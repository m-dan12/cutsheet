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
    private readonly IProducer<string, string> _producer;

    public EventBus(IConfiguration config)
    {
        BootstrapServers = config["Kafka:BootstrapServers"] ?? "localhost:9094";
        Producer = config["Kafka:ClientId"] ?? AppDomain.CurrentDomain.FriendlyName.ToLowerInvariant();
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

    public Task PublishAsync(string eventType, Guid projectId, Guid correlationId, object payload, CancellationToken ct) =>
        PublishAsync(Envelope.Create(eventType, projectId, correlationId, payload, Producer), ct);

    public async Task PublishAsync(Envelope e, CancellationToken ct)
    {
        var value = JsonSerializer.Serialize(e);
        // Ключ партиционирования — project_id (порядок событий внутри проекта).
        await _producer.ProduceAsync(e.EventType,
            new Message<string, string> { Key = e.ProjectId.ToString(), Value = value }, ct);
    }

    public void Dispose() => _producer.Dispose();
}
