using System.Text.Json;
using Cutsheet.Aggregator.Dialogue;
using Cutsheet.Aggregator.Enrichment;
using Cutsheet.Messaging;
using Microsoft.Extensions.Logging.Abstractions;
using Npgsql;
using Xunit;

namespace Cutsheet.Aggregator.Tests;

public sealed class EnrichmentCollectorTests : IAsyncLifetime
{
    private sealed class CapturingPublisher : IEventPublisher
    {
        public List<Envelope> Events { get; } = [];
        public Task PublishAsync(Envelope e, CancellationToken ct) { Events.Add(e); return Task.CompletedTask; }
    }

    private readonly NpgsqlDataSource _db = NpgsqlDataSource.Create(Environment.GetEnvironmentVariable("CUTSHEET_TEST_PG") ?? "Host=none");
    private readonly CapturingPublisher _bus = new();
    private readonly Guid _project = Guid.NewGuid();
    private readonly EnrichmentCollector _collector;
    private List<Envelope> _requests = [];

    public EnrichmentCollectorTests() => _collector = new EnrichmentCollector(_db, _bus, NullLogger<EnrichmentCollector>.Instance);

    /// <summary>Проект с двумя сценами после join: на каждую опубликован scene.ready-for-enrichment.</summary>
    public async Task InitializeAsync()
    {
        if (Environment.GetEnvironmentVariable("CUTSHEET_TEST_PG") is null) return;
        await Sql("INSERT INTO projects (id, owner_id, name) VALUES ($1, gen_random_uuid(), 'test')");
        await Sql("""
            INSERT INTO scenes (id, project_id, idx, start_ms, end_ms)
            VALUES (gen_random_uuid(), $1, 0, 0, 2000), (gen_random_uuid(), $1, 1, 2000, 5000)
            """);
        var join = new DialogueJoin(_db, _bus, NullLogger<DialogueJoin>.Instance);
        await join.OnScenesDetectedAsync(Event("scenes.detected", new { scenes = Array.Empty<object>() }), default);
        await join.OnDialogueAlignedAsync(Event("dialogue.aligned", new { replicas = Array.Empty<object>() }), default);
        _requests = _bus.Events.Where(e => e.EventType == "scene.ready-for-enrichment").OrderBy(Index).ToList();
        _bus.Events.Clear();
    }

    public async Task DisposeAsync() => await _db.DisposeAsync();

    private static int Index(Envelope e) => e.Payload.GetProperty("index").GetInt32();

    private async Task Sql(string sql)
    {
        await using var cmd = _db.CreateCommand(sql);
        cmd.Parameters.AddWithValue(_project);
        await cmd.ExecuteNonQueryAsync();
    }

    private Envelope Event(string type, object payload, string producer = "test") =>
        new(Guid.NewGuid(), type, 1, _project, Guid.NewGuid(), DateTimeOffset.UtcNow,
            JsonSerializer.SerializeToElement(payload), producer);

    private Envelope Enriched(int scene, string source, string value, Guid? request = null) =>
        Event("scene.enriched", source == "shot_type"
            ? new Dictionary<string, object>
            {
                ["scene_id"] = SceneId(scene), ["source"] = source, ["shot_type"] = value, ["confidence"] = 0.8,
                ["prompt_version"] = "shot-rules-v1", ["model"] = "mediapipe", ["request_event_id"] = request ?? _requests[scene].EventId,
            }
            : new Dictionary<string, object>
            {
                ["scene_id"] = SceneId(scene), ["source"] = source, ["description"] = value,
                ["prompt_version"] = "scene-description-v1", ["model"] = "qwen2.5vl:7b",
                ["request_event_id"] = request ?? _requests[scene].EventId,
            }, source == "shot_type" ? "shot-type" : "scene-description");

    private string SceneId(int scene) => _requests[scene].Payload.GetProperty("scene_id").GetString()!;

    private Envelope Failed(int scene, string service) => Event("pipeline.failed", new
    {
        service, error = "LLMError: unavailable", source_event_id = _requests[scene].EventId,
        source_event_type = "scene.ready-for-enrichment", retryable = true,
    }, service);

    private async Task<List<(string Status, string? Shot, string? Description)>> ScenesAsync()
    {
        await using var cmd = _db.CreateCommand("SELECT status, shot_type, description FROM scenes WHERE project_id = $1 ORDER BY idx");
        cmd.Parameters.AddWithValue(_project);
        var rows = new List<(string, string?, string?)>();
        await using var r = await cmd.ExecuteReaderAsync();
        while (await r.ReadAsync()) rows.Add((r.GetString(0), r.IsDBNull(1) ? null : r.GetString(1), r.IsDBNull(2) ? null : r.GetString(2)));
        return rows;
    }

    private List<(string Stage, string Status, double? Progress)> Statuses() => _bus.Events
        .Where(e => e.EventType == "project.status-changed")
        .Select(e => (e.Payload.GetProperty("stage").GetString()!, e.Payload.GetProperty("status").GetString()!,
            e.Payload.TryGetProperty("progress", out var p) ? p.GetDouble() : (double?)null))
        .ToList();

