using System.Text.Json;
using Cutsheet.Messaging;
using Npgsql;
using NpgsqlTypes;

namespace Cutsheet.Aggregator.Dialogue;

/// <summary>
/// Join сцен и диалогов (FR-A1–A3). Оба входа (scenes.detected, dialogue.aligned) сохраняются
/// в join_inputs; когда есть оба, реплики режутся по сценам, пишутся в replicas/roles и на каждую
/// сцену публикуется scene.ready-for-enrichment.
///
/// Всё в одной транзакции с блокировкой строки pipeline_state проекта, поэтому одновременная
/// обработка двух входов не запускает нарезку дважды. События публикуются до фиксации транзакции
/// с детерминированными id: если сервис упадёт между публикацией и commit, повтор даст те же id,
/// и потребители отбросят дубликаты (ТЗ 3.3).
/// </summary>
public sealed class DialogueJoin(NpgsqlDataSource db, IEventPublisher bus, ILogger<DialogueJoin> log)
{
    private const string Consumer = "aggregator.dialogue-join";
    private const string Producer = "aggregator";

    public Task OnScenesDetectedAsync(Envelope e, CancellationToken ct) => AcceptAsync(e, "scenes", ct);

    public Task OnDialogueAlignedAsync(Envelope e, CancellationToken ct) => AcceptAsync(e, "dialogue", ct);

    private async Task AcceptAsync(Envelope e, string kind, CancellationToken ct)
    {
        await using var conn = await db.OpenConnectionAsync(ct);
        await using var tx = await conn.BeginTransactionAsync(ct);
        var p = e.ProjectId;

        if (await ScalarAsync<long>(conn, "SELECT count(*) FROM projects WHERE id = @p", ct, ("p", p)) == 0)
        {
            // Проект создаёт Project API; без него join невозможен (FK). Событие пропускаем.
            log.LogWarning("project {ProjectId} not found, {Kind} input ignored", p, kind);
            return;
        }
        if (await ExecAsync(conn, "INSERT INTO processed_events (consumer, event_id) VALUES (@c, @e) ON CONFLICT DO NOTHING",
                ct, ("c", Consumer), ("e", e.EventId)) == 0)
        {
            log.LogInformation("duplicate {EventType} {EventId} skipped", e.EventType, e.EventId);
            return;
        }

        await ExecAsync(conn, """
            INSERT INTO pipeline_state (project_id, correlation_id) VALUES (@p, @c) ON CONFLICT (project_id) DO NOTHING;
            SELECT 1 FROM pipeline_state WHERE project_id = @p FOR UPDATE;
            """, ct, ("p", p), ("c", e.CorrelationId));
        await ExecAsync(conn, """
            INSERT INTO join_inputs (project_id, kind, event_id, correlation_id, payload)
            VALUES (@p, @k, @e, @c, @payload)
            ON CONFLICT (project_id, kind) DO UPDATE SET event_id = excluded.event_id,
                correlation_id = excluded.correlation_id, payload = excluded.payload, received_at = now()
            """, ct, ("p", p), ("k", kind), ("e", e.EventId), ("c", e.CorrelationId),
            ("payload", new NpgsqlParameter { NpgsqlDbType = NpgsqlDbType.Jsonb, Value = e.Payload.GetRawText() }));
        var flag = kind == "scenes" ? "scenes_detected" : "dialogue_aligned";
        await ExecAsync(conn, $"UPDATE pipeline_state SET {flag} = true, updated_at = now() WHERE project_id = @p",
            ct, ("p", p));

        var output = new List<Envelope>();
        if (kind == "dialogue")
        {
            var replicas = e.Payload.GetProperty("replicas").GetArrayLength();
            log.LogInformation("dialogue.aligned: {Count} replicas for project {ProjectId}", replicas, p);
            output.Add(Envelope.Create("project.status-changed", p, e.CorrelationId,
                new { stage = "dialogue", status = "done", progress = 1.0 }, Producer,
                DeterministicGuid.Create($"{e.EventId}:status")));
        }
        output.AddRange(await TryJoinAsync(conn, e, ct));

        foreach (var o in output) await bus.PublishAsync(o, ct);
        await tx.CommitAsync(ct);
    }

