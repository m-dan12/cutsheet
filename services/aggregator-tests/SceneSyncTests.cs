using System.Text.Json;
using Cutsheet.Aggregator.Dialogue;
using Cutsheet.Messaging;
using Microsoft.Extensions.Logging.Abstractions;
using Npgsql;
using Xunit;

namespace Cutsheet.Aggregator.Tests;

/// <summary>Повторная обработка не затирает правки пользователя (FR-A5, ТЗ 6.2). Нужен CUTSHEET_TEST_PG.</summary>
public sealed class SceneSyncTests : IAsyncLifetime
{
    private sealed class NullPublisher : IEventPublisher
    {
        public Task PublishAsync(Envelope e, CancellationToken ct) => Task.CompletedTask;
    }

    private readonly NpgsqlDataSource _db = NpgsqlDataSource.Create(Environment.GetEnvironmentVariable("CUTSHEET_TEST_PG") ?? "Host=none");
    private readonly Guid _project = Guid.NewGuid();

    public async Task InitializeAsync()
    {
        if (Environment.GetEnvironmentVariable("CUTSHEET_TEST_PG") is null) return;
        await Exec("INSERT INTO projects (id, owner_id, name) VALUES (@p, gen_random_uuid(), 'sync')");
    }

    public async Task DisposeAsync() => await _db.DisposeAsync();

    private async Task Exec(string sql)
    {
        await using var cmd = _db.CreateCommand(sql);
        cmd.Parameters.AddWithValue("p", _project);
        await cmd.ExecuteNonQueryAsync();
    }

    private async Task<SceneSync.Result> Detect(params long[] bounds)
    {
        var scenes = bounds.Zip(bounds.Skip(1), (a, b) => (a, b))
            .Select((s, i) => new DetectedScene(i, s.a, s.b, [$"s3://cutsheet/f/{s.a}.jpg"])).ToList();
        await using var conn = await _db.OpenConnectionAsync();
        await using var tx = await conn.BeginTransactionAsync();
        var result = await SceneSync.ApplyAsync(conn, tx, _project, scenes, default);
        await tx.CommitAsync();
        return result;
    }

    private async Task<List<(Guid Id, int Idx, long Start, long End, string? Description)>> Scenes()
    {
        await using var cmd = _db.CreateCommand("SELECT id, idx, start_ms, end_ms, description FROM scenes WHERE project_id = @p ORDER BY idx");
        cmd.Parameters.AddWithValue("p", _project);
        var rows = new List<(Guid, int, long, long, string?)>();
        await using var r = await cmd.ExecuteReaderAsync();
        while (await r.ReadAsync()) rows.Add((r.GetGuid(0), r.GetInt32(1), r.GetInt64(2), r.GetInt64(3), r.IsDBNull(4) ? null : r.GetString(4)));
        return rows;
    }

    /// <summary>Правка описания, как её делает Project API.</summary>
    private Task EditDescription(int idx, string text) => Exec($"""
        UPDATE scenes SET description = '{text}' WHERE project_id = @p AND idx = {idx};
        INSERT INTO user_edits (id, scene_id, field, value, auto_value, user_id)
        SELECT gen_random_uuid(), id, 'description', to_jsonb('{text}'::text), 'null', gen_random_uuid()
        FROM scenes WHERE project_id = @p AND idx = {idx};
        """);

    [PostgresFact]
    public async Task RedetectionKeepsRowIdsAndEdits()
    {
        Assert.Equal(SceneSync.Result.Inserted, await Detect(0, 2000, 5000, 9000));
        var before = await Scenes();
        await EditDescription(1, "Маша у окна");

        Assert.Equal(SceneSync.Result.Matched, await Detect(0, 2200, 5000, 9000));
        var after = await Scenes();
        Assert.Equal(before.Select(s => s.Id), after.Select(s => s.Id));
        Assert.Equal((2200L, 5000L, "Маша у окна"), (after[1].Start, after[1].End, after[1].Description));
    }

    [PostgresFact]
    public async Task EditOfVanishedSceneMovesToItsSuccessor()
    {
        await Detect(0, 2000, 5000, 9000);
        await EditDescription(0, "Иван входит");
        await Detect(0, 5000, 9000);
        var after = await Scenes();
        Assert.Equal(2, after.Count);
        Assert.Equal("Иван входит", after[0].Description);
        await using var cmd = _db.CreateCommand("SELECT count(*) FROM user_edits u JOIN scenes s ON s.id = u.scene_id WHERE s.project_id = @p");
        cmd.Parameters.AddWithValue("p", _project);
        Assert.Equal(1L, await cmd.ExecuteScalarAsync());
    }

    [PostgresFact]
    public async Task UserStructureIsNotReplaced()
    {
        await Detect(0, 2000, 5000, 9000);
        await Exec("UPDATE projects SET structure_edited = true WHERE id = @p");
        var before = await Scenes();
        Assert.Equal(SceneSync.Result.KeptUserStructure, await Detect(0, 4000, 9000));
        Assert.Equal(before, await Scenes());
    }

    [PostgresFact]
    public async Task RejoinKeepsDeletedAndAddedReplicas()
    {
        var join = new DialogueJoin(_db, new NullPublisher(), NullLogger<DialogueJoin>.Instance);
        Envelope Event(string type, object payload) =>
            new(Guid.NewGuid(), type, 1, _project, Guid.NewGuid(), DateTimeOffset.UtcNow, JsonSerializer.SerializeToElement(payload), "test");
        var dialogue = new
        {
            replicas = new object[]
            {
                new { start_ms = 100, end_ms = 900, role = "ИВАН", text = "Привет", script_line_id = "p00001", matched = true },
                new { start_ms = 6000, end_ms = 7000, role = (string?)null, text = "ну и погода", script_line_id = (string?)null, matched = false },
            },
        };
        await Detect(0, 2000, 5000, 9000);
        await join.OnScenesDetectedAsync(Event("scenes.detected", new { }), default);
        await join.OnDialogueAlignedAsync(Event("dialogue.aligned", dialogue), default);

        // Пользователь удалил несопоставленную реплику и добавил свою (как PUT /replicas).
        await Exec("""
            UPDATE replicas SET deleted = true WHERE text = 'ну и погода' AND scene_id IN (SELECT id FROM scenes WHERE project_id = @p);
            INSERT INTO user_edits (id, replica_id, field, value, auto_value, user_id)
            SELECT gen_random_uuid(), id, 'deleted', 'true', 'false', gen_random_uuid() FROM replicas
            WHERE text = 'ну и погода' AND scene_id IN (SELECT id FROM scenes WHERE project_id = @p);
            INSERT INTO replicas (id, scene_id, idx, start_ms, end_ms, text, origin)
            SELECT gen_random_uuid(), id, 5, 3000, 4000, 'Своя реплика', 'user' FROM scenes WHERE project_id = @p AND idx = 1;
            """);

        await Detect(0, 2000, 5000, 9000);
        await join.OnScenesDetectedAsync(Event("scenes.detected", new { }), default);
        await using var cmd = _db.CreateCommand("""
            SELECT r.text, r.deleted FROM replicas r JOIN scenes s ON s.id = r.scene_id
            WHERE s.project_id = @p ORDER BY s.idx, r.idx
            """);
        cmd.Parameters.AddWithValue("p", _project);
        var rows = new List<(string, bool)>();
        await using (var r = await cmd.ExecuteReaderAsync())
            while (await r.ReadAsync()) rows.Add((r.GetString(0), r.GetBoolean(1)));
        Assert.Equal([("Привет", false), ("Своя реплика", false), ("ну и погода", true)], rows);
    }
}