    [PostgresFact]
    public async Task CollectsBothResultsThenProjectIsReadyForReview()
    {
        Assert.Equal(2, _requests.Count);
        Assert.Equal([("enriching", null, null), ("enriching", null, null)], await ScenesAsync());

        await _collector.OnEnrichedAsync(Enriched(0, "shot_type", "medium"), default);
        Assert.Empty(_bus.Events);  // у сцены ещё нет описания
        var description = Enriched(0, "description", "Иван сидит у окна.");
        await _collector.OnEnrichedAsync(description, default);
        Assert.Equal([("enrichment", "running", 0.5)], Statuses());

        await _collector.OnEnrichedAsync(description, default);  // повторная доставка
        Assert.Single(_bus.Events);

        await _collector.OnEnrichedAsync(Enriched(1, "description", "Двое на перроне."), default);
        await _collector.OnEnrichedAsync(Enriched(1, "shot_type", "wide"), default);
        Assert.Equal([("ready", "medium", "Иван сидит у окна."), ("ready", "wide", "Двое на перроне.")], await ScenesAsync());
        Assert.Equal([("enrichment", "running", 0.5), ("enrichment", "done", 1.0), ("review", "ready_for_review", 1.0)],
            Statuses());

        await using var cmd = _db.CreateCommand("""
            SELECT v.field, v.value::text, v.source, v.prompt_version, v.model, v.confidence FROM scene_auto_values v
            JOIN scenes s ON s.id = v.scene_id WHERE s.project_id = $1 AND s.idx = 0 ORDER BY v.field
            """);
        cmd.Parameters.AddWithValue(_project);
        await using var r = await cmd.ExecuteReaderAsync();
        Assert.True(await r.ReadAsync());
        Assert.Equal(("description", "\"Иван сидит у окна.\"", "scene-description", "scene-description-v1", "qwen2.5vl:7b"),
            (r.GetString(0), r.GetString(1), r.GetString(2), r.GetString(3), r.GetString(4)));
        Assert.True(r.IsDBNull(5));
        Assert.True(await r.ReadAsync());
        Assert.Equal(("shot_type", "\"medium\"", 0.8f), (r.GetString(0), r.GetString(1), r.GetFloat(5)));
    }

    [PostgresFact]
    public async Task FailuresAndTimeoutLeaveProjectReviewable()
    {
        await _collector.OnEnrichedAsync(Enriched(0, "shot_type", "close"), default);
        await _collector.OnFailedAsync(Failed(0, "scene-description"), default);
        Assert.Equal(("enrichment_failed", "close", null), (await ScenesAsync())[0]);
        Assert.Equal([("enrichment", "running", 0.5)], Statuses());

        // Ответы по сцене 1 не приходят; ждать без результатов дольше таймаута — сбой.
        Assert.Equal(0, await _collector.ExpireAsync(TimeSpan.FromHours(1), default, _project));
        await _collector.ExpireAsync(TimeSpan.FromDays(3650), default);  // проверка по всем проектам, как в таймере
        Assert.Equal(1, await _collector.ExpireAsync(TimeSpan.Zero, default, _project));
        Assert.Equal([("enrichment_failed", "close", null), ("enrichment_failed", null, null)], await ScenesAsync());
        var last = _bus.Events[^1];
        Assert.Equal("ready_for_review", last.Payload.GetProperty("status").GetString());
        Assert.Equal("обогащение не удалось для 2 из 2 сцен", last.Payload.GetProperty("error").GetString());

        // Опоздавший ответ всё равно принимается.
        await _collector.OnEnrichedAsync(Enriched(1, "shot_type", "wide"), default);
        // Сбой обогащения сцены не считается ошибкой пайплайна проекта.
        await using var cmd = _db.CreateCommand("SELECT error IS NULL FROM pipeline_state WHERE project_id = $1");
        cmd.Parameters.AddWithValue(_project);
        Assert.Equal(true, await cmd.ExecuteScalarAsync());
    }

    [PostgresFact]
    public async Task StaleResultsAreIgnoredAndUserEditsWin()
    {
        await _collector.OnEnrichedAsync(Enriched(0, "shot_type", "wide", request: Guid.NewGuid()), default);
        Assert.Equal(("enriching", null, null), (await ScenesAsync())[0]);

        await Sql("""
            INSERT INTO user_edits (id, scene_id, field, value, user_id)
            SELECT gen_random_uuid(), id, 'description', '"Правка"', gen_random_uuid() FROM scenes WHERE project_id = $1 AND idx = 0
            """);
        await Sql("UPDATE scenes SET description = 'Правка' WHERE project_id = $1 AND idx = 0");
        await _collector.OnEnrichedAsync(Enriched(0, "description", "Авто-описание."), default);
        await _collector.OnEnrichedAsync(Enriched(0, "shot_type", "close"), default);
        Assert.Equal(("ready", "close", "Правка"), (await ScenesAsync())[0]);
    }
}
