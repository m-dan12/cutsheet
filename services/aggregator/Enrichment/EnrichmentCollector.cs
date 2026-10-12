using System.Text.Json;
using Cutsheet.Aggregator.Dialogue;
using Cutsheet.Messaging;
using Npgsql;
using NpgsqlTypes;
using static Cutsheet.Aggregator.Db;

namespace Cutsheet.Aggregator.Enrichment;

/// <summary>
/// Сбор обогащения (FR-A4, FR-A6, FR-A7). На каждую сцену после join ждём два scene.enriched:
/// план (Shot Type) и описание (Scene Description). Значение пишется в scenes и в scene_auto_values;
/// сцена становится ready, когда пришли оба, и enrichment_failed, если один из источников упал
/// (pipeline.failed) или не ответил за таймаут. Когда все сцены проекта в конечном статусе,
/// проект готов к ревью: при неудачном обогащении части сцен его всё равно можно проверить вручную.
///
/// Обработка идёт под блокировкой строки pipeline_state проекта (как и join), поэтому прогресс
/// считается последовательно. События публикуются до фиксации с детерминированными id.
/// </summary>
public sealed class EnrichmentCollector(NpgsqlDataSource db, IEventPublisher bus, ILogger<EnrichmentCollector> log)
{
    private const string Consumer = "aggregator.enrichment";
    private const string Producer = "aggregator";

    /// <summary>Источник обогащения по имени сервиса из pipeline.failed.</summary>
    public static string? SourceOf(string service) => service switch
    {
        "shot-type" => "shot_type",
        "scene-description" => "description",
        _ => null,
    };

    /// <summary>
    /// Сцена ждёт оба результата на запрос <paramref name="requestEventId"/>. Вызывается из join
    /// в его транзакции; повторный join (новые диалоги) перезапрашивает обогащение.
    /// </summary>
    public static async Task RequestAsync(NpgsqlConnection conn, Guid sceneId, Guid requestEventId, CancellationToken ct)
    {
        await ExecAsync(conn, """
            INSERT INTO scene_enrichment (scene_id, source, request_event_id)
            SELECT @s, src, @r FROM unnest(ARRAY['shot_type', 'description']) AS src
            ON CONFLICT (scene_id, source) DO UPDATE SET status = 'pending', request_event_id = excluded.request_event_id,
                requested_at = now(), finished_at = NULL, error = NULL;
            UPDATE scenes SET status = 'enriching', needs_enrichment = false WHERE id = @s;
            """, ct, ("s", sceneId), ("r", requestEventId));
    }

    public async Task OnEnrichedAsync(Envelope e, CancellationToken ct)
    {
        var p = e.Payload;
        var sceneId = Guid.Parse(p.GetProperty("scene_id").GetString()!);
        var source = p.GetProperty("source").GetString()!;
        var value = p.GetProperty(source);
        Guid? request = p.TryGetProperty("request_event_id", out var r) && r.ValueKind == JsonValueKind.String
            ? Guid.Parse(r.GetString()!) : null;

        await using var conn = await db.OpenConnectionAsync(ct);
        await using var tx = await conn.BeginTransactionAsync(ct);
        if (!await BeginAsync(conn, e, ct)) return;

        Guid? pending = null;
        await using (var cmd = Command(conn, """
                         SELECT e.request_event_id FROM scene_enrichment e JOIN scenes s ON s.id = e.scene_id
                         WHERE e.scene_id = @s AND e.source = @src AND s.project_id = @p
                         """, ("s", sceneId), ("src", source), ("p", e.ProjectId)))
            pending = await cmd.ExecuteScalarAsync(ct) as Guid?;
        if (pending is null || (request is { } req && req != pending))
        {
            // Сцена пересоздана повторной детекцией или обогащение перезапрошено: ответ устарел.
            log.LogInformation("stale scene.enriched {Source} for scene {SceneId} skipped", source, sceneId);
            await tx.CommitAsync(ct);
            return;
        }

        string? Str(string name) => p.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
        await ExecAsync(conn, """
            INSERT INTO scene_auto_values (scene_id, field, value, confidence, source, prompt_version, model, updated_at)
            VALUES (@s, @f, @v, @c, @src, @pv, @m, now())
            ON CONFLICT (scene_id, field) DO UPDATE SET value = excluded.value, confidence = excluded.confidence,
                source = excluded.source, prompt_version = excluded.prompt_version, model = excluded.model, updated_at = now();
            UPDATE scene_enrichment SET status = 'done', finished_at = now(), error = NULL WHERE scene_id = @s AND source = @f;
            """, ct, ("s", sceneId), ("f", source),
            ("v", new NpgsqlParameter { NpgsqlDbType = NpgsqlDbType.Jsonb, Value = value.GetRawText() }),
            ("c", p.TryGetProperty("confidence", out var c) && c.ValueKind == JsonValueKind.Number ? (float)c.GetDouble() : (object)DBNull.Value),
            ("src", e.Producer ?? source), ("pv", (object?)Str("prompt_version") ?? DBNull.Value),
            ("m", (object?)Str("model") ?? DBNull.Value));
        // Правка пользователя важнее авто-результата (FR-A5): колонку сцены не трогаем. row_version растёт,
        // чтобы клиент с открытым листом увидел, что сцена изменилась (оптимистичная блокировка, этап 4).
        await ExecAsync(conn, $"""
            UPDATE scenes SET {(source == "shot_type" ? "shot_type" : "description")} = @v, row_version = row_version + 1
            WHERE id = @s AND NOT EXISTS (SELECT 1 FROM user_edits u WHERE u.scene_id = @s AND u.field = @f)
            """, ct, ("s", sceneId), ("f", source), ("v", value.GetString() ?? ""));

        var output = await RefreshAsync(conn, e.ProjectId, e.CorrelationId, [sceneId], e.EventId.ToString(), ct);
        foreach (var o in output) await bus.PublishAsync(o, ct);
        await tx.CommitAsync(ct);
    }

