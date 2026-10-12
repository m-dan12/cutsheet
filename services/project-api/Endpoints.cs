using System.Security.Claims;
using Cutsheet.Messaging;
using Microsoft.AspNetCore.SignalR;

namespace Cutsheet.ProjectApi;

public sealed record CreateProjectRequest(string? Name, string? Language);
public sealed record StartUploadRequest(string? Kind, string? Filename, long? SizeBytes, string? ContentType);
public sealed record PartUrl(int PartNumber, string Url);
public sealed record UploadResponse(Guid UploadId, string Kind, string Status, long SizeBytes, long PartSize,
    int PartCount, List<int> UploadedParts, List<PartUrl> Parts, DateTimeOffset ExpiresAt);

public static class Endpoints
{
    // Части multipart: от 16 МиБ, не больше 10 000 частей (ограничение S3).
    private const long MinPartSize = 16L * 1024 * 1024;
    private const int MaxParts = 10_000;
    private const long MaxObjectSize = 5L * 1024 * 1024 * 1024 * 1024; // 5 ТиБ, предел S3

    public static async Task<IResult> ListProjects(ClaimsPrincipal user, ProjectStore store, CancellationToken ct) =>
        Results.Ok(await store.List(user.UserId(), ct));

    public static async Task<IResult> CreateProject(CreateProjectRequest body, ClaimsPrincipal user, ProjectStore store,
        CancellationToken ct)
    {
        var name = body.Name?.Trim();
        if (string.IsNullOrEmpty(name) || name.Length > 200)
            return Results.ValidationProblem(new Dictionary<string, string[]> { ["name"] = ["от 1 до 200 символов"] });
        var project = await store.Create(user.UserId(), name, body.Language ?? "ru", ct);
        return Results.Created($"/api/v1/projects/{project.Id}", project);
    }

    public static async Task<IResult> GetProject(Guid id, ClaimsPrincipal user, ProjectStore store, CancellationToken ct) =>
        await store.Get(id, user.UserId(), ct) is { } p ? Results.Ok(p) : Results.NotFound();

    /// <summary>
    /// POST /projects/{id}/uploads: начинает multipart-загрузку и выдаёт presigned URL на каждую часть
    /// (FR-G2). Клиент грузит части напрямую в S3, мимо Kong (FR-GW5).
    /// </summary>
    public static async Task<IResult> StartUpload(Guid id, StartUploadRequest body, ClaimsPrincipal user,
        ProjectStore store, ObjectStorage s3, IHubContext<ProjectsHub> hub, CancellationToken ct)
    {
        if (await store.Get(id, user.UserId(), ct) is null) return Results.NotFound();
        var errors = new Dictionary<string, string[]>();
        if (body.Kind is not ("video" or "script")) errors["kind"] = ["video или script"];
        if (string.IsNullOrWhiteSpace(body.Filename)) errors["filename"] = ["обязательно"];
        if (body.SizeBytes is not > 0 || body.SizeBytes > MaxObjectSize) errors["size_bytes"] = ["от 1 байта до 5 ТиБ"];
        if (errors.Count > 0) return Results.ValidationProblem(errors);

        var size = body.SizeBytes!.Value;
        var partSize = Math.Max(MinPartSize, (size + MaxParts - 1) / MaxParts);
        var partCount = (int)((size + partSize - 1) / partSize);
        var uploadId = Guid.NewGuid();
        var filename = Path.GetFileName(body.Filename!.Trim());
        // Ключ не зависит от имени файла (кириллица, пробелы); имя хранится в uploads и уходит в событие.
        var key = $"projects/{id}/{body.Kind}/{uploadId}{Path.GetExtension(filename).ToLowerInvariant()}";
        var contentType = body.ContentType ?? (body.Kind == "video" ? "video/mp4"
            : "application/vnd.openxmlformats-officedocument.wordprocessingml.document");
        var s3UploadId = await s3.StartMultipart(key, contentType, ct);

        var upload = new Upload(uploadId, id, body.Kind!, key, "pending", filename, contentType, size, partSize,
            partCount, s3UploadId);
        await store.CreateUpload(upload, ct);
        if (body.Kind == "video")
            await SetStatus(store, hub, id, "upload", "running", null, ct);
        return Results.Ok(Describe(upload, s3, []));
    }

