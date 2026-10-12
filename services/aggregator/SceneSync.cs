using Npgsql;

namespace Cutsheet.Aggregator;

public sealed record DetectedScene(int Index, long StartMs, long EndMs, List<string> KeyframeUris);

/// <summary>
/// Запись результата детекции в лист без потери правок (FR-A5, ТЗ 6.2).
/// <list type="bullet">
/// <item>Первая детекция — сцены вставляются как есть.</item>
/// <item>Человек менял структуру листа (projects.structure_edited) — сцены не трогаются: границы теперь его.</item>
/// <item>Иначе сцены сопоставляются по времени (<see cref="SceneMatcher"/>): строка с парой обновляется
/// на месте и сохраняет id, правки и реплики; правки строк без пары переносятся на ближайшую новую.</item>
/// </list>
/// </summary>
public static class SceneSync
{
    public enum Result { Inserted, Matched, KeptUserStructure }

    private sealed record OldScene(Guid Id, long StartMs, long EndMs, string? ShotType, string? Description,
        HashSet<string> Edited);

    public static async Task<Result> ApplyAsync(NpgsqlConnection conn, NpgsqlTransaction tx, Guid project,
        IReadOnlyList<DetectedScene> scenes, CancellationToken ct)
    {
        var structureEdited = (bool)(await Scalar(conn, tx,
            "SELECT structure_edited FROM projects WHERE id = @p FOR UPDATE", ct, ("p", project)))!;

        var old = new List<OldScene>();
        await using (var cmd = Command(conn, tx, """
                         SELECT s.id, s.start_ms, s.end_ms, s.shot_type, s.description,
                                COALESCE(array_agg(u.field) FILTER (WHERE u.field IS NOT NULL), '{}')
                         FROM scenes s LEFT JOIN user_edits u ON u.scene_id = s.id
                         WHERE s.project_id = @p GROUP BY s.id ORDER BY s.idx
                         """, ("p", project)))
        await using (var r = await cmd.ExecuteReaderAsync(ct))
            while (await r.ReadAsync(ct))
                old.Add(new OldScene(r.GetGuid(0), r.GetInt64(1), r.GetInt64(2),
                    r.IsDBNull(3) ? null : r.GetString(3), r.IsDBNull(4) ? null : r.GetString(4),
                    [.. r.GetFieldValue<string[]>(5)]));

        if (old.Count > 0 && structureEdited) return Result.KeptUserStructure;

        var match = SceneMatcher.Match(old.Select(o => new SceneInterval(o.StartMs, o.EndMs)).ToList(),
            scenes.Select(s => new SceneInterval(s.StartMs, s.EndMs)).ToList());
        // UNIQUE (project_id, idx) проверяется построчно: сначала уводим номера в отрицательные.
        await Exec(conn, tx, "UPDATE scenes SET idx = -idx - 1 WHERE project_id = @p", ct, ("p", project));

        var ids = new Guid[scenes.Count];
        for (var j = 0; j < scenes.Count; j++)
        {
            var scene = scenes[j];
            if (match.Reuse[j] is var i and >= 0)
            {
                ids[j] = old[i].Id;
                await Exec(conn, tx, """
                    UPDATE scenes SET idx = @idx, start_ms = @start, end_ms = @end, status = 'detected',
                        needs_enrichment = false, row_version = row_version + 1
                    WHERE id = @id
                    """, ct, ("id", ids[j]), ("idx", scene.Index), ("start", scene.StartMs), ("end", scene.EndMs));
                await Exec(conn, tx, "DELETE FROM scene_keyframes WHERE scene_id = @id", ct, ("id", ids[j]));
            }
            else
            {
                ids[j] = Guid.NewGuid();
                await Exec(conn, tx,
                    "INSERT INTO scenes (id, project_id, idx, start_ms, end_ms) VALUES (@id, @p, @idx, @start, @end)",
                    ct, ("id", ids[j]), ("p", project), ("idx", scene.Index), ("start", scene.StartMs),
                    ("end", scene.EndMs));
            }
            var position = 0;
            foreach (var uri in scene.KeyframeUris)
                await Exec(conn, tx, "INSERT INTO scene_keyframes (scene_id, position, s3_uri) VALUES (@id, @pos, @uri)",
                    ct, ("id", ids[j]), ("pos", position++), ("uri", uri));
        }

        foreach (var (i, j) in match.Orphans)
        {
            var orphan = old[i];
            var target = ids[j];
            var targetEdited = (string[])(await Scalar(conn, tx,
                "SELECT COALESCE(array_agg(field), '{}') FROM user_edits WHERE scene_id = @t", ct, ("t", target)))!;
            foreach (var (field, value) in new[] { ("shot_type", orphan.ShotType), ("description", orphan.Description) })
            {
                if (!orphan.Edited.Contains(field) || targetEdited.Contains(field)) continue;
                await Exec(conn, tx, "UPDATE user_edits SET scene_id = @t WHERE scene_id = @o AND field = @f", ct,
                    ("t", target), ("o", orphan.Id), ("f", field));
                await Exec(conn, tx, $"UPDATE scenes SET {field} = @v WHERE id = @t", ct,
                    ("t", target), ("v", (object?)value ?? DBNull.Value));
            }
            // Реплики с правками живут дальше; авто-реплики join нарежет заново.
            await Exec(conn, tx, """
                UPDATE replicas r SET scene_id = @t WHERE r.scene_id = @o
                  AND (r.origin = 'user' OR r.deleted OR EXISTS (SELECT 1 FROM user_edits u WHERE u.replica_id = r.id))
                """, ct, ("t", target), ("o", orphan.Id));
            await Exec(conn, tx, "DELETE FROM scenes WHERE id = @o", ct, ("o", orphan.Id));
        }
        return old.Count == 0 ? Result.Inserted : Result.Matched;
    }

    private static NpgsqlCommand Command(NpgsqlConnection conn, NpgsqlTransaction tx, string sql,
        params (string Name, object Value)[] args)
    {
        var cmd = new NpgsqlCommand(sql, conn, tx);
        foreach (var (name, value) in args) cmd.Parameters.AddWithValue(name, value);
        return cmd;
    }

    private static async Task Exec(NpgsqlConnection conn, NpgsqlTransaction tx, string sql, CancellationToken ct,
        params (string, object)[] args)
    {
        await using var cmd = Command(conn, tx, sql, args);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    private static async Task<object?> Scalar(NpgsqlConnection conn, NpgsqlTransaction tx, string sql,
        CancellationToken ct, params (string, object)[] args)
    {
        await using var cmd = Command(conn, tx, sql, args);
        return await cmd.ExecuteScalarAsync(ct);
    }
}
