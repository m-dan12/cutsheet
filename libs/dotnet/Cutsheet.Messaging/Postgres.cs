using Microsoft.Extensions.Configuration;
using Npgsql;

namespace Cutsheet.Messaging;

public static class Postgres
{
    /// <summary>Источник подключений из ConnectionStrings:Postgres.</summary>
    public static NpgsqlDataSource CreateDataSource(IConfiguration config) =>
        NpgsqlDataSource.Create(config.GetConnectionString("Postgres")
            ?? "Host=localhost;Database=cutsheet;Username=cutsheet;Password=cutsheet");

    /// <summary>
    /// Отмечает событие обработанным для потребителя (таблица processed_events).
    /// Возвращает false, если событие уже было обработано (идемпотентность, ТЗ 3.3).
    /// </summary>
    public static async Task<bool> TryMarkProcessedAsync(NpgsqlConnection conn, NpgsqlTransaction tx,
        string consumer, Guid eventId, CancellationToken ct)
    {
        await using var cmd = new NpgsqlCommand(
            "INSERT INTO processed_events (consumer, event_id) VALUES ($1, $2) ON CONFLICT DO NOTHING", conn, tx);
        cmd.Parameters.AddWithValue(consumer);
        cmd.Parameters.AddWithValue(eventId);
        return await cmd.ExecuteNonQueryAsync(ct) == 1;
    }
}