    /// <summary>Состояние загрузки и свежие URL для недостающих частей: докачка после обрыва (FR-C2).</summary>
    public static async Task<IResult> GetUpload(Guid id, Guid uploadId, ClaimsPrincipal user, ProjectStore store,
        ObjectStorage s3, CancellationToken ct)
    {
        if (await store.Get(id, user.UserId(), ct) is null) return Results.NotFound();
        if (await store.GetUpload(id, uploadId, ct) is not { } upload) return Results.NotFound();
        if (upload.Status == "completed") return Results.Ok(Describe(upload, s3, null));
        var done = (await s3.ListParts(upload.S3Key, upload.S3UploadId!, ct)).Select(p => p.PartNumber ?? 0).ToList();
        return Results.Ok(Describe(upload, s3, done));
    }

    /// <summary>
    /// Завершает multipart-загрузку, проверяет объект в S3 и публикует video.uploaded / script.uploaded
    /// (FR-G3). Повторный вызов для завершённой загрузки повторяет только публикацию события.
    /// </summary>
    public static async Task<IResult> CompleteUpload(Guid id, Guid uploadId, ClaimsPrincipal user, ProjectStore store,
        ObjectStorage s3, EventBus bus, IHubContext<ProjectsHub> hub, CancellationToken ct)
    {
        if (await store.Get(id, user.UserId(), ct) is null) return Results.NotFound();
        if (await store.GetUpload(id, uploadId, ct) is not { } upload) return Results.NotFound();

        if (upload.Status != "completed")
        {
            var parts = await s3.ListParts(upload.S3Key, upload.S3UploadId!, ct);
            var missing = Enumerable.Range(1, upload.PartCount ?? 0).Except(parts.Select(p => p.PartNumber ?? 0)).ToList();
            if (missing.Count > 0)
                return Results.Problem($"не загружены части: {string.Join(", ", missing.Take(20))}",
                    statusCode: StatusCodes.Status409Conflict);
            await s3.CompleteMultipart(upload.S3Key, upload.S3UploadId!, parts, ct);
        }

        if (await s3.ObjectSize(upload.S3Key, ct) is not { } size)
            return Results.Problem("объект не найден в хранилище", statusCode: StatusCodes.Status409Conflict);
        if (upload.SizeBytes is { } expected && expected != size)
            return Results.Problem($"размер {size} не совпадает с заявленным {expected}",
                statusCode: StatusCodes.Status409Conflict);

        var uri = ObjectStorage.Uri(s3.Bucket, upload.S3Key);
        await store.CompleteUpload(upload, uri, size, ct);

        var correlationId = Guid.NewGuid();
        if (upload.Kind == "video")
        {
            await bus.PublishAsync("video.uploaded", id, correlationId,
                new VideoUploaded(uri, size, upload.Filename ?? Path.GetFileName(upload.S3Key)), ct);
            await SetStatus(store, hub, id, "scenes", "running", null, ct);
        }
        else
        {
            await bus.PublishAsync("script.uploaded", id, correlationId,
                new ScriptUploaded(uri, upload.Filename ?? Path.GetFileName(upload.S3Key)), ct);
        }
        return Results.Ok(await store.Get(id, user.UserId(), ct));
    }

    private static UploadResponse Describe(Upload u, ObjectStorage s3, List<int>? uploaded)
    {
        var done = uploaded ?? Enumerable.Range(1, u.PartCount ?? 0).ToList();
        var urls = uploaded is null
            ? []
            : Enumerable.Range(1, u.PartCount ?? 0).Except(done)
                .Select(n => new PartUrl(n, s3.PresignPart(u.S3Key, u.S3UploadId!, n))).ToList();
        return new UploadResponse(u.Id, u.Kind, uploaded is null ? "completed" : u.Status, u.SizeBytes ?? 0,
            u.PartSize ?? 0, u.PartCount ?? 0, done, urls, DateTimeOffset.UtcNow + s3.UrlLifetime);
    }

    internal static async Task SetStatus(ProjectStore store, IHubContext<ProjectsHub> hub, Guid id, string stage,
        string status, string? error, CancellationToken ct)
    {
        await store.SetStatus(id, stage, status, error, ct);
        await hub.Clients.Group(ProjectsHub.Group(id)).SendAsync("status",
            new StatusMessage(id, stage, status, null, error), ct);
    }

    // Payload'ы событий (contracts/schemas/events/*.v1.json); имена полей — snake_case.
    internal sealed record VideoUploaded(
        [property: System.Text.Json.Serialization.JsonPropertyName("video_uri")] string VideoUri,
        [property: System.Text.Json.Serialization.JsonPropertyName("size_bytes")] long SizeBytes,
        [property: System.Text.Json.Serialization.JsonPropertyName("filename")] string Filename);

    internal sealed record ScriptUploaded(
        [property: System.Text.Json.Serialization.JsonPropertyName("script_uri")] string ScriptUri,
        [property: System.Text.Json.Serialization.JsonPropertyName("filename")] string Filename);
}