    private async Task<List<Envelope>> TryJoinAsync(NpgsqlConnection conn, Envelope trigger, CancellationToken ct)
    {
        var p = trigger.ProjectId;
        var inputs = new Dictionary<string, (Guid EventId, JsonElement Payload)>();
        await using (var cmd = Command(conn, "SELECT kind, event_id, payload::text FROM join_inputs WHERE project_id = @p",
                         ("p", p)))
        await using (var r = await cmd.ExecuteReaderAsync(ct))
            while (await r.ReadAsync(ct))
                inputs[r.GetString(0)] = (r.GetGuid(1), JsonDocument.Parse(r.GetString(2)).RootElement.Clone());
        if (!inputs.TryGetValue("scenes", out var scenesIn) || !inputs.TryGetValue("dialogue", out var dialogueIn))
        {
            log.LogInformation("join for project {ProjectId}: waiting for {Missing}", p,
                inputs.ContainsKey("scenes") ? "dialogue.aligned" : "scenes.detected");
            return [];
        }

        // Сцены пишет PipelineConsumer до вызова join (этап 1); при повторной детекции они
        // пересоздаются, и join режет реплики заново по сохранённому dialogue.aligned.
        var scenes = await LoadScenesAsync(conn, p, ct);
        var replicas = dialogueIn.Payload.GetProperty("replicas").EnumerateArray().Select(ParseReplica).ToList();
        var sliced = ReplicaSlicer.Slice(scenes.Select(s => s.Span).ToList(), replicas);

        var roleIds = await UpsertRolesAsync(conn, p, replicas, ct);
        var kept = await ReplaceReplicasAsync(conn, p, scenes, sliced, roleIds, ct);
        await ExecAsync(conn, """
            UPDATE pipeline_state SET stage = 'enrichment', joined_scenes_event_id = @s,
                joined_dialogue_event_id = @d, error = NULL, updated_at = now()
            WHERE project_id = @p
            """, ct, ("p", p), ("s", scenesIn.EventId), ("d", dialogueIn.EventId));
        log.LogInformation("join done for project {ProjectId}: {Replicas} replicas in {Scenes} scenes, {Kept} edited kept",
            p, replicas.Count, scenes.Count, kept);

        var key = $"{scenesIn.EventId}:{dialogueIn.EventId}";
        var output = scenes.Select(s => Envelope.Create("scene.ready-for-enrichment", p, trigger.CorrelationId, new
        {
            scene_id = s.Id,
            index = s.Span.Index,
            start_ms = s.Span.StartMs,
            end_ms = s.Span.EndMs,
            keyframe_uris = s.Keyframes,
            // Кратко, для контекста LLM в Scene Description.
            replicas = sliced[s.Span.Index].Select(rep => new
            {
                start_ms = rep.StartMs, end_ms = rep.EndMs, role = rep.Role, text = rep.Text,
                script_line_id = rep.ScriptLineId,
            }),
        }, Producer, DeterministicGuid.Create($"{key}:scene:{s.Span.Index}"))).ToList();
        output.Add(Envelope.Create("project.status-changed", p, trigger.CorrelationId,
            new { stage = "enrichment", status = "running", progress = 0.0 }, Producer,
            DeterministicGuid.Create($"{key}:status")));
        return output;
    }

    private sealed record SceneRow(Guid Id, SceneSpan Span, List<string> Keyframes);

    private static async Task<List<SceneRow>> LoadScenesAsync(NpgsqlConnection conn, Guid p, CancellationToken ct)
    {
        var rows = new List<SceneRow>();
        await using (var cmd = Command(conn, "SELECT id, idx, start_ms, end_ms FROM scenes WHERE project_id = @p ORDER BY idx", ("p", p)))
        await using (var r = await cmd.ExecuteReaderAsync(ct))
            while (await r.ReadAsync(ct))
                rows.Add(new SceneRow(r.GetGuid(0), new SceneSpan(r.GetInt32(1), r.GetInt64(2), r.GetInt64(3)), []));
        var byId = rows.ToDictionary(s => s.Id);
        await using (var cmd = Command(conn, """
                         SELECT k.scene_id, k.s3_uri FROM scene_keyframes k JOIN scenes s ON s.id = k.scene_id
                         WHERE s.project_id = @p ORDER BY k.scene_id, k.position
                         """, ("p", p)))
        await using (var r = await cmd.ExecuteReaderAsync(ct))
            while (await r.ReadAsync(ct))
                byId[r.GetGuid(0)].Keyframes.Add(r.GetString(1));
        return rows;
    }

