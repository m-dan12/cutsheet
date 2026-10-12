using Npgsql;

namespace Cutsheet.ProjectApi;

public sealed record Project(Guid Id, Guid OwnerId, string Name, string Stage, string Status, string? Error,
    string? VideoUri, string? ScriptUri, double? Fps, long? DurationMs, string Language, DateTimeOffset CreatedAt, DateTimeOffset UpdatedAt,
    bool ReviewRequired, bool StructureEdited);

public sealed record Upload(Guid Id, Guid ProjectId, string Kind, string S3Key, string Status, string? Filename,
    string? ContentType, long? SizeBytes, long? PartSize, int? PartCount, string? S3UploadId);

/// <summary>Таблицы projects и uploads (пишет Project API).</summary>
public sealed class ProjectStore(NpgsqlDataSource db)
{
    private const string ProjectColumns =
        "id, owner_id, name, stage, status, error, video_uri, script_uri, fps, duration_ms, language, created_at, updated_at, " +
        "review_required, structure_edited";

    public async Task<Project> Create(Guid ownerId, string name, string language, CancellationToken ct)
    {
        await using var cmd = db.CreateCommand($"""
            INSERT INTO projects (id, owner_id, name, language) VALUES ($1, $2, $3, $4)
            RETURNING {ProjectColumns}
            """);
        cmd.Parameters.AddWithValue(Guid.NewGuid());
        cmd.Parameters.AddWithValue(ownerId);
        cmd.Parameters.AddWithValue(name);
        cmd.Parameters.AddWithValue(language);
        return (await ReadProjects(cmd, ct))[0];
    }

    public async Task<List<Project>> List(Guid ownerId, CancellationToken ct)
    {
        await using var cmd = db.CreateCommand(
            $"SELECT {ProjectColumns} FROM projects WHERE owner_id = $1 ORDER BY created_at DESC");
        cmd.Parameters.AddWithValue(ownerId);
        return await ReadProjects(cmd, ct);
    }

    /// <summary>Проект владельца или null (чужой проект неотличим от несуществующего, FR-G9).</summary>
    public async Task<Project?> Get(Guid id, Guid ownerId, CancellationToken ct)
    {
        await using var cmd = db.CreateCommand($"SELECT {ProjectColumns} FROM projects WHERE id = $1 AND owner_id = $2");
        cmd.Parameters.AddWithValue(id);
        cmd.Parameters.AddWithValue(ownerId);
        return (await ReadProjects(cmd, ct)).FirstOrDefault();
    }

