using System.Text.Json;
using Npgsql;

namespace Cutsheet.ProjectApi;

/// <summary>Результат правки листа; транзакция фиксируется только для <see cref="Changed"/>.</summary>
public abstract record EditOutcome
{
    public sealed record NotFound : EditOutcome;

    /// <summary>row_version не совпал (FR-G5): Current — актуальная строка.</summary>
    public sealed record Conflict(SheetScene? Current) : EditOutcome;

    public sealed record Invalid(Dictionary<string, string[]> Errors) : EditOutcome
    {
        public Invalid(string field, string error) : this(new Dictionary<string, string[]> { [field] = [error] }) { }
    }

    /// <param name="SceneIds">Изменённые строки.</param>
    /// <param name="Structure">Изменилась структура листа (границы, состав сцен): нужен полный лист.</param>
    public sealed record Changed(List<Guid> SceneIds, bool Structure) : EditOutcome;
}

/// <param name="EditAuto">Значения полей до первой правки (user_edits.auto_value) по (id сцены или реплики, поле).</param>
internal sealed record SheetData(List<SheetScene> Scenes, Dictionary<(Guid Id, string Field), JsonElement> EditAuto);

/// <summary>
/// Монтажный лист проекта: чтение и правки (FR-G4, FR-G5, ТЗ 6.2). Каждая правка — одна транзакция
/// с блокировкой строки проекта: правки одного проекта и запись результатов Aggregator'ом
/// (он тоже блокирует проект) идут по очереди.
/// </summary>
public sealed class SheetStore(NpgsqlDataSource db)
{
    public async Task<List<SheetScene>> Load(Guid projectId, CancellationToken ct)
    {
        await using var conn = await db.OpenConnectionAsync(ct);
        return (await LoadAsync(conn, null, projectId, ct)).Scenes;
    }

    public async Task<List<string>> Roles(Guid projectId, CancellationToken ct)
    {
        await using var cmd = db.CreateCommand("SELECT name FROM roles WHERE project_id = $1 ORDER BY name");
        cmd.Parameters.AddWithValue(projectId);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        var list = new List<string>();
        while (await r.ReadAsync(ct)) list.Add(r.GetString(0));
        return list;
    }

    public async Task<EditOutcome> Edit(Guid projectId, Guid ownerId, Guid userId,
        Func<SheetEdit, Task<EditOutcome>> action, CancellationToken ct)
    {
        await using var conn = await db.OpenConnectionAsync(ct);
        await using var tx = await conn.BeginTransactionAsync(ct);
        long? duration;
        await using (var cmd = new NpgsqlCommand(
                         "SELECT duration_ms FROM projects WHERE id = $1 AND owner_id = $2 FOR UPDATE", conn, tx))
        {
            cmd.Parameters.AddWithValue(projectId);
            cmd.Parameters.AddWithValue(ownerId);
            await using var r = await cmd.ExecuteReaderAsync(ct);
            if (!await r.ReadAsync(ct)) return new EditOutcome.NotFound();
            duration = r.IsDBNull(0) ? null : r.GetInt64(0);
        }

        var sheet = await LoadAsync(conn, tx, projectId, ct);
        var edit = new SheetEdit(conn, tx, projectId, userId, duration, sheet, ct);
        var outcome = await action(edit);
        if (outcome is not EditOutcome.Changed changed)
        {
            await tx.RollbackAsync(ct);
            return outcome;
        }
        if (changed.Structure) await edit.MarkStructureEditedAsync();
        await tx.CommitAsync(ct);
        return outcome;
    }

