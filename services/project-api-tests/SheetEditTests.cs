using System.Text.Json;
using Npgsql;
using Xunit;

namespace Cutsheet.ProjectApi.Tests;

/// <summary>Тест с настоящим PostgreSQL: строка подключения в CUTSHEET_TEST_PG, миграции из db/migrations применены.</summary>
public sealed class PostgresFactAttribute : FactAttribute
{
    public PostgresFactAttribute()
    {
        if (string.IsNullOrEmpty(Environment.GetEnvironmentVariable("CUTSHEET_TEST_PG")))
            Skip = "CUTSHEET_TEST_PG is not set";
    }
}

/// <summary>Правки листа: row_version, метки правок, сдвиг границ, split/merge, реплики (FR-C5–C9, FR-G5).</summary>
public sealed class SheetEditTests : IAsyncLifetime
{
    private readonly NpgsqlDataSource _db = NpgsqlDataSource.Create(Environment.GetEnvironmentVariable("CUTSHEET_TEST_PG") ?? "Host=none");
    private readonly Guid _project = Guid.NewGuid();
    private readonly Guid _owner = Guid.NewGuid();
    private readonly SheetStore _sheet;

    public SheetEditTests() => _sheet = new SheetStore(_db);

    public async Task InitializeAsync()
    {
        if (Environment.GetEnvironmentVariable("CUTSHEET_TEST_PG") is null) return;
        // Три сцены как после детекции и join: 0–2 с, 2–5 с, 5–9 с; две реплики во второй.
        await Exec("""
            INSERT INTO projects (id, owner_id, name, duration_ms) VALUES (@p, @o, 'sheet', 9000);
            INSERT INTO scenes (id, project_id, idx, start_ms, end_ms, shot_type, description)
            VALUES (gen_random_uuid(), @p, 0, 0, 2000, 'wide', 'Улица'),
                   (gen_random_uuid(), @p, 1, 2000, 5000, 'close', 'Иван'),
                   (gen_random_uuid(), @p, 2, 5000, 9000, NULL, NULL);
            INSERT INTO scene_auto_values (scene_id, field, value, confidence, source)
            SELECT id, 'description', to_jsonb(description), 0.7, 'description' FROM scenes WHERE project_id = @p AND idx = 1;
            INSERT INTO roles (id, project_id, name) VALUES (gen_random_uuid(), @p, 'ИВАН');
            INSERT INTO replicas (id, scene_id, idx, start_ms, end_ms, role_id, text, script_line_id, matched)
            SELECT gen_random_uuid(), s.id, 0, 2100, 2900, ro.id, 'Привет', 'p1', true
            FROM scenes s, roles ro WHERE s.project_id = @p AND s.idx = 1 AND ro.project_id = @p;
            INSERT INTO replicas (id, scene_id, idx, start_ms, end_ms, text, matched)
            SELECT gen_random_uuid(), id, 1, 4000, 4800, 'ну и погода', false FROM scenes WHERE project_id = @p AND idx = 1;
            """);
    }

    public async Task DisposeAsync() => await _db.DisposeAsync();

    private async Task Exec(string sql)
    {
        await using var cmd = _db.CreateCommand(sql);
        cmd.Parameters.AddWithValue("p", _project);
        cmd.Parameters.AddWithValue("o", _owner);
        await cmd.ExecuteNonQueryAsync();
    }

    private Task<List<SheetScene>> Load() => _sheet.Load(_project, default);

    private Task<EditOutcome> Edit(Func<SheetEdit, Task<EditOutcome>> action) =>
        _sheet.Edit(_project, _owner, _owner, action, default);

    private static JsonElement Body(object o) => JsonSerializer.SerializeToElement(o);

    [PostgresFact]
    public async Task StaleRowVersionIsConflictWithCurrentRow()
    {
        var s = (await Load())[1];
        Assert.IsType<EditOutcome.Changed>(await Edit(e => e.PatchSceneAsync(s.Id, Body(new { row_version = s.RowVersion, description = "Иван у окна" }))));
        var conflict = Assert.IsType<EditOutcome.Conflict>(await Edit(e => e.PatchSceneAsync(s.Id, Body(new { row_version = s.RowVersion, description = "другое" }))));
        Assert.Equal("Иван у окна", conflict.Current!.Description);
        Assert.Equal(s.RowVersion + 1, conflict.Current.RowVersion);
    }

    [PostgresFact]
    public async Task EditIsMarkedAndResetReturnsAutoValue()
    {
        var s = (await Load())[1];
        await Edit(e => e.PatchSceneAsync(s.Id, Body(new { row_version = s.RowVersion, description = "Иван у окна", shot_type = "medium" })));
        s = (await Load())[1];
        Assert.Equal(["description", "shot_type"], s.Edited.Order());
        Assert.Equal("Иван", s.Auto["description"].Value.GetString());

        await Edit(e => e.PatchSceneAsync(s.Id, Body(new { row_version = s.RowVersion, reset = new[] { "description", "shot_type" } })));
        s = (await Load())[1];
        Assert.Empty(s.Edited);
        Assert.Equal(("Иван", "close"), (s.Description, s.ShotType));
    }

    [PostgresFact]
    public async Task TypingTheAutoValueBackClearsTheMark()
    {
        var s = (await Load())[0];
        await Edit(e => e.PatchSceneAsync(s.Id, Body(new { row_version = s.RowVersion, shot_type = "close" })));
        s = (await Load())[0];
        await Edit(e => e.PatchSceneAsync(s.Id, Body(new { row_version = s.RowVersion, shot_type = "wide" })));
        Assert.Empty((await Load())[0].Edited);
    }

