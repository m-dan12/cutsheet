using System.Text.Json.Serialization;

namespace Cutsheet.ProjectApi;

/// <summary>
/// Снимок монтажного листа для Export Service (FR-G6, FR-E4): итоговые значения строк с учётом правок
/// пользователя. Контракт — contracts/schemas/documents/sheet-snapshot.v1.json.
/// </summary>
public sealed record ExportSnapshot(
    [property: JsonPropertyName("schema_version")] int SchemaVersion,
    [property: JsonPropertyName("export_id")] Guid ExportId,
    [property: JsonPropertyName("project")] SnapshotProject Project,
    [property: JsonPropertyName("generated_at")] DateTimeOffset GeneratedAt,
    [property: JsonPropertyName("fps")] double? Fps,
    [property: JsonPropertyName("duration_ms")] long? DurationMs,
    [property: JsonPropertyName("scenes")] List<SnapshotScene> Scenes)
{
    public static ExportSnapshot Build(Guid exportId, Project project, IReadOnlyList<SheetScene> scenes,
        DateTimeOffset now) =>
        new(1, exportId, new SnapshotProject(project.Id, project.Name, project.Language), now,
            project.Fps is > 0 ? project.Fps : null, project.DurationMs,
            scenes.OrderBy(s => s.Index).Select((s, i) => new SnapshotScene(s.Id, i + 1, s.StartMs, s.EndMs,
                s.ShotType, s.Description,
                s.Replicas.OrderBy(r => r.Index).ThenBy(r => r.StartMs)
                    .Select(r => new SnapshotReplica(r.Role, r.Text, r.StartMs, r.EndMs)).ToList())).ToList());
}

public sealed record SnapshotProject(
    [property: JsonPropertyName("id")] Guid Id,
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("language")] string Language);

public sealed record SnapshotScene(
    [property: JsonPropertyName("id")] Guid Id,
    [property: JsonPropertyName("number")] int Number,
    [property: JsonPropertyName("start_ms")] long StartMs,
    [property: JsonPropertyName("end_ms")] long EndMs,
    [property: JsonPropertyName("shot_type")] string? ShotType,
    [property: JsonPropertyName("description")] string? Description,
    [property: JsonPropertyName("replicas")] List<SnapshotReplica> Replicas);

public sealed record SnapshotReplica(
    [property: JsonPropertyName("role")] string? Role,
    [property: JsonPropertyName("text")] string Text,
    [property: JsonPropertyName("start_ms")] long StartMs,
    [property: JsonPropertyName("end_ms")] long EndMs);
