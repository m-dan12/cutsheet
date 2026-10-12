using System.Diagnostics;
using System.Text;
using System.Text.Json;
using Confluent.Kafka;
using Microsoft.Extensions.Configuration;

namespace Cutsheet.Messaging;

/// <summary>Публикация событий: бизнес-логика зависит от этого интерфейса, а не от Kafka.</summary>
public interface IEventPublisher
{
    Task PublishAsync(Envelope e, CancellationToken ct);
}

/// <summary>Тонкий адаптер брокера (ТЗ 3.3): бизнес-логика не видит Kafka напрямую.</summary>
public sealed class EventBus : IEventPublisher, IDisposable
{
    /// <summary>Заголовок Kafka с контекстом трейса (W3C), общий с Python-сервисами.</summary>
    public const string TraceParentHeader = "traceparent";

    private readonly IProducer<string, string> _producer;

    public EventBus(IConfiguration config)
    {
        BootstrapServers = config["Kafka:BootstrapServers"] ?? "localhost:9094";
        Producer = config["Kafka:ClientId"] ?? AppDomain.CurrentDomain.FriendlyName.ToLowerInvariant();
        MaxAttempts = Math.Max(1, config.GetValue("Kafka:MaxAttempts", 5));
        RetryBackoff = TimeSpan.FromSeconds(config.GetValue("Kafka:RetryBackoffSeconds", 1.0));
        _producer = new ProducerBuilder<string, string>(new ProducerConfig
        {
            BootstrapServers = BootstrapServers,
            EnableIdempotence = true,
            ClientId = Producer,
        }).Build();
    }

    public string BootstrapServers { get; }

    /// <summary>Имя сервиса-производителя, пишется в поле producer конверта.</summary>
    public string Producer { get; }

    /// <summary>Сколько раз обрабатывать событие, прежде чем отправить его в DLQ (ТЗ 4.3: 3–5).</summary>
    public int MaxAttempts { get; }

    /// <summary>Первая задержка между повторами; дальше удваивается.</summary>
    public TimeSpan RetryBackoff { get; }

    public Task PublishAsync(string eventType, Guid projectId, Guid correlationId, object payload, CancellationToken ct) =>
        PublishAsync(Envelope.Create(eventType, projectId, correlationId, payload, Producer), ct);

    public async Task PublishAsync(Envelope e, CancellationToken ct)
    {
        using var activity = Observability.Source.StartActivity($"{e.EventType} publish", ActivityKind.Producer);
        activity?.SetTag("messaging.destination.name", e.EventType);
        activity?.SetTag("cutsheet.event_id", e.EventId);
        activity?.SetTag("cutsheet.project_id", e.ProjectId);
        var message = new Message<string, string>
        {
            // Ключ партиционирования — project_id (порядок событий внутри проекта).
            Key = e.ProjectId.ToString(),
            Value = JsonSerializer.Serialize(e),
            Headers = TraceHeaders(Activity.Current),
        };
        await _producer.ProduceAsync(e.EventType, message, ct);
        Observability.EventsPublished.WithLabels(Producer, e.EventType).Inc();
    }

    /// <summary>Отправка сообщения как есть (DLQ): без конверта и проверки, с заголовками-причиной.</summary>
    public async Task ProduceRawAsync(string topic, string? key, string value,
        IEnumerable<KeyValuePair<string, string>> headers, CancellationToken ct)
    {
        var h = new Headers();
        foreach (var (k, v) in headers) h.Add(k, Encoding.UTF8.GetBytes(v));
        await _producer.ProduceAsync(topic, new Message<string, string> { Key = key!, Value = value, Headers = h }, ct);
    }

    private static Headers? TraceHeaders(Activity? activity)
    {
        if (activity is null || activity.IdFormat != ActivityIdFormat.W3C) return null;
        return new Headers { { TraceParentHeader, Encoding.ASCII.GetBytes(activity.Id!) } };
    }

    public void Dispose() => _producer.Dispose();
}
