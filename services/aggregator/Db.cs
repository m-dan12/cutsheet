using Npgsql;

namespace Cutsheet.Aggregator;

/// <summary>Короткие помощники для SQL с именованными параметрами. Команды выполняются в текущей
/// транзакции соединения.</summary>
internal static class Db
{
    public static NpgsqlCommand Command(NpgsqlConnection conn, string sql, params (string Name, object Value)[] args)
    {
        var cmd = new NpgsqlCommand(sql, conn);
        foreach (var (name, value) in args)
        {
            if (value is NpgsqlParameter prm) { prm.ParameterName = name; cmd.Parameters.Add(prm); }
            else cmd.Parameters.AddWithValue(name, value);
        }
        return cmd;
    }

    public static async Task<int> ExecAsync(NpgsqlConnection conn, string sql, CancellationToken ct,
        params (string, object)[] args)
    {
        await using var cmd = Command(conn, sql, args);
        return await cmd.ExecuteNonQueryAsync(ct);
    }

    public static async Task<T> ScalarAsync<T>(NpgsqlConnection conn, string sql, CancellationToken ct,
        params (string, object)[] args)
    {
        await using var cmd = Command(conn, sql, args);
        return (T)(await cmd.ExecuteScalarAsync(ct))!;
    }
}
