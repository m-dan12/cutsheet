using System.Text.Json;
using Confluent.Kafka;

namespace Cutsheet.Aggregator;

/// <summary>Тонкий адаптер брокера (ТЗ 3.3): бизнес-логика не видит Kafka напрямую.</summary>
public sealed class EventBus : IDisposable
{
    private readonly IProducer<string, string> _producer;

    public EventBus(IConfiguration config)
    {
        BootstrapServers = config["Kafka:BootstrapServers"] ?? "localhost:9094";
        _producer = new ProducerBuilder<string, string>(new ProducerConfig
        {
            BootstrapServers = BootstrapServers,
            EnableIdempotence = true,
            ClientId = "aggregator",
        }).Build();
    }

    public string BootstrapServers { get; }

    public async Task PublishAsync(Envelope e, CancellationToken ct)
    {
        var value = JsonSerializer.Serialize(e);
        // Ключ партиционирования — project_id (порядок событий внутри проекта).
        await _producer.ProduceAsync(e.EventType,
            new Message<string, string> { Key = e.ProjectId.ToString(), Value = value }, ct);
    }

    public void Dispose() => _producer.Dispose();
}
