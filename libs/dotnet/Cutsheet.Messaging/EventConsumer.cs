using System.Diagnostics;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using Confluent.Kafka;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Npgsql;

namespace Cutsheet.Messaging;

/// <summary>
/// Цикл чтения топиков: десериализует конверт, вызывает <see cref="HandleAsync"/> и фиксирует
/// смещение после обработки (at-least-once). Наследник задаёт топики, группу и обработчик.
/// </summary>
/// <remarks>
/// Ошибки (ТЗ 4.3, этап 6):
/// <list type="bullet">
/// <item>невалидное сообщение и ошибка данных (нет поля, не тот тип) — сразу в <c>&lt;topic&gt;.dlq</c>;</item>
/// <item>недоступность PostgreSQL или Kafka — повтор без лимита с задержкой до минуты: событие
/// нельзя терять, а сервис сам по себе исправен;</item>
/// <item>прочие сбои — до <see cref="EventBus.MaxAttempts"/> попыток с экспоненциальной задержкой,
/// затем DLQ и <see cref="OnFailedAsync"/>.</item>
/// </list>
/// </remarks>
public abstract class EventConsumer(EventBus bus, ILogger log) : BackgroundService
{
    protected EventBus Bus => bus;
    protected ILogger Log => log;

    protected abstract string[] Topics { get; }
    protected abstract string GroupId { get; }
    protected virtual AutoOffsetReset OffsetReset => AutoOffsetReset.Earliest;

    protected abstract Task HandleAsync(Envelope e, CancellationToken ct);

    /// <summary>Вызывается, когда событие ушло в DLQ после всех попыток (например, публикует pipeline.failed).</summary>
    protected virtual Task OnFailedAsync(Envelope e, Exception error, bool retryable, CancellationToken ct) =>
        Task.CompletedTask;

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

            try
            {
                if (!await ProcessAsync(msg, ct)) break;
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { break; }
            consumer.Commit(msg);
        }
        consumer.Close();
    }

    /// <summary>Обрабатывает одно сообщение. false — сервис останавливается, смещение не фиксируем.</summary>
    private async Task<bool> ProcessAsync(ConsumeResult<string, string> msg, CancellationToken ct)
    {
        var topic = msg.Topic;
        Envelope? envelope;
        string? invalid = null;
        try { envelope = JsonSerializer.Deserialize<Envelope>(msg.Message.Value); }
        catch (JsonException ex) { envelope = null; invalid = ex.Message; }
        if (envelope is null || envelope.EventType is null)
        {
            Observability.EventsConsumed.WithLabels(bus.Producer, topic, "invalid").Inc();
            await ToDlqAsync(msg, "invalid", invalid ?? "empty envelope", 0, ct);
            return true;
        }

        var e = envelope;
        using var scope = log.BeginScope(new Dictionary<string, object>
        {
            ["project_id"] = e.ProjectId, ["correlation_id"] = e.CorrelationId, ["event_id"] = e.EventId,
        });
        using var activity = Observability.Source.StartActivity($"{topic} process", ActivityKind.Consumer,
            ParentContext(msg.Message.Headers));
        activity?.SetTag("messaging.destination.name", topic);
        activity?.SetTag("cutsheet.event_id", e.EventId);
        activity?.SetTag("cutsheet.project_id", e.ProjectId);

        var attempt = 0;
        var outages = 0;
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            var started = Stopwatch.GetTimestamp();
            try
            {
                attempt++;
                await HandleAsync(e, ct);
                Observability.HandlerDuration.WithLabels(bus.Producer, e.EventType)
                    .Observe(Stopwatch.GetElapsedTime(started).TotalSeconds);
                Observability.EventsConsumed.WithLabels(bus.Producer, topic, "ok").Inc();
                return true;
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { return false; }
            catch (Exception ex) when (IsOutage(ex))
            {
                // Попытку не считаем: событие корректно, просто недоступна инфраструктура.
                attempt--;
                var delay = Backoff(++outages, TimeSpan.FromMinutes(1));
                log.LogWarning(ex, "{EventType} {EventId}: infrastructure unavailable, retry in {Delay}s",
                    e.EventType, e.EventId, delay.TotalSeconds);
                await Task.Delay(delay, ct);
            }
            catch (Exception ex)
            {
                var retryable = !IsDataError(ex);
                if (retryable && attempt < bus.MaxAttempts)
                {
                    var delay = Backoff(attempt, TimeSpan.FromMinutes(5));
                    Observability.HandlerRetries.WithLabels(bus.Producer, topic).Inc();
                    log.LogWarning(ex, "{EventType} {EventId} failed (attempt {Attempt}/{Max}), retry in {Delay}s",
                        e.EventType, e.EventId, attempt, bus.MaxAttempts, delay.TotalSeconds);
                    await Task.Delay(delay, ct);
                    continue;
                }
                log.LogError(ex, "{EventType} {EventId} failed after {Attempt} attempt(s), sent to DLQ",
                    e.EventType, e.EventId, attempt);
                activity?.SetStatus(ActivityStatusCode.Error, ex.Message);
                Observability.EventsConsumed.WithLabels(bus.Producer, topic, "failed").Inc();
                await ToDlqAsync(msg, "failed", $"{ex.GetType().Name}: {ex.Message}", attempt, ct);
                await OnFailedAsync(e, ex, retryable, ct);
                return true;
            }
        }
    }

    private TimeSpan Backoff(int attempt, TimeSpan max)
    {
        var seconds = bus.RetryBackoff.TotalSeconds * Math.Pow(2, Math.Min(attempt - 1, 16));
        return TimeSpan.FromSeconds(Math.Min(seconds, max.TotalSeconds));
    }

    private async Task ToDlqAsync(ConsumeResult<string, string> msg, string reason, string error, int attempts,
        CancellationToken ct)
    {
        var topic = msg.Topic;
        await bus.ProduceRawAsync($"{topic}.dlq", msg.Message.Key, msg.Message.Value,
        [
            new("x-dlq-source-topic", topic), new("x-dlq-service", bus.Producer), new("x-dlq-reason", reason),
            new("x-dlq-error", error.Length > 2000 ? error[..2000] : error), new("x-dlq-attempts", attempts.ToString()),
            new("x-dlq-partition", msg.Partition.Value.ToString()), new("x-dlq-offset", msg.Offset.Value.ToString()),
            new("x-dlq-failed-at", DateTimeOffset.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")),
        ], ct);
        Observability.DlqMessages.WithLabels(bus.Producer, topic, reason).Inc();
        log.LogError("sent to {Topic}.dlq ({Reason}): {Error}", topic, reason, error);
    }

    private static ActivityContext ParentContext(Headers? headers)
    {
        if (headers is not null && headers.TryGetLastBytes(EventBus.TraceParentHeader, out var raw)
            && ActivityContext.TryParse(Encoding.ASCII.GetString(raw), null, out var parent))
            return parent;
        return default;
    }

    /// <summary>Недоступность базы или брокера: ждём, а не отправляем событие в DLQ.</summary>
    public static bool IsOutage(Exception ex) => ex switch
    {
        PostgresException pg => pg.IsTransient,
        NpgsqlException npg => npg.IsTransient || npg.InnerException is SocketException or TimeoutException,
        KafkaException kafka => !kafka.Error.IsFatal,
        SocketException or TimeoutException => true,
        _ => ex.InnerException is { } inner && IsOutage(inner),
    };

    /// <summary>Битое событие: повтор не поможет.</summary>
    public static bool IsDataError(Exception ex) =>
        ex is JsonException or KeyNotFoundException or FormatException or InvalidOperationException
            or ArgumentException;
}
