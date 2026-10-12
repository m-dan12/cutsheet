using System.Text.Json;
using Confluent.Kafka;

namespace Cutsheet.Aggregator;

public sealed class PipelineConsumer(EventBus bus, ILogger<PipelineConsumer> log) : BackgroundService
{
    private static readonly string[] Topics = ["scenes.detected", "pipeline.failed"];

    protected override Task ExecuteAsync(CancellationToken ct) => Task.Run(() => Loop(ct), ct);

    private async Task Loop(CancellationToken ct)
    {
        using var consumer = new ConsumerBuilder<string, string>(new ConsumerConfig
        {
            BootstrapServers = bus.BootstrapServers,
            GroupId = "aggregator",
            EnableAutoCommit = false,
            AutoOffsetReset = AutoOffsetReset.Earliest,
        }).Build();
        consumer.Subscribe(Topics);
        log.LogInformation("consuming {Topics}", string.Join(", ", Topics));

        while (!ct.IsCancellationRequested)
        {
            ConsumeResult<string, string>? msg;
            try { msg = consumer.Consume(ct); }
            catch (OperationCanceledException) { break; }
            catch (ConsumeException ex) { log.LogWarning("kafka: {Reason}", ex.Error.Reason); continue; }

            Envelope? envelope;
            try { envelope = JsonSerializer.Deserialize<Envelope>(msg.Message.Value); }
            catch (JsonException ex) { log.LogError("invalid message skipped: {Error}", ex.Message); envelope = null; }

            if (envelope is { } e)
            {
                using var _ = log.BeginScope(new Dictionary<string, object>
                {
                    ["project_id"] = e.ProjectId, ["correlation_id"] = e.CorrelationId,
                });
                await Handle(e, ct);
            }
            consumer.Commit(msg); // смещение фиксируется после обработки (at-least-once)
        }
        consumer.Close();
    }

    private async Task Handle(Envelope e, CancellationToken ct)
    {
        switch (e.EventType)
        {
            case "scenes.detected":
                var count = e.Payload.GetProperty("scenes").GetArrayLength();
                log.LogInformation("scenes.detected: {Count} scenes for project {ProjectId}", count, e.ProjectId);
                await bus.PublishAsync(Envelope.Create("project.status-changed", e.ProjectId, e.CorrelationId,
                    new { stage = "scenes", status = "done", progress = 1.0 }), ct);
                break;
            case "pipeline.failed":
                var error = e.Payload.GetProperty("error").GetString();
                log.LogWarning("pipeline.failed from {Service}: {Error}",
                    e.Payload.GetProperty("service").GetString(), error);
                await bus.PublishAsync(Envelope.Create("project.status-changed", e.ProjectId, e.CorrelationId,
                    new { stage = "scenes", status = "failed", error }), ct);
                break;
        }
    }
}
