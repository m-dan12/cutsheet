using System.Text.Json;

namespace Cutsheet.ProjectApi;

/// <summary>Поля сцены, которые правит человек (FR-C5), и справочник планов (FR-ST1).</summary>
public static class SheetFields
{
    public const string StartMs = "start_ms";
    public const string EndMs = "end_ms";
    public const string ShotType = "shot_type";
    public const string Description = "description";

    // Поля реплики. deleted/scene_id — метки удаления и переноса, чтобы повторный join их не отменил.
    public const string Text = "text";
    public const string Role = "role";
    public const string Deleted = "deleted";
    public const string SceneId = "scene_id";

    /// <summary>Коды планов (contracts/schemas/defs.v1.json, shot_type).</summary>
    public static readonly string[] ShotTypes = ["wide", "medium", "close", "detail", "unknown"];

    public const int MaxDescription = 4000;
    public const int MaxReplicaText = 4000;
    public const int MaxRoleName = 200;
}

public sealed record AutoValue(JsonElement Value, float? Confidence, string Source);

public sealed record ReplicaRow(Guid Id, Guid SceneId, int Index, long StartMs, long EndMs, string? Role, string Text,
    string? SpokenText, float? Confidence, bool Matched, string Origin, List<string> Edited);

public sealed record SheetScene(Guid Id, int Index, long StartMs, long EndMs, string? ShotType, string? Description,
    string Status, int RowVersion, string Origin, bool NeedsEnrichment, List<string> KeyframeUris, List<string> Edited,
    Dictionary<string, AutoValue> Auto, List<ReplicaRow> Replicas);

// Ответы API (snake_case задаёт JsonNamingPolicy в Program.cs).
public sealed record ReplicaResponse(Guid Id, int Index, long StartMs, long EndMs, string? Role, string Text,
    string? SpokenText, float? Confidence, bool Matched, string Origin, List<string> Edited);

public sealed record SceneResponse(Guid Id, int Index, long StartMs, long EndMs, string? ShotType, string? Description,
    string Status, int RowVersion, List<string> KeyframeUrls, string Origin, bool NeedsEnrichment, List<string> Edited,
    Dictionary<string, AutoValue> Auto, List<ReplicaResponse> Replicas);

public sealed record ScenesResponse(Guid ProjectId, double? Fps, long? DurationMs, string? VideoUrl,
    bool ReviewRequired, bool StructureEdited, List<string> ShotTypes, List<string> Roles, List<SceneResponse> Scenes);

/// <summary>Ответ на правку одной строки: изменённые сцены (сама строка и, при сдвиге границы, соседи).</summary>
public sealed record SceneChangesResponse(List<SceneResponse> Scenes);

/// <summary>409 (FR-G5): версия строки устарела, в ответе актуальные данные.</summary>
public sealed record ConflictResponse(string Title, SceneResponse? Scene);
