using System.Security.Claims;
using System.Text.Json;
using Cutsheet.Messaging;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.SignalR;

namespace Cutsheet.ProjectApi;

public sealed record UpdateProjectRequest(bool? ReviewRequired);
public sealed record ReprocessRequest(string? From);

/// <summary>Монтажный лист: чтение, правки строк, split/merge, перезапуск обработки (ТЗ 5.2, этап 4).</summary>
public static class SheetEndpoints
{
    public static void Map(RouteGroupBuilder projects)
    {
        projects.MapPatch("/{id:guid}", UpdateProject);
        projects.MapPost("/{id:guid}/reprocess", Reprocess);
        projects.MapGet("/{id:guid}/scenes", GetScenes);
        projects.MapPost("/{id:guid}/scenes", (Guid id, JsonElement body, ClaimsPrincipal user, SheetStore sheet,
                ProjectStore store, ObjectStorage s3, CancellationToken ct) =>
            Edit(id, user, sheet, store, s3, e => e.AddAsync(body), ct));
        projects.MapPatch("/{id:guid}/scenes/{sceneId:guid}", (Guid id, Guid sceneId, JsonElement body,
                ClaimsPrincipal user, SheetStore sheet, ProjectStore store, ObjectStorage s3, CancellationToken ct) =>
            Edit(id, user, sheet, store, s3, e => e.PatchSceneAsync(sceneId, body), ct));
        projects.MapPut("/{id:guid}/scenes/{sceneId:guid}/replicas", (Guid id, Guid sceneId, JsonElement body,
                ClaimsPrincipal user, SheetStore sheet, ProjectStore store, ObjectStorage s3, CancellationToken ct) =>
            Edit(id, user, sheet, store, s3, e => e.PutReplicasAsync(sceneId, body), ct));
        projects.MapPost("/{id:guid}/scenes/{sceneId:guid}/split", (Guid id, Guid sceneId, JsonElement body,
                ClaimsPrincipal user, SheetStore sheet, ProjectStore store, ObjectStorage s3, CancellationToken ct) =>
            Edit(id, user, sheet, store, s3, e => e.SplitAsync(sceneId, body), ct));
        projects.MapPost("/{id:guid}/scenes/{sceneId:guid}/merge", (Guid id, Guid sceneId, JsonElement body,
                ClaimsPrincipal user, SheetStore sheet, ProjectStore store, ObjectStorage s3, CancellationToken ct) =>
            Edit(id, user, sheet, store, s3, e => e.MergeAsync(sceneId, body), ct));
        projects.MapDelete("/{id:guid}/scenes/{sceneId:guid}", (Guid id, Guid sceneId, [FromQuery(Name = "row_version")] int? rowVersion,
                ClaimsPrincipal user, SheetStore sheet, ProjectStore store, ObjectStorage s3, CancellationToken ct) =>
            Edit(id, user, sheet, store, s3, e => e.DeleteAsync(sceneId, rowVersion), ct));
    }

    /// <summary>GET /projects/{id}/scenes: лист целиком с репликами, метками правок и авто-значениями (FR-G4).</summary>
    public static async Task<IResult> GetScenes(Guid id, ClaimsPrincipal user, ProjectStore store, SheetStore sheet,
        ObjectStorage s3, CancellationToken ct)
    {
        if (await store.Get(id, user.UserId(), ct) is not { } project) return Results.NotFound();
        return Results.Ok(await FullSheet(project, sheet, s3, ct));
    }

    /// <summary>PATCH /projects/{id}: режим «без правок» (FR-C12).</summary>
    public static async Task<IResult> UpdateProject(Guid id, UpdateProjectRequest body, ClaimsPrincipal user,
        ProjectStore store, CancellationToken ct)
    {
        if (await store.Get(id, user.UserId(), ct) is null) return Results.NotFound();
        if (body.ReviewRequired is { } review) await store.SetReviewRequired(id, review, ct);
        return Results.Ok(await store.Get(id, user.UserId(), ct));
    }