    private static async Task<Dictionary<string, Guid>> UpsertRolesAsync(NpgsqlConnection conn, Guid p,
        List<Replica> replicas, CancellationToken ct)
    {
        foreach (var name in replicas.Select(r => r.Role).OfType<string>().Distinct())
            await ExecAsync(conn, "INSERT INTO roles (id, project_id, name) VALUES (@id, @p, @n) ON CONFLICT (project_id, name) DO NOTHING",
                ct, ("id", DeterministicGuid.Create($"{p}:role:{name}")), ("p", p), ("n", name));
        var ids = new Dictionary<string, Guid>();
        await using var cmd = Command(conn, "SELECT name, id FROM roles WHERE project_id = @p", ("p", p));
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct)) ids[r.GetString(0)] = r.GetGuid(1);
        return ids;
    }

    /// <summary>
    /// Авто-реплики заменяются новыми; реплики с правками пользователя остаются (FR-A5), и новая
    /// реплика с тем же script_line_id не добавляется. Полное слияние правок — этап 4.
    /// </summary>
    private static async Task<int> ReplaceReplicasAsync(NpgsqlConnection conn, Guid p, List<SceneRow> scenes,
        Dictionary<int, List<Replica>> sliced, Dictionary<string, Guid> roleIds, CancellationToken ct)
    {
        await ExecAsync(conn, """
            DELETE FROM replicas r USING scenes s
            WHERE r.scene_id = s.id AND s.project_id = @p
              AND NOT EXISTS (SELECT 1 FROM user_edits u WHERE u.replica_id = r.id)
            """, ct, ("p", p));
        var editedLines = new HashSet<string>();
        var kept = 0;
        await using (var cmd = Command(conn, "SELECT r.script_line_id FROM replicas r JOIN scenes s ON s.id = r.scene_id WHERE s.project_id = @p",
                         ("p", p)))
        await using (var r = await cmd.ExecuteReaderAsync(ct))
            while (await r.ReadAsync(ct))
            {
                kept++;
                if (!r.IsDBNull(0)) editedLines.Add(r.GetString(0));
            }

        await using var copy = await conn.BeginBinaryImportAsync(
            "COPY replicas (id, scene_id, idx, start_ms, end_ms, role_id, text, spoken_text, script_line_id, confidence, matched) FROM STDIN (FORMAT BINARY)",
            ct);
        foreach (var scene in scenes)
        {
            var idx = 0;
            foreach (var rep in sliced[scene.Span.Index])
            {
                if (rep.ScriptLineId is { } lid && editedLines.Contains(lid)) continue;
                await copy.StartRowAsync(ct);
                await copy.WriteAsync(Guid.NewGuid(), NpgsqlDbType.Uuid, ct);
                await copy.WriteAsync(scene.Id, NpgsqlDbType.Uuid, ct);
                await copy.WriteAsync(idx++, NpgsqlDbType.Integer, ct);
                await copy.WriteAsync(rep.StartMs, NpgsqlDbType.Bigint, ct);
                await copy.WriteAsync(rep.EndMs, NpgsqlDbType.Bigint, ct);
                if (rep.Role is { } role) await copy.WriteAsync(roleIds[role], NpgsqlDbType.Uuid, ct);
                else await copy.WriteNullAsync(ct);
                await copy.WriteAsync(rep.Text, NpgsqlDbType.Text, ct);
                await WriteTextAsync(copy, rep.SpokenText, ct);
                await WriteTextAsync(copy, rep.ScriptLineId, ct);
                if (rep.Confidence is { } c) await copy.WriteAsync((float)c, NpgsqlDbType.Real, ct);
                else await copy.WriteNullAsync(ct);
                await copy.WriteAsync(rep.Matched, NpgsqlDbType.Boolean, ct);
            }
        }
        await copy.CompleteAsync(ct);
        return kept;
    }

    private static Task WriteTextAsync(NpgsqlBinaryImporter copy, string? value, CancellationToken ct) =>
        value is null ? copy.WriteNullAsync(ct) : copy.WriteAsync(value, NpgsqlDbType.Text, ct);

    private static Replica ParseReplica(JsonElement r)
    {
        string? Str(string name) => r.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
        return new Replica(
            r.GetProperty("start_ms").GetInt64(),
            r.GetProperty("end_ms").GetInt64(),
            Str("role"),
            r.GetProperty("text").GetString() ?? "",
            Str("spoken_text"),
            Str("script_line_id"),
            r.TryGetProperty("confidence", out var c) && c.ValueKind == JsonValueKind.Number ? c.GetDouble() : null,
            r.TryGetProperty("matched", out var m) && m.ValueKind == JsonValueKind.True);
    }

    private static NpgsqlCommand Command(NpgsqlConnection conn, string sql, params (string Name, object Value)[] args)
    {
        var cmd = new NpgsqlCommand(sql, conn);
        foreach (var (name, value) in args)
        {
            if (value is NpgsqlParameter prm) { prm.ParameterName = name; cmd.Parameters.Add(prm); }
            else cmd.Parameters.AddWithValue(name, value);
        }
        return cmd;
    }

    private static async Task<int> ExecAsync(NpgsqlConnection conn, string sql, CancellationToken ct,
        params (string, object)[] args)
    {
        await using var cmd = Command(conn, sql, args);
        return await cmd.ExecuteNonQueryAsync(ct);
    }

    private static async Task<T> ScalarAsync<T>(NpgsqlConnection conn, string sql, CancellationToken ct,
        params (string, object)[] args)
    {
        await using var cmd = Command(conn, sql, args);
        return (T)(await cmd.ExecuteScalarAsync(ct))!;
    }
}
