using System.Text.Json;
using Npgsql;
using Xunit;

namespace Cutsheet.ProjectApi.Tests;

/// <summary>Экспорт (этап 5): снимок листа с правками, имя файла, итог экспорта из событий.</summary>
public sealed class ExportTests : IAsyncLifetime
{
    private readonly NpgsqlDataSource _db = NpgsqlDataSource.Create(Environment.GetEnvironmentVariable("CUTSHEET_TEST_PG") ?? "Host=none");
    private readonly Guid _project = Guid.NewGuid();
    private readonly Guid _owner = Guid.NewGuid();

    private static Project Project(double? fps = 25) => new(Guid.NewGuid(), Guid.NewGuid(), "Фильм: «Утро»", "ready_for_review",
        "done", null, null, null, fps, 9000, "ru", DateTimeOffset.UtcNow, DateTimeOffset.UtcNow, false, false);

    private static ReplicaRow Replica(Guid scene, int idx, string? role, string text) =>
        new(Guid.NewGuid(), scene, idx, idx * 1000, idx * 1000 + 500, role, text, null, null, true, "auto", []);

    [Fact]
    public void SnapshotKeepsSheetOrderAndFinalValues()
    {
        var a = Guid.NewGuid();
        var b = Guid.NewGuid();
        // Строки приходят не по порядку; номер строки — позиция в листе, а не idx.
        List<SheetScene> scenes =
        [
            new(b, 5, 2000, 9000, null, null, "done", 1, "user", true, [], ["start_ms"], [], [Replica(b, 1, null, "Кто там?"), Replica(b, 0, "ИВАН", "Привет")]),
            new(a, 2, 0, 2000, "wide", "Улица", "done", 3, "auto", false, [], ["description"], [], []),
        ];
        var id = Guid.NewGuid();
        var snap = ExportSnapshot.Build(id, Project(), scenes, new DateTimeOffset(2026, 10, 12, 10, 0, 0, TimeSpan.Zero));
        var json = JsonSerializer.SerializeToElement(snap);

        Assert.Equal(1, json.GetProperty("schema_version").GetInt32());
        Assert.Equal(id, json.GetProperty("export_id").GetGuid());
        Assert.Equal("Фильм: «Утро»", json.GetProperty("project").GetProperty("name").GetString());
        var rows = json.GetProperty("scenes").EnumerateArray().ToList();
        Assert.Equal([1, 2], rows.Select(r => r.GetProperty("number").GetInt32()));
        Assert.Equal("Улица", rows[0].GetProperty("description").GetString());
        Assert.Equal(JsonValueKind.Null, rows[1].GetProperty("shot_type").ValueKind);
        Assert.Equal(["ИВАН", null], rows[1].GetProperty("replicas").EnumerateArray().Select(r => r.GetProperty("role").GetString()));
    }

    [Fact]
    public void UnknownFpsIsNull() =>
        Assert.Null(ExportSnapshot.Build(Guid.NewGuid(), Project(fps: 0), [], DateTimeOffset.UtcNow).Fps);

    [Theory]
    [InlineData("Фильм: «Утро»", "pdf", "Фильм_ «Утро» - монтажный лист.pdf")]
    [InlineData("a/b\\c?", "xlsx", "a_b_c_ - монтажный лист.xlsx")]
    [InlineData("...", "docx", "sheet - монтажный лист.docx")]
    public void FilenameIsSafeForWindows(string name, string format, string expected) =>
        Assert.Equal(expected, ExportEndpoints.Filename(name, format));

    [Fact]
    public void ContentDispositionHasAsciiFallbackAndUtf8Name()
    {
        var cd = ObjectStorage.ContentDisposition("Утро \"1\".pdf");
        Assert.Equal("attachment; filename=\"____ _1_.pdf\"; filename*=UTF-8''%D0%A3%D1%82%D1%80%D0%BE%20%221%22.pdf", cd);
    }

    public async Task InitializeAsync()
    {
        if (Environment.GetEnvironmentVariable("CUTSHEET_TEST_PG") is null) return;
        await using var cmd = _db.CreateCommand("INSERT INTO projects (id, owner_id, name) VALUES ($1, $2, 'export')");
        cmd.Parameters.AddWithValue(_project);
        cmd.Parameters.AddWithValue(_owner);
        await cmd.ExecuteNonQueryAsync();
    }

    public async Task DisposeAsync() => await _db.DisposeAsync();

    [PostgresFact]
    public async Task FinishRecordsResultOnceAndKeepsHistory()
    {
        var store = new ExportStore(_db);
        var options = JsonSerializer.SerializeToElement(new { template = "compact" });
        var first = await store.Create(Guid.NewGuid(), _project, "pdf", options, "s3://cutsheet/x/snapshot.json", default);
        var second = await store.Create(Guid.NewGuid(), _project, "xlsx", options, "s3://cutsheet/y/snapshot.json", default);
        Assert.Equal("requested", first.Status);

        var eventId = Guid.NewGuid();
        var done = await store.Finish(eventId, first.Id, "s3://cutsheet/x/sheet.pdf", null, default);
        Assert.Equal(("completed", "s3://cutsheet/x/sheet.pdf"), (done!.Status, done.S3Uri));
        Assert.NotNull(done.CompletedAt);
        Assert.Null(await store.Finish(eventId, first.Id, null, "повтор", default)); // дубликат события

        var failed = await store.Finish(Guid.NewGuid(), second.Id, null, "FileNotFoundError: нет снимка", default);
        Assert.Equal(("failed", "FileNotFoundError: нет снимка"), (failed!.Status, failed.Error));
        Assert.Null(await store.Finish(Guid.NewGuid(), Guid.NewGuid(), "s3://cutsheet/z", null, default)); // чужой export_id

        var list = await store.List(_project, 20, default);
        Assert.Equal([second.Id, first.Id], list.Select(e => e.Id));
        Assert.Equal("completed", (await store.Get(_project, first.Id, default))!.Status);
        Assert.Null(await store.Get(Guid.NewGuid(), first.Id, default));
    }
}