    /// <summary>
    /// POST /projects/{id}/reprocess (FR-G7): повторяет video.uploaded (с поиска склеек) или
    /// script.uploaded (с разбора сценария). Правки пользователя сохраняются: Aggregator обновляет
    /// только авто-значения.
    /// </summary>
    public static async Task<IResult> Reprocess(Guid id, ReprocessRequest body, ClaimsPrincipal user,
        ProjectStore store, EventBus bus, IHubContext<ProjectsHub> hub, CancellationToken ct)
    {
        if (await store.Get(id, user.UserId(), ct) is not { } project) return Results.NotFound();
        var from = body.From ?? "scenes";
        if (from is not ("scenes" or "dialogue"))
            return Results.ValidationProblem(new Dictionary<string, string[]> { ["from"] = ["scenes или dialogue"] });
        var kind = from == "scenes" ? "video" : "script";
        if (await store.LastCompletedUpload(id, kind, ct) is not { SizeBytes: { } size } upload
            || (kind == "video" ? project.VideoUri : project.ScriptUri) is not { } uri)
            return Results.Problem(kind == "video" ? "видео не загружено" : "сценарий не загружен",
                statusCode: StatusCodes.Status409Conflict);

        var correlationId = Guid.NewGuid();
        var filename = upload.Filename ?? Path.GetFileName(upload.S3Key);
        if (kind == "video")
            await bus.PublishAsync("video.uploaded", id, correlationId, new Endpoints.VideoUploaded(uri, size, filename), ct);
        else
            await bus.PublishAsync("script.uploaded", id, correlationId, new Endpoints.ScriptUploaded(uri, filename), ct);
        await Endpoints.SetStatus(store, hub, id, from, "running", null, ct);
        return Results.Accepted($"/api/v1/projects/{id}", await store.Get(id, user.UserId(), ct));
    }

    private static async Task<IResult> Edit(Guid id, ClaimsPrincipal user, SheetStore sheet, ProjectStore store,
        ObjectStorage s3, Func<SheetEdit, Task<EditOutcome>> action, CancellationToken ct)
    {
        var owner = user.UserId();
        switch (await sheet.Edit(id, owner, owner, action, ct))
        {
            case EditOutcome.NotFound:
                return Results.NotFound();
            case EditOutcome.Invalid invalid:
                return Results.ValidationProblem(invalid.Errors);
            case EditOutcome.Conflict conflict:
                return Results.Json(new ConflictResponse("Строку уже изменили: версия устарела",
                    conflict.Current is null ? null : ToResponse(conflict.Current, s3)), statusCode: StatusCodes.Status409Conflict);
            case EditOutcome.Changed changed:
                var project = (await store.Get(id, owner, ct))!;
                if (changed.Structure) return Results.Ok(await FullSheet(project, sheet, s3, ct));
                var scenes = await sheet.Load(id, ct);
                return Results.Ok(new SceneChangesResponse(scenes.Where(s => changed.SceneIds.Contains(s.Id))
                    .Select(s => ToResponse(s, s3)).ToList()));
            default:
                throw new InvalidOperationException();
        }
    }

    private static async Task<ScenesResponse> FullSheet(Project project, SheetStore sheet, ObjectStorage s3,
        CancellationToken ct)
    {
        var scenes = await sheet.Load(project.Id, ct);
        return new ScenesResponse(project.Id, project.Fps, project.DurationMs,
            project.VideoUri is { } v ? s3.PresignGet(v) : null, project.ReviewRequired, project.StructureEdited,
            [.. SheetFields.ShotTypes], await sheet.Roles(project.Id, ct), scenes.Select(s => ToResponse(s, s3)).ToList());
    }

    private static SceneResponse ToResponse(SheetScene s, ObjectStorage s3) =>
        new(s.Id, s.Index, s.StartMs, s.EndMs, s.ShotType, s.Description, s.Status, s.RowVersion,
            s.KeyframeUris.Select(s3.PresignGet).ToList(), s.Origin, s.NeedsEnrichment, s.Edited, s.Auto,
            s.Replicas.Select(r => new ReplicaResponse(r.Id, r.Index, r.StartMs, r.EndMs, r.Role, r.Text, r.SpokenText,
                r.Confidence, r.Matched, r.Origin, r.Edited)).ToList());
}
