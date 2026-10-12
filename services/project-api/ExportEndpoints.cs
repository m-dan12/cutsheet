using System.Security.Claims;
using System.Text.Json;
using System.Text.Json.Serialization;
using Cutsheet.Messaging;
using Microsoft.AspNetCore.SignalR;

namespace Cutsheet.ProjectApi;

public sealed record ExportRequest(string? Format, JsonElement? Options);

public sealed record ExportResponse(Guid Id, string Format, string Status, string? Error, string? DownloadUrl,
    string Filename, DateTimeOffset CreatedAt, DateTimeOffset? CompletedAt);

/// <summary>Сообщение "export" в хабе: экспорт запрошен, готов или не удался.</summary>
public sealed record ExportMessage(Guid ProjectId, Guid ExportId, string Format, string Status, string? Error);

/// <summary>
/// Экспорт монтажного листа (FR-G6, этап 5). Project API собирает снимок листа (итоговые значения с
/// правками) в S3 и публикует export.requested; Export Service кладёт файл в S3 и отвечает
/// export.completed / export.failed (<see cref="ExportConsumer"/>).
/// </summary>
public static class ExportEndpoints
{
    public static readonly string[] Formats = ["xlsx", "docx", "pdf"];
    private const int ListLimit = 20;

    private static readonly JsonSerializerOptions SnapshotJson = new() { WriteIndented = false };

    public static void Map(RouteGroupBuilder projects)
    {
        projects.MapPost("/{id:guid}/exports", Request);
        projects.MapGet("/{id:guid}/exports", List);
        projects.MapGet("/{id:guid}/exports/{exportId:guid}", Get);
    }

    /// <summary>POST /projects/{id}/exports {format, options}: 202 и строка экспорта со статусом requested.</summary>
    public static async Task<IResult> Request(Guid id, ExportRequest body, ClaimsPrincipal user, ProjectStore store,
        SheetStore sheet, ExportStore exports, ObjectStorage s3, EventBus bus, IHubContext<ProjectsHub> hub,
        CancellationToken ct)
    {
        if (await store.Get(id, user.UserId(), ct) is not { } project) return Results.NotFound();
        var errors = new Dictionary<string, string[]>();
        if (body.Format is not { } format || !Formats.Contains(format)) errors["format"] = ["xlsx, docx или pdf"];
        var options = body.Options is { ValueKind: not (JsonValueKind.Null or JsonValueKind.Undefined) } o
            ? o : JsonSerializer.SerializeToElement(new { });
        if (options.ValueKind != JsonValueKind.Object) errors["options"] = ["объект"];
        if (errors.Count > 0) return Results.ValidationProblem(errors);

        var scenes = await sheet.Load(id, ct);
        if (scenes.Count == 0)
            return Results.Problem("в листе нет строк: дождитесь поиска склеек", statusCode: StatusCodes.Status409Conflict);

        var exportId = Guid.NewGuid();
        var snapshot = ExportSnapshot.Build(exportId, project, scenes, DateTimeOffset.UtcNow);
        var snapshotUri = await s3.PutBytes($"projects/{id}/exports/{exportId}/snapshot.json",
            JsonSerializer.SerializeToUtf8Bytes(snapshot, SnapshotJson), "application/json", ct);
        var row = await exports.Create(exportId, id, body.Format!, options, snapshotUri, ct);

        await bus.PublishAsync("export.requested", id, Guid.NewGuid(),
            new ExportRequested(exportId, body.Format!, snapshotUri, options), ct);
        await hub.Clients.Group(ProjectsHub.Group(id)).SendAsync("export",
            new ExportMessage(id, exportId, row.Format, row.Status, null), ct);
        return Results.Accepted($"/api/v1/projects/{id}/exports/{exportId}", ToResponse(row, project, s3));
    }

    public static async Task<IResult> List(Guid id, ClaimsPrincipal user, ProjectStore store, ExportStore exports,
        ObjectStorage s3, CancellationToken ct)
    {
        if (await store.Get(id, user.UserId(), ct) is not { } project) return Results.NotFound();
        return Results.Ok((await exports.List(id, ListLimit, ct)).Select(e => ToResponse(e, project, s3)).ToList());
    }

    /// <summary>GET /projects/{id}/exports/{exportId}: статус и ссылка на файл (presigned, ≤ 1 ч).</summary>
    public static async Task<IResult> Get(Guid id, Guid exportId, ClaimsPrincipal user, ProjectStore store,
        ExportStore exports, ObjectStorage s3, CancellationToken ct)
    {
        if (await store.Get(id, user.UserId(), ct) is not { } project) return Results.NotFound();
        return await exports.Get(id, exportId, ct) is { } row ? Results.Ok(ToResponse(row, project, s3)) : Results.NotFound();
    }

    private static ExportResponse ToResponse(ExportRow e, Project project, ObjectStorage s3)
    {
        var filename = Filename(project.Name, e.Format);
        var url = e is { Status: "completed", S3Uri: { } uri } ? s3.PresignGet(uri, filename) : null;
        return new ExportResponse(e.Id, e.Format, e.Status, e.Error, url, filename, e.CreatedAt, e.CompletedAt);
    }

    /// <summary>Имя файла для скачивания: название проекта без символов, запрещённых в Windows.</summary>
    public static string Filename(string projectName, string format)
    {
        var invalid = new HashSet<char>("<>:\"/\\|?*");
        var name = new string(projectName.Select(c => invalid.Contains(c) || char.IsControl(c) ? '_' : c).ToArray())
            .Trim().TrimEnd('.');
        if (name.Length > 100) name = name[..100].TrimEnd();
        return $"{(name.Length == 0 ? "sheet" : name)} - монтажный лист.{format}";
    }

    internal sealed record ExportRequested(
        [property: JsonPropertyName("export_id")] Guid ExportId,
        [property: JsonPropertyName("format")] string Format,
        [property: JsonPropertyName("snapshot_uri")] string SnapshotUri,
        [property: JsonPropertyName("options")] JsonElement Options);
}