    /// <summary>pipeline.failed от Shot Type или Scene Description на запрос обогащения сцены.</summary>
    public async Task OnFailedAsync(Envelope e, CancellationToken ct)
    {
        var p = e.Payload;
        var source = SourceOf(p.GetProperty("service").GetString() ?? "");
        if (source is null || !p.TryGetProperty("source_event_id", out var se)) return;
        var error = p.GetProperty("error").GetString() ?? "";

        await using var conn = await db.OpenConnectionAsync(ct);
        await using var tx = await conn.BeginTransactionAsync(ct);
        if (!await BeginAsync(conn, e, ct)) return;
        var scenes = new List<Guid>();
        await using (var cmd = Command(conn, """
                         UPDATE scene_enrichment SET status = 'failed', finished_at = now(), error = @err
                         WHERE request_event_id = @r AND source = @src AND status = 'pending'
                         RETURNING scene_id
                         """, ("r", Guid.Parse(se.GetString()!)), ("src", source), ("err", error)))
        await using (var rd = await cmd.ExecuteReaderAsync(ct))
            while (await rd.ReadAsync(ct)) scenes.Add(rd.GetGuid(0));
        log.LogWarning("enrichment {Source} failed for {Count} scene(s) of project {ProjectId}: {Error}",
            source, scenes.Count, e.ProjectId, error);

        var output = await RefreshAsync(conn, e.ProjectId, e.CorrelationId, scenes, e.EventId.ToString(), ct);
        foreach (var o in output) await bus.PublishAsync(o, ct);
        await tx.CommitAsync(ct);
    }

    /// <summary>
    /// Таймаут (FR-A6): если по проекту нет ни одного ответа дольше <paramref name="timeout"/>,
    /// ожидающие результаты считаются неудачными. Отсчёт от последнего ответа, а не от запроса:
    /// сцены обогащаются по очереди, и для длинного фильма последняя сцена ждёт долго.
    /// Возвращает число затронутых проектов; <paramref name="project"/> ограничивает проверку одним проектом.
    /// </summary>
    public async Task<int> ExpireAsync(TimeSpan timeout, CancellationToken ct, Guid? project = null)
    {
        const string stale = """
            SELECT s.project_id FROM scene_enrichment e JOIN scenes s ON s.id = e.scene_id
            WHERE (@p::uuid IS NULL OR s.project_id = @p)
            GROUP BY s.project_id
            HAVING bool_or(e.status = 'pending')
               AND max(greatest(e.requested_at, coalesce(e.finished_at, e.requested_at))) < now() - @t
            """;
        var projects = new List<Guid>();
        await using (var conn = await db.OpenConnectionAsync(ct))
        await using (var cmd = Command(conn, stale, ("p", (object?)project ?? DBNull.Value), ("t", timeout)))
        await using (var rd = await cmd.ExecuteReaderAsync(ct))
            while (await rd.ReadAsync(ct)) projects.Add(rd.GetGuid(0));

        foreach (var p in projects)
        {
            await using var conn = await db.OpenConnectionAsync(ct);
            await using var tx = await conn.BeginTransactionAsync(ct);
            await LockProjectAsync(conn, p, ct);
            // Под блокировкой проверяем ещё раз: ответ мог прийти, пока мы ждали.
            await using (var check = Command(conn, stale, ("p", p), ("t", timeout)))
                if (await check.ExecuteScalarAsync(ct) is null) continue;
            var scenes = new List<Guid>();
            await using (var cmd = Command(conn, """
                             UPDATE scene_enrichment e SET status = 'failed', finished_at = now(), error = 'timeout'
                             FROM scenes s WHERE s.id = e.scene_id AND s.project_id = @p AND e.status = 'pending'
                             RETURNING e.scene_id
                             """, ("p", p)))
            await using (var rd = await cmd.ExecuteReaderAsync(ct))
                while (await rd.ReadAsync(ct)) scenes.Add(rd.GetGuid(0));
            var correlation = await ScalarAsync<object>(conn, "SELECT correlation_id FROM pipeline_state WHERE project_id = @p",
                ct, ("p", p)) as Guid? ?? Guid.Empty;
            log.LogWarning("enrichment timed out for {Count} result(s) of project {ProjectId}", scenes.Count, p);
            var output = await RefreshAsync(conn, p, correlation, scenes.Distinct().ToList(), $"timeout:{Guid.NewGuid()}", ct);
            foreach (var o in output) await bus.PublishAsync(o, ct);
            await tx.CommitAsync(ct);
        }
        return projects.Count;
    }