    internal static async Task<SheetData> LoadAsync(NpgsqlConnection conn, NpgsqlTransaction? tx, Guid p,
        CancellationToken ct)
    {
        var scenes = new List<SheetScene>();
        await using (var cmd = new NpgsqlCommand("""
                         SELECT s.id, s.idx, s.start_ms, s.end_ms, s.shot_type, s.description, s.status, s.row_version,
                                s.origin, s.needs_enrichment,
                                COALESCE(array_agg(k.s3_uri ORDER BY k.position) FILTER (WHERE k.s3_uri IS NOT NULL), '{}')
                         FROM scenes s LEFT JOIN scene_keyframes k ON k.scene_id = s.id
                         WHERE s.project_id = $1
                         GROUP BY s.id ORDER BY s.idx
                         """, conn, tx))
        {
            cmd.Parameters.AddWithValue(p);
            await using var r = await cmd.ExecuteReaderAsync(ct);
            while (await r.ReadAsync(ct))
                scenes.Add(new SheetScene(r.GetGuid(0), r.GetInt32(1), r.GetInt64(2), r.GetInt64(3), N<string>(r, 4),
                    N<string>(r, 5), r.GetString(6), r.GetInt32(7), r.GetString(8), r.GetBoolean(9),
                    [.. r.GetFieldValue<string[]>(10)], [], [], []));
        }
        var byId = scenes.ToDictionary(s => s.Id);

        await using (var cmd = new NpgsqlCommand("""
                         SELECT a.scene_id, a.field, a.value::text, a.confidence, a.source
                         FROM scene_auto_values a JOIN scenes s ON s.id = a.scene_id
                         WHERE s.project_id = $1 AND a.value IS NOT NULL
                         """, conn, tx))
        {
            cmd.Parameters.AddWithValue(p);
            await using var r = await cmd.ExecuteReaderAsync(ct);
            while (await r.ReadAsync(ct))
                byId[r.GetGuid(0)].Auto[r.GetString(1)] =
                    new AutoValue(Json(r.GetString(2)), N<float?>(r, 3), r.GetString(4));
        }

        var replicaEdits = new Dictionary<Guid, List<string>>();
        var editAuto = new Dictionary<(Guid, string), JsonElement>();
        await using (var cmd = new NpgsqlCommand("""
                         SELECT u.scene_id, u.replica_id, u.field, u.auto_value::text FROM user_edits u
                         LEFT JOIN replicas r ON r.id = u.replica_id
                         JOIN scenes s ON s.id = COALESCE(u.scene_id, r.scene_id)
                         WHERE s.project_id = $1 ORDER BY u.field
                         """, conn, tx))
        {
            cmd.Parameters.AddWithValue(p);
            await using var r = await cmd.ExecuteReaderAsync(ct);
            while (await r.ReadAsync(ct))
            {
                if (!r.IsDBNull(0))
                {
                    var scene = byId[r.GetGuid(0)];
                    scene.Edited.Add(r.GetString(2));
                    if (!r.IsDBNull(3)) editAuto[(scene.Id, r.GetString(2))] = Json(r.GetString(3));
                }
                else
                {
                    var id = r.GetGuid(1);
                    if (!replicaEdits.TryGetValue(id, out var list)) replicaEdits[id] = list = [];
                    list.Add(r.GetString(2));
                    if (!r.IsDBNull(3)) editAuto[(id, r.GetString(2))] = Json(r.GetString(3));
                }
            }
        }

        await using (var cmd = new NpgsqlCommand("""
                         SELECT r.id, r.scene_id, r.idx, r.start_ms, r.end_ms, ro.name, r.text, r.spoken_text,
                                r.confidence, r.matched, r.origin
                         FROM replicas r JOIN scenes s ON s.id = r.scene_id LEFT JOIN roles ro ON ro.id = r.role_id
                         WHERE s.project_id = $1 AND NOT r.deleted
                         ORDER BY r.scene_id, r.idx, r.start_ms
                         """, conn, tx))
        {
            cmd.Parameters.AddWithValue(p);
            await using var r = await cmd.ExecuteReaderAsync(ct);
            while (await r.ReadAsync(ct))
            {
                var id = r.GetGuid(0);
                byId[r.GetGuid(1)].Replicas.Add(new ReplicaRow(id, r.GetGuid(1), r.GetInt32(2), r.GetInt64(3),
                    r.GetInt64(4), N<string>(r, 5), r.GetString(6), N<string>(r, 7), N<float?>(r, 8), r.GetBoolean(9),
                    r.GetString(10), replicaEdits.GetValueOrDefault(id) ?? []));
            }
        }
        return new SheetData(scenes, editAuto);
    }

    private static JsonElement Json(string text) => JsonDocument.Parse(text).RootElement.Clone();

    private static T? N<T>(NpgsqlDataReader r, int i) => r.IsDBNull(i) ? default : r.GetFieldValue<T>(i);
}
