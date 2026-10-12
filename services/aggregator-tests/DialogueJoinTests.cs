using System.Text.Json;
using Cutsheet.Aggregator.Dialogue;
using Microsoft.Extensions.Logging.Abstractions;
using Npgsql;
using Xunit;

namespace Cutsheet.Aggregator.Tests;

/// <summary>Тест с настоящим PostgreSQL: строка подключения в CUTSHEET_TEST_PG, миграции из db/migrations применены.</summary>
public sealed class PostgresFactAttribute : FactAttribute
{
    public PostgresFactAttribute()
    {
        if (string.IsNullOrEmpty(Environment.GetEnvironmentVariable("CUTSHEET_TEST_PG")))
            Skip = "CUTSHEET_TEST_PG is not set";
    }
}

public sealed class DialogueJoinTests : IAsyncLifetime
{
    private sealed class CapturingPublisher : IEventPublisher
    {
        public List<Envelope> Events { get; } = [];
        public Task PublishAsync(Envelope e, CancellationToken ct) { Events.Add(e); return Task.CompletedTask; }
    }

    private readonly NpgsqlDataSource _db = NpgsqlDataSource.Create(Environment.GetEnvironmentVariable("CUTSHEET_TEST_PG") ?? "Host=none");
    private readonly CapturingPublisher _bus = new();
    private readonly Guid _project = Guid.NewGuid();
    private readonly DialogueJoin _join;

    public DialogueJoinTests() => _join = new DialogueJoin(_db, _bus, NullLogger<DialogueJoin>.Instance);

    public async Task InitializeAsync()
    {
        if (Environment.GetEnvironmentVariable("CUTSHEET_TEST_PG") is null) return;
        await using var cmd = _db.CreateCommand("INSERT INTO projects (id, owner_id, name) VALUES ($1, $2, 'test')");
        cmd.Parameters.AddWithValue(_project);
        cmd.Parameters.AddWithValue(Guid.NewGuid());
        await cmd.ExecuteNonQueryAsync();
    }

    public async Task DisposeAsync() => await _db.DisposeAsync();

    private Envelope Event(string type, object payload, Guid? project = null) =>
        new(Guid.NewGuid(), type, 1, project ?? _project, Guid.NewGuid(), DateTimeOffset.UtcNow,
            JsonSerializer.SerializeToElement(payload), "test");

    private static object ScenesPayload => new
    {
        fps = 25.0, duration_ms = 9000,
        scenes = new object[]
        {
            new { index = 0, start_ms = 0, end_ms = 2000, keyframe_uris = new[] { "s3://cutsheet/f/0_0.jpg" } },
            new { index = 1, start_ms = 2000, end_ms = 5000, keyframe_uris = new[] { "s3://cutsheet/f/1_0.jpg" } },
            new { index = 2, start_ms = 5000, end_ms = 9000, keyframe_uris = Array.Empty<string>() },
        },
    };

    private static object DialoguePayload(string firstText = "Привет") => new
    {
        replicas = new object[]
        {
            new { start_ms = 100, end_ms = 900, role = "ИВАН", text = firstText, spoken_text = firstText, script_line_id = "p00001", confidence = 0.9, matched = true },
            new { start_ms = 1500, end_ms = 4000, role = "МАША", text = "Здравствуй", spoken_text = "здравствуй", script_line_id = "p00003", confidence = 1.0, matched = true },
            new { start_ms = 6000, end_ms = 7000, role = (string?)null, text = "ну и погода", spoken_text = "ну и погода", script_line_id = (string?)null, matched = false },
        },
        language = "ru",
    };

    private async Task<List<(int Scene, string Text, string? Role, bool Matched)>> ReplicasAsync()
    {
        await using var cmd = _db.CreateCommand("""
            SELECT s.idx, r.text, ro.name, r.matched FROM replicas r JOIN scenes s ON s.id = r.scene_id
            LEFT JOIN roles ro ON ro.id = r.role_id WHERE s.project_id = $1 ORDER BY s.idx, r.idx
            """);
        cmd.Parameters.AddWithValue(_project);
        var rows = new List<(int, string, string?, bool)>();
        await using var r = await cmd.ExecuteReaderAsync();
        while (await r.ReadAsync()) rows.Add((r.GetInt32(0), r.GetString(1), r.IsDBNull(2) ? null : r.GetString(2), r.GetBoolean(3)));
        return rows;
    }

    [PostgresFact]
    public async Task JoinsInAnyOrderAndIsIdempotent()
    {
        var dialogue = Event("dialogue.aligned", DialoguePayload());
        await _join.OnDialogueAlignedAsync(dialogue, default);
        Assert.Equal(["project.status-changed"], _bus.Events.Select(e => e.EventType));  // ждём сцены

        await _join.OnScenesDetectedAsync(Event("scenes.detected", ScenesPayload), default);
        var ready = _bus.Events.Where(e => e.EventType == "scene.ready-for-enrichment").ToList();
        Assert.Equal(3, ready.Count);
        Assert.Equal("Здравствуй", ready[1].Payload.GetProperty("replicas")[0].GetProperty("text").GetString());
        Assert.Equal("s3://cutsheet/f/1_0.jpg", ready[1].Payload.GetProperty("keyframe_uris")[0].GetString());
        Assert.Equal(DeterministicGuid.Create($"{_project}:scene:1"), ready[1].Payload.GetProperty("scene_id").GetGuid());
        Assert.Equal([(0, "Привет", "ИВАН", true), (1, "Здравствуй", "МАША", true), (2, "ну и погода", null, false)],
            await ReplicasAsync());

        // Повторная доставка — ничего не меняется и не публикуется.
        var before = _bus.Events.Count;
        await _join.OnDialogueAlignedAsync(dialogue, default);
        Assert.Equal(before, _bus.Events.Count);
        Assert.Equal(3, (await ReplicasAsync()).Count);
    }

    [PostgresFact]
    public async Task ReprocessingKeepsUserEditedReplicas()
    {
        await _join.OnScenesDetectedAsync(Event("scenes.detected", ScenesPayload), default);
        await _join.OnDialogueAlignedAsync(Event("dialogue.aligned", DialoguePayload()), default);
        foreach (var sql in new[]
                 {
                     """
                     UPDATE replicas SET text = 'Привет!!' WHERE script_line_id = 'p00001'
                       AND scene_id IN (SELECT id FROM scenes WHERE project_id = $1)
                     """,
                     """
                     INSERT INTO user_edits (id, replica_id, field, value, user_id)
                     SELECT gen_random_uuid(), r.id, 'text', '"Привет!!"', gen_random_uuid() FROM replicas r
                     JOIN scenes s ON s.id = r.scene_id WHERE s.project_id = $1 AND r.script_line_id = 'p00001'
                     """,
                 })
        {
            await using var cmd = _db.CreateCommand(sql);
            cmd.Parameters.AddWithValue(_project);
            await cmd.ExecuteNonQueryAsync();
        }

        await _join.OnDialogueAlignedAsync(Event("dialogue.aligned", DialoguePayload("Приветик")), default);
        var rows = await ReplicasAsync();
        Assert.Equal(3, rows.Count);
        Assert.Contains((0, "Привет!!", "ИВАН", true), rows);
        Assert.DoesNotContain(rows, r => r.Text == "Приветик");
    }

    [PostgresFact]
    public async Task UnknownProjectIsIgnored()
    {
        await _join.OnDialogueAlignedAsync(Event("dialogue.aligned", DialoguePayload(), Guid.NewGuid()), default);
        Assert.Empty(_bus.Events);
    }
}