    /// <summary>Дедупликация и блокировка проекта. false — событие уже обработано.</summary>
    private async Task<bool> BeginAsync(NpgsqlConnection conn, Envelope e, CancellationToken ct)
    {
        if (await ExecAsync(conn, "INSERT INTO processed_events (consumer, event_id) VALUES (@c, @e) ON CONFLICT DO NOTHING",
                ct, ("c", Consumer), ("e", e.EventId)) == 0)
        {
            log.LogInformation("duplicate {EventType} {EventId} skipped", e.EventType, e.EventId);
            return false;
        }
        await LockProjectAsync(conn, e.ProjectId, ct);
        return true;
    }

    /// <summary>Порядок блокировок как в join и SceneSync: сначала строка projects, затем pipeline_state.</summary>
    private static Task LockProjectAsync(NpgsqlConnection conn, Guid p, CancellationToken ct) =>
        ExecAsync(conn, """
            SELECT 1 FROM projects WHERE id = @p FOR UPDATE;
            SELECT 1 FROM pipeline_state WHERE project_id = @p FOR UPDATE;
            """, ct, ("p", p));

    /// <summary>
    /// Пересчитывает статусы сцен по состоянию обогащения и, если какая-то сцена дошла до
    /// конечного статуса, — прогресс проекта (FR-A7). Когда готовы все сцены — проект готов к ревью.
    /// </summary>
    private async Task<List<Envelope>> RefreshAsync(NpgsqlConnection conn, Guid p, Guid correlation, List<Guid> scenes,
        string key, CancellationToken ct)
    {
        if (scenes.Count == 0) return [];
        var finished = await ScalarAsync<long>(conn, """
            WITH x AS (
                SELECT scene_id, CASE WHEN bool_and(status = 'done') THEN 'ready'
                                      WHEN bool_or(status = 'pending') THEN 'enriching'
                                      ELSE 'enrichment_failed' END AS st
                FROM scene_enrichment WHERE scene_id = ANY(@ids) GROUP BY scene_id),
            u AS (UPDATE scenes s SET status = x.st FROM x WHERE s.id = x.scene_id AND s.status <> x.st RETURNING s.status)
            SELECT count(*) FROM u WHERE status IN ('ready', 'enrichment_failed')
            """, ct, ("ids", scenes.ToArray()));
        if (finished == 0) return [];

        long total = 0, done = 0, failed = 0;
        await using (var cmd = Command(conn, """
                         SELECT count(*), count(*) FILTER (WHERE status IN ('ready', 'enrichment_failed')),
                                count(*) FILTER (WHERE status = 'enrichment_failed')
                         FROM scenes WHERE project_id = @p AND status IN ('enriching', 'ready', 'enrichment_failed')
                         """, ("p", p)))
        await using (var rd = await cmd.ExecuteReaderAsync(ct))
            if (await rd.ReadAsync(ct)) (total, done, failed) = (rd.GetInt64(0), rd.GetInt64(1), rd.GetInt64(2));

        var output = new List<Envelope>();
        Envelope Status(string suffix, object payload) =>
            Envelope.Create("project.status-changed", p, correlation, payload, Producer, DeterministicGuid.Create($"{key}:{suffix}"));
        if (done < total)
        {
            output.Add(Status("progress", new { stage = "enrichment", status = "running", progress = Math.Round((double)done / total, 3) }));
            return output;
        }

        string? note = failed > 0 ? $"обогащение не удалось для {failed} из {total} сцен" : null;
        await ExecAsync(conn, "UPDATE pipeline_state SET stage = 'review', updated_at = now() WHERE project_id = @p", ct, ("p", p));
        log.LogInformation("project {ProjectId} ready for review: {Total} scenes, {Failed} without enrichment", p, total, failed);
        output.Add(Status("enrichment-done", new { stage = "enrichment", status = "done", progress = 1.0, error = note }));
        output.Add(Status("review", new { stage = "review", status = "ready_for_review", progress = 1.0, error = note }));
        return output;
    }
}
