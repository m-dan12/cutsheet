using System.Text.Json;
using Cutsheet.Aggregator.Dialogue;
using Cutsheet.Messaging;
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

    /// <summary>Как PipelineConsumer на scenes.detected: сцены проекта пересоздаются целиком.</summary>
    private async Task<Envelope> ScenesDetectedAsync(long[] bounds)
    {
        var scenes = bounds.Zip(bounds.Skip(1), (a, b) => (a, b)).Select((s, i) => new
        {
            index = i, start_ms = s.a, end_ms = s.b, keyframe_uris = new[] { $"s3://cutsheet/f/{i}_0.jpg" },
        }).ToArray();
        await using (var del = _db.CreateCommand("DELETE FROM scenes WHERE project_id = $1"))
        {
            del.Parameters.AddWithValue(_project);
            await del.ExecuteNonQueryAsync();
        }
        foreach (var sc in scenes)
        {
            var id = Guid.NewGuid();
            await using var ins = _db.CreateCommand("INSERT INTO scenes (id, project_id, idx, start_ms, end_ms) VALUES ($1, $2, $3, $4, $5)");
            ins.Parameters.AddWithValue(id);
            ins.Parameters.AddWithValue(_project);
            ins.Parameters.AddWithValue(sc.index);
            ins.Parameters.AddWithValue(sc.start_ms);
            ins.Parameters.AddWithValue(sc.end_ms);
            await ins.ExecuteNonQueryAsync();
            await using var kf = _db.CreateCommand("INSERT INTO scene_keyframes (scene_id, position, s3_uri) VALUES ($1, 0, $2)");
            kf.Parameters.AddWithValue(id);
            kf.Parameters.AddWithValue(sc.keyframe_uris[0]);
            await kf.ExecuteNonQueryAsync();
        }
        return Event("scenes.detected", new { fps = 25.0, duration_ms = bounds[^1], scenes });
    }

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

        await _join.OnScenesDetectedAsync(await ScenesDetectedAsync([0, 2000, 5000, 9000]), default);
        var ready = _bus.Events.Where(e => e.EventType == "scene.ready-for-enrichment").ToList();
        Assert.Equal(3, ready.Count);
        Assert.Equal("Здравствуй", ready[1].Payload.GetProperty("replicas")[0].GetProperty("text").GetString());
        Assert.Equal("s3://cutsheet/f/1_0.jpg", ready[1].Payload.GetProperty("keyframe_uris")[0].GetString());
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
        await _join.OnScenesDetectedAsync(await ScenesDetectedAsync([0, 2000, 5000, 9000]), default);
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
    public async Task RedetectedScenesAreSlicedAgain()
    {
        await _join.OnDialogueAlignedAsync(Event("dialogue.aligned", DialoguePayload()), default);
        await _join.OnScenesDetectedAsync(await ScenesDetectedAsync([0, 2000, 5000, 9000]), default);
        // Повторная детекция: две сцены вместо трёх, старые сцены и реплики удалены каскадом.
        await _join.OnScenesDetectedAsync(await ScenesDetectedAsync([0, 5000, 9000]), default);
        Assert.Equal([(0, "Привет", "ИВАН", true), (0, "Здравствуй", "МАША", true), (1, "ну и погода", null, false)],
            await ReplicasAsync());
        Assert.Equal(5, _bus.Events.Count(e => e.EventType == "scene.ready-for-enrichment"));
    }

    [PostgresFact]
    public async Task UnknownProjectIsIgnored()
    {
        await _join.OnDialogueAlignedAsync(Event("dialogue.aligned", DialoguePayload(), Guid.NewGuid()), default);
        Assert.Empty(_bus.Events);
    }
}
