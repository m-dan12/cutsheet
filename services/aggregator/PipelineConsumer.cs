using System.Text.Json;
using Cutsheet.Aggregator.Dialogue;
using Cutsheet.Aggregator.Enrichment;
using Cutsheet.Messaging;
using Npgsql;

namespace Cutsheet.Aggregator;

public sealed class PipelineConsumer(EventBus bus, NpgsqlDataSource db, DialogueJoin join,
    EnrichmentCollector enrichment, ILogger<PipelineConsumer> logger)
    : EventConsumer(bus, logger)
{
    private const string Consumer = "aggregator";

    protected override string[] Topics => ["scenes.detected", "dialogue.aligned", "scene.enriched", "pipeline.failed"];
    protected override string GroupId => Consumer;

    protected override async Task HandleAsync(Envelope e, CancellationToken ct)
    {
        switch (e.EventType)
        {
            case "scenes.detected":
                var count = await SaveScenes(e, ct);
                if (count is not null)
                {
                    Log.LogInformation("scenes.detected: {Count} scenes for project {ProjectId}", count, e.ProjectId);
                    await Bus.PublishAsync("project.status-changed", e.ProjectId, e.CorrelationId,
                        new { stage = "scenes", status = "done", progress = 1.0 }, ct);
                }
                // Join после записи сцен; у join своя дедупликация, поэтому он идёт и для дубля
                // (на случай падения между записью сцен и join).
                await join.OnScenesDetectedAsync(e, ct);
                break;
            case "dialogue.aligned":
                await join.OnDialogueAlignedAsync(e, ct);
                break;
            case "scene.enriched":
                await enrichment.OnEnrichedAsync(e, ct);
                break;
            case "pipeline.failed" when IsEnrichmentRequest(e):
                // Сбой обогащения одной сцены не валит проект: сцена получает enrichment_failed (FR-A6).
                await enrichment.OnFailedAsync(e, ct);
                break;
            case "pipeline.failed":
                var error = e.Payload.GetProperty("error").GetString();
                var service = e.Payload.GetProperty("service").GetString() ?? "";
                Log.LogWarning("pipeline.failed from {Service}: {Error}", service, error);
                if (!await SaveFailure(e, error, ct)) return;
                await Bus.PublishAsync("project.status-changed", e.ProjectId, e.CorrelationId,
                    new { stage = StageOf(service), status = "failed", error }, ct);
                break;
        }
    }

    /// <summary>
    /// Событие ушло в DLQ после всех попыток: проект не должен навсегда зависнуть в «обработке»,
    /// поэтому публикуем pipeline.failed. Для самого pipeline.failed — нет, иначе цикл.
    /// </summary>
    protected override Task OnFailedAsync(Envelope e, Exception error, bool retryable, CancellationToken ct) =>
        e.EventType == "pipeline.failed"
            ? Task.CompletedTask
            : Bus.PublishAsync("pipeline.failed", e.ProjectId, e.CorrelationId, new
            {
                service = Consumer,
                source_event_id = e.EventId,
                source_event_type = e.EventType,
                error = $"{error.GetType().Name}: {error.Message}",
                retryable,
            }, ct);

    /// <summary>Сохраняет сцены одной транзакцией. null — событие уже обработано.</summary>
    private async Task<int?> SaveScenes(Envelope e, CancellationToken ct)
    {
        var p = e.Payload;
        var scenes = p.GetProperty("scenes");
        await using var conn = await db.OpenConnectionAsync(ct);
        await using var tx = await conn.BeginTransactionAsync(ct);
        if (!await Postgres.TryMarkProcessedAsync(conn, tx, Consumer, e.EventId, ct)) return null;

        if (!await ProjectExists(conn, tx, e.ProjectId, ct))
        {
            // Например, ролик отправлен tools/dev_pipeline.py в обход Project API.
            Log.LogWarning("project {ProjectId} not found, scenes not stored", e.ProjectId);
            await tx.CommitAsync(ct);
            return scenes.GetArrayLength();
        }

        await Exec(conn, tx, "UPDATE projects SET fps = $2, duration_ms = $3 WHERE id = $1", ct,
            e.ProjectId, p.GetProperty("fps").GetDouble(), p.GetProperty("duration_ms").GetInt64());
        var detected = scenes.EnumerateArray().Select(scene => new DetectedScene(
            scene.GetProperty("index").GetInt32(), scene.GetProperty("start_ms").GetInt64(),
            scene.GetProperty("end_ms").GetInt64(),
            scene.GetProperty("keyframe_uris").EnumerateArray().Select(u => u.GetString()!).ToList())).ToList();
        var result = await SceneSync.ApplyAsync(conn, tx, e.ProjectId, detected, ct);
        if (result == SceneSync.Result.KeptUserStructure)
            Log.LogInformation("project {ProjectId}: scene structure edited by user, re-detection keeps it", e.ProjectId);

        await Exec(conn, tx, """
            INSERT INTO pipeline_state (project_id, correlation_id, scenes_detected, stage, error, updated_at)
            VALUES ($1, $2, true, 'scenes', NULL, now())
            ON CONFLICT (project_id) DO UPDATE
               SET correlation_id = $2, scenes_detected = true, stage = 'scenes', error = NULL, updated_at = now()
            """, ct, e.ProjectId, e.CorrelationId);
        await tx.CommitAsync(ct);
        return scenes.GetArrayLength();
    }

    private async Task<bool> SaveFailure(Envelope e, string? error, CancellationToken ct)
    {
        await using var conn = await db.OpenConnectionAsync(ct);
        await using var tx = await conn.BeginTransactionAsync(ct);
        if (!await Postgres.TryMarkProcessedAsync(conn, tx, Consumer, e.EventId, ct)) return false;
        if (await ProjectExists(conn, tx, e.ProjectId, ct))
            await Exec(conn, tx, """
                INSERT INTO pipeline_state (project_id, correlation_id, error, updated_at)
                VALUES ($1, $2, $3, now())
                ON CONFLICT (project_id) DO UPDATE SET error = $3, updated_at = now()
                """, ct, e.ProjectId, e.CorrelationId, (object?)error ?? DBNull.Value);
        await tx.CommitAsync(ct);
        return true;
    }

    private static bool IsEnrichmentRequest(Envelope e) =>
        e.Payload.TryGetProperty("source_event_type", out var t) && t.GetString() == "scene.ready-for-enrichment";

    /// <summary>Этап пайплайна по имени упавшего сервиса.</summary>
    private static string StageOf(string service) => service switch
    {
        "transcription" or "script-parser" => "dialogue",
        "shot-type" or "scene-description" => "enrichment",
        "export" => "export",
        _ => "scenes",
    };

    private static async Task<bool> ProjectExists(NpgsqlConnection conn, NpgsqlTransaction tx, Guid id,
        CancellationToken ct)
    {
        await using var cmd = new NpgsqlCommand("SELECT 1 FROM projects WHERE id = $1", conn, tx);
        cmd.Parameters.AddWithValue(id);
        return await cmd.ExecuteScalarAsync(ct) is not null;
    }

    private static async Task Exec(NpgsqlConnection conn, NpgsqlTransaction tx, string sql, CancellationToken ct,
        params object[] args)
    {
        await using var cmd = new NpgsqlCommand(sql, conn, tx);
        foreach (var a in args) cmd.Parameters.AddWithValue(a);
        await cmd.ExecuteNonQueryAsync(ct);
    }
}
