using System.Text.Json;
using Cutsheet.Messaging;
using Npgsql;

namespace Cutsheet.Aggregator;

public sealed class PipelineConsumer(EventBus bus, NpgsqlDataSource db, ILogger<PipelineConsumer> logger)
    : EventConsumer(bus, logger)
{
    private const string Consumer = "aggregator";

    protected override string[] Topics => ["scenes.detected", "pipeline.failed"];
    protected override string GroupId => Consumer;

    protected override async Task HandleAsync(Envelope e, CancellationToken ct)
    {
        switch (e.EventType)
        {
            case "scenes.detected":
                var count = await SaveScenes(e, ct);
                if (count is null) return; // дубль
                Log.LogInformation("scenes.detected: {Count} scenes for project {ProjectId}", count, e.ProjectId);
                await Bus.PublishAsync("project.status-changed", e.ProjectId, e.CorrelationId,
                    new { stage = "scenes", status = "done", progress = 1.0 }, ct);
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
        // Повторная детекция заменяет сцены целиком. Сохранение правок при перезапуске — этап 4 (FR-A5).
        await Exec(conn, tx, "DELETE FROM scenes WHERE project_id = $1", ct, e.ProjectId);

        foreach (var scene in scenes.EnumerateArray())
        {
            var sceneId = Guid.NewGuid();
            await Exec(conn, tx,
                "INSERT INTO scenes (id, project_id, idx, start_ms, end_ms) VALUES ($1, $2, $3, $4, $5)", ct,
                sceneId, e.ProjectId, scene.GetProperty("index").GetInt32(),
                scene.GetProperty("start_ms").GetInt64(), scene.GetProperty("end_ms").GetInt64());
            var position = 0;
            foreach (var uri in scene.GetProperty("keyframe_uris").EnumerateArray())
                await Exec(conn, tx,
                    "INSERT INTO scene_keyframes (scene_id, position, s3_uri) VALUES ($1, $2, $3)", ct,
                    sceneId, position++, uri.GetString()!);
        }

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
