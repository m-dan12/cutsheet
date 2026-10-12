using System.Text.Json;
using Cutsheet.Messaging;
using Npgsql;

namespace Cutsheet.ProjectApi;

public sealed record ExportRow(Guid Id, Guid ProjectId, string Format, string Status, string? SnapshotUri,
    string? S3Uri, string? Error, DateTimeOffset CreatedAt, DateTimeOffset? CompletedAt);

/// <summary>Таблица exports (FR-G6): запрос экспорта и его итог из export.completed / export.failed.</summary>
public sealed class ExportStore(NpgsqlDataSource db)
{
    public const string Consumer = "project-api-exports";
    private const string Columns = "id, project_id, format, status, snapshot_uri, s3_uri, error, created_at, completed_at";

    public async Task<ExportRow> Create(Guid id, Guid projectId, string format, JsonElement options, string snapshotUri,
        CancellationToken ct)
    {
        await using var cmd = db.CreateCommand($"""
            INSERT INTO exports (id, project_id, format, options, snapshot_uri) VALUES ($1, $2, $3, $4::jsonb, $5)
            RETURNING {Columns}
            """);
        cmd.Parameters.AddWithValue(id);
        cmd.Parameters.AddWithValue(projectId);
        cmd.Parameters.AddWithValue(format);
        cmd.Parameters.AddWithValue(options.GetRawText());
        cmd.Parameters.AddWithValue(snapshotUri);
        return (await Read(cmd, ct))[0];
    }

    public async Task<ExportRow?> Get(Guid projectId, Guid id, CancellationToken ct)
    {
        await using var cmd = db.CreateCommand($"SELECT {Columns} FROM exports WHERE id = $1 AND project_id = $2");
        cmd.Parameters.AddWithValue(id);
        cmd.Parameters.AddWithValue(projectId);
        return (await Read(cmd, ct)).FirstOrDefault();
    }

    public async Task<List<ExportRow>> List(Guid projectId, int limit, CancellationToken ct)
    {
        await using var cmd = db.CreateCommand(
            $"SELECT {Columns} FROM exports WHERE project_id = $1 ORDER BY created_at DESC LIMIT $2");
        cmd.Parameters.AddWithValue(projectId);
        cmd.Parameters.AddWithValue(limit);
        return await Read(cmd, ct);
    }

    /// <summary>
    /// Итог экспорта из события. Дубликат события (тот же event_id) ничего не меняет и возвращает null;
    /// иначе — обновлённая строка (null и для неизвестного export_id).
    /// </summary>
    public async Task<ExportRow?> Finish(Guid eventId, Guid exportId, string? resultUri, string? error,
        CancellationToken ct)
    {
        await using var conn = await db.OpenConnectionAsync(ct);
        await using var tx = await conn.BeginTransactionAsync(ct);
        if (!await Postgres.TryMarkProcessedAsync(conn, tx, Consumer, eventId, ct)) return null;
        ExportRow? row;
        await using (var cmd = new NpgsqlCommand($"""
                         UPDATE exports SET status = $2, s3_uri = $3, error = $4, completed_at = now()
                         WHERE id = $1 RETURNING {Columns}
                         """, conn, tx))
        {
            cmd.Parameters.AddWithValue(exportId);
            cmd.Parameters.AddWithValue(resultUri is null ? "failed" : "completed");
            cmd.Parameters.AddWithValue((object?)resultUri ?? DBNull.Value);
            cmd.Parameters.AddWithValue((object?)error ?? DBNull.Value);
            row = (await Read(cmd, ct)).FirstOrDefault();
        }
        await tx.CommitAsync(ct);
        return row;
    }

    private static async Task<List<ExportRow>> Read(NpgsqlCommand cmd, CancellationToken ct)
    {
        await using var r = await cmd.ExecuteReaderAsync(ct);
        var list = new List<ExportRow>();
        while (await r.ReadAsync(ct))
            list.Add(new ExportRow(r.GetGuid(0), r.GetGuid(1), r.GetString(2), r.GetString(3), N<string>(r, 4),
                N<string>(r, 5), N<string>(r, 6), r.GetFieldValue<DateTimeOffset>(7), N<DateTimeOffset?>(r, 8)));
        return list;
    }

    private static T? N<T>(NpgsqlDataReader r, int i) => r.IsDBNull(i) ? default : r.GetFieldValue<T>(i);
}
