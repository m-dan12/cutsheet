using System.Text.Json;
using System.Text.Json.Serialization;

namespace Cutsheet.Aggregator;

/// <summary>Конверт события (ТЗ 4.1, contracts/schemas/envelope.v1.json).</summary>
public sealed record Envelope(
    [property: JsonPropertyName("event_id")] Guid EventId,
    [property: JsonPropertyName("event_type")] string EventType,
    [property: JsonPropertyName("schema_version")] int SchemaVersion,
    [property: JsonPropertyName("project_id")] Guid ProjectId,
    [property: JsonPropertyName("correlation_id")] Guid CorrelationId,
    [property: JsonPropertyName("occurred_at")] DateTimeOffset OccurredAt,
    [property: JsonPropertyName("payload")] JsonElement Payload,
    [property: JsonPropertyName("producer")] string? Producer = null)
{
    /// <param name="eventId">Детерминированный id для повторяемых результатов; по умолчанию случайный.</param>
    public static Envelope Create(string eventType, Guid projectId, Guid correlationId, object payload,
        Guid? eventId = null) =>
        new(eventId ?? Guid.NewGuid(), eventType, 1, projectId, correlationId, DateTimeOffset.UtcNow,
            JsonSerializer.SerializeToElement(payload), "aggregator");
}