    [PostgresFact]
    public async Task MovingSharedBoundaryMovesNeighbor()
    {
        var s = (await Load())[1];
        var changed = Assert.IsType<EditOutcome.Changed>(
            await Edit(e => e.PatchSceneAsync(s.Id, Body(new { row_version = s.RowVersion, start_ms = 1500 }))));
        Assert.Equal(2, changed.SceneIds.Count);
        var scenes = await Load();
        Assert.Equal((1500L, 1500L), (scenes[0].EndMs, scenes[1].StartMs));
        Assert.Contains("end_ms", scenes[0].Edited);
        Assert.True(scenes[0].NeedsEnrichment && scenes[1].NeedsEnrichment);

        var bad = await Edit(e => e.PatchSceneAsync(s.Id, Body(new { row_version = scenes[1].RowVersion, start_ms = 0 })));
        Assert.IsType<EditOutcome.Invalid>(bad);
    }

    [PostgresFact]
    public async Task SplitAndMergeKeepReplicasAndRenumber()
    {
        var s = (await Load())[1];
        Assert.IsType<EditOutcome.Changed>(await Edit(e => e.SplitAsync(s.Id, Body(new { row_version = s.RowVersion, at_ms = 3500 }))));
        var scenes = await Load();
        Assert.Equal([0, 1, 2, 3], scenes.Select(x => x.Index));
        Assert.Equal((2000L, 3500L, "Привет"), (scenes[1].StartMs, scenes[1].EndMs, scenes[1].Replicas.Single().Text));
        Assert.Equal((3500L, 5000L, "ну и погода", "user"), (scenes[2].StartMs, scenes[2].EndMs, scenes[2].Replicas.Single().Text, scenes[2].Origin));
        Assert.Equal("Иван", scenes[2].Description);

        Assert.IsType<EditOutcome.Changed>(await Edit(e => e.MergeAsync(scenes[1].Id,
            Body(new { row_version = scenes[1].RowVersion, next_row_version = scenes[2].RowVersion }))));
        scenes = await Load();
        Assert.Equal(3, scenes.Count);
        Assert.Equal((2000L, 5000L), (scenes[1].StartMs, scenes[1].EndMs));
        Assert.Equal(["Привет", "ну и погода"], scenes[1].Replicas.Select(r => r.Text));
        Assert.Equal("Иван Иван", scenes[1].Description);

        await using var cmd = _db.CreateCommand("SELECT structure_edited FROM projects WHERE id = $1");
        cmd.Parameters.AddWithValue(_project);
        Assert.Equal(true, await cmd.ExecuteScalarAsync());
    }

    [PostgresFact]
    public async Task DeleteThenAddFillsTheGap()
    {
        var s = (await Load())[2];
        await Edit(e => e.DeleteAsync(s.Id, s.RowVersion));
        Assert.IsType<EditOutcome.Invalid>(await Edit(e => e.AddAsync(Body(new { start_ms = 4000, end_ms = 6000 }))));
        Assert.IsType<EditOutcome.Changed>(await Edit(e => e.AddAsync(Body(new { start_ms = 5000, end_ms = 9000 }))));
        var scenes = await Load();
        Assert.Equal(("user", 2), (scenes[2].Origin, scenes[2].Index));
    }

    [PostgresFact]
    public async Task ReplicasEditMoveDeleteAndAdd()
    {
        var scenes = await Load();
        var s = scenes[1];
        var hello = s.Replicas[0];
        // Правим текст и роль первой, удаляем вторую, добавляем свою.
        Assert.IsType<EditOutcome.Changed>(await Edit(e => e.PutReplicasAsync(s.Id, Body(new
        {
            row_version = s.RowVersion,
            replicas = new object[]
            {
                new { id = hello.Id, text = "Привет!", role = "МАША" },
                new { text = "Новая реплика", role = (string?)null },
            },
        }))));
        s = (await Load())[1];
        Assert.Equal(["Привет!", "Новая реплика"], s.Replicas.Select(r => r.Text));
        Assert.Equal(["role", "text"], s.Replicas[0].Edited.Order());
        Assert.Equal(("user", 2900L), (s.Replicas[1].Origin, s.Replicas[1].StartMs));
        await using (var cmd = _db.CreateCommand("SELECT deleted FROM replicas WHERE text = 'ну и погода' AND scene_id = $1"))
        {
            cmd.Parameters.AddWithValue(s.Id);
            Assert.Equal(true, await cmd.ExecuteScalarAsync());
        }

        // Перенос в первую сцену и сброс текста к авто-значению.
        var first = (await Load())[0];
        Assert.IsType<EditOutcome.Changed>(await Edit(e => e.PutReplicasAsync(first.Id, Body(new
        {
            row_version = first.RowVersion,
            replicas = new object[] { new { id = hello.Id, reset = new[] { "text" } } },
        }))));
        scenes = await Load();
        Assert.Equal(("Привет", "МАША"), (scenes[0].Replicas.Single().Text, scenes[0].Replicas.Single().Role));
        Assert.Equal(["role", "scene_id"], scenes[0].Replicas.Single().Edited.Order());
        Assert.Equal(["Новая реплика"], scenes[1].Replicas.Select(r => r.Text));
        Assert.Equal(s.RowVersion + 1, scenes[1].RowVersion);
    }

    [PostgresFact]
    public async Task ForeignProjectIsNotFound()
    {
        var s = (await Load())[0];
        Assert.IsType<EditOutcome.NotFound>(await _sheet.Edit(_project, Guid.NewGuid(), _owner,
            e => e.PatchSceneAsync(s.Id, Body(new { row_version = s.RowVersion, description = "x" })), default));
    }
}
