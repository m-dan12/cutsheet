using System.Text.Json;
using Confluent.Kafka;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace Cutsheet.Messaging;

/// <summary>
/// Цикл чтения топиков: десериализует конверт, вызывает <see cref="HandleAsync"/> и фиксирует
/// смещение после обработки (at-least-once). Наследник задаёт топики, группу и обработчик.
/// </summary>
public abstract class EventConsumer(EventBus bus, ILogger log) : BackgroundService
{
    protected EventBus Bus => bus;
    protected ILogger Log => log;

    protected abstract string[] Topics { get; }
    protected abstract string GroupId { get; }
    protected virtual AutoOffsetReset OffsetReset => AutoOffsetReset.Earliest;

    protected abstract Task HandleAsync(Envelope e, CancellationToken ct);

    protected override Task ExecuteAsync(CancellationToken ct) => Task.Run(() => Loop(ct), ct);

    private async Task Loop(CancellationToken ct)
    {
        using var consumer = new ConsumerBuilder<string, string>(new ConsumerConfig
        {
            BootstrapServers = bus.BootstrapServers,
            GroupId = GroupId,
            EnableAutoCommit = false,
            AutoOffsetReset = OffsetReset,
        }).Build();
        consumer.Subscribe(Topics);
        log.LogInformation("consuming {Topics} as {Group}", string.Join(", ", Topics), GroupId);

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
                while (!ct.IsCancellationRequested)
                {
                    try { await HandleAsync(e, ct); break; }
                    catch (OperationCanceledException) when (ct.IsCancellationRequested) { return; }
                    catch (Exception ex)
                    {
                        // Повтор той же записи: смещение не двигается, пока обработка не удалась.
                        // DLQ и лимит повторов — этап 6.
                        log.LogError(ex, "{EventType} {EventId} failed, retrying", e.EventType, e.EventId);
                        await Task.Delay(TimeSpan.FromSeconds(2), ct);
                    }
                }
            }
            consumer.Commit(msg);
        }
        consumer.Close();
    }
}