    public async Task SetStatus(Guid id, string stage, string status, string? error, CancellationToken ct)
    {
        await using var cmd = db.CreateCommand(
            "UPDATE projects SET stage = $2, status = $3, error = $4, updated_at = now() WHERE id = $1");
        cmd.Parameters.AddWithValue(id);
        cmd.Parameters.AddWithValue(stage);
        cmd.Parameters.AddWithValue(status);
        cmd.Parameters.AddWithValue((object?)error ?? DBNull.Value);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task CreateUpload(Upload u, CancellationToken ct)
    {
        await using var cmd = db.CreateCommand("""
            INSERT INTO uploads (id, project_id, kind, s3_key, status, filename, content_type, size_bytes,
                                 part_size, part_count, s3_upload_id)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
            """);
        foreach (var v in new object?[] { u.Id, u.ProjectId, u.Kind, u.S3Key, u.Status, u.Filename, u.ContentType,
                     u.SizeBytes, u.PartSize, u.PartCount, u.S3UploadId })
            cmd.Parameters.AddWithValue(v ?? DBNull.Value);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task<Upload?> GetUpload(Guid projectId, Guid uploadId, CancellationToken ct)
    {
        await using var cmd = db.CreateCommand("""
            SELECT id, project_id, kind, s3_key, status, filename, content_type, size_bytes, part_size, part_count,
                   s3_upload_id
            FROM uploads WHERE id = $1 AND project_id = $2
            """);
        cmd.Parameters.AddWithValue(uploadId);
        cmd.Parameters.AddWithValue(projectId);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        if (!await r.ReadAsync(ct)) return null;
        return new Upload(r.GetGuid(0), r.GetGuid(1), r.GetString(2), r.GetString(3), r.GetString(4),
            N<string>(r, 5), N<string>(r, 6), N<long>(r, 7), N<long>(r, 8), N<int>(r, 9), N<string>(r, 10));
    }

    /// <summary>Отмечает загрузку завершённой и записывает ссылку в проект.</summary>
    public async Task CompleteUpload(Upload u, string uri, long size, CancellationToken ct)
    {
        await using var conn = await db.OpenConnectionAsync(ct);
        await using var tx = await conn.BeginTransactionAsync(ct);
        await using (var cmd = new NpgsqlCommand(
            "UPDATE uploads SET status = 'completed', size_bytes = $2, completed_at = now() WHERE id = $1", conn, tx))
        {
            cmd.Parameters.AddWithValue(u.Id);
            cmd.Parameters.AddWithValue(size);
            await cmd.ExecuteNonQueryAsync(ct);
        }
        var column = u.Kind == "video" ? "video_uri" : "script_uri";
        await using (var cmd = new NpgsqlCommand($"UPDATE projects SET {column} = $2, updated_at = now() WHERE id = $1",
                         conn, tx))
        {
            cmd.Parameters.AddWithValue(u.ProjectId);
            cmd.Parameters.AddWithValue(uri);
            await cmd.ExecuteNonQueryAsync(ct);
        }
        await tx.CommitAsync(ct);
    }

    /// <summary>Режим «без правок» (FR-C12).</summary>
    public async Task SetReviewRequired(Guid id, bool value, CancellationToken ct)
    {
        await using var cmd = db.CreateCommand("UPDATE projects SET review_required = $2, updated_at = now() WHERE id = $1");
        cmd.Parameters.AddWithValue(id);
        cmd.Parameters.AddWithValue(value);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    /// <summary>Последняя завершённая загрузка видео или сценария: из неё повторяется событие при перезапуске.</summary>
    public async Task<Upload?> LastCompletedUpload(Guid projectId, string kind, CancellationToken ct)
    {
        await using var cmd = db.CreateCommand("""
            SELECT id, project_id, kind, s3_key, status, filename, content_type, size_bytes, part_size, part_count,
                   s3_upload_id
            FROM uploads WHERE project_id = $1 AND kind = $2 AND status = 'completed'
            ORDER BY completed_at DESC LIMIT 1
            """);
        cmd.Parameters.AddWithValue(projectId);
        cmd.Parameters.AddWithValue(kind);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        if (!await r.ReadAsync(ct)) return null;
        return new Upload(r.GetGuid(0), r.GetGuid(1), r.GetString(2), r.GetString(3), r.GetString(4),
            N<string>(r, 5), N<string>(r, 6), N<long>(r, 7), N<long>(r, 8), N<int>(r, 9), N<string>(r, 10));
    }

    private static async Task<List<Project>> ReadProjects(NpgsqlCommand cmd, CancellationToken ct)
    {
        await using var r = await cmd.ExecuteReaderAsync(ct);
        var list = new List<Project>();
        while (await r.ReadAsync(ct))
            list.Add(new Project(r.GetGuid(0), r.GetGuid(1), r.GetString(2), r.GetString(3), r.GetString(4),
                N<string>(r, 5), N<string>(r, 6), N<string>(r, 7), N<double>(r, 8), N<long>(r, 9), r.GetString(10),
                r.GetFieldValue<DateTimeOffset>(11), r.GetFieldValue<DateTimeOffset>(12), r.GetBoolean(13), r.GetBoolean(14)));
        return list;
    }

    private static T? N<T>(NpgsqlDataReader r, int i) => r.IsDBNull(i) ? default : r.GetFieldValue<T>(i);
}
