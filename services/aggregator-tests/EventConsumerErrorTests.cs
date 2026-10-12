using System.Net.Sockets;
using System.Text.Json;
using Confluent.Kafka;
using Cutsheet.Messaging;
using Npgsql;
using Xunit;

namespace Cutsheet.Aggregator.Tests;

/// <summary>Классификация ошибок консьюмера (этап 6): ждать, повторять или сразу в DLQ.</summary>
public sealed class EventConsumerErrorTests
{
    [Fact]
    public void DatabaseAndBrokerOutagesAreWaitedOut()
    {
        Assert.True(EventConsumer.IsOutage(new NpgsqlException("connect failed", new SocketException())));
        Assert.True(EventConsumer.IsOutage(new TimeoutException()));
        Assert.True(EventConsumer.IsOutage(new KafkaException(ErrorCode.Local_Transport)));
        Assert.True(EventConsumer.IsOutage(new InvalidOperationException("wrapped", new SocketException())));
    }

    [Fact]
    public void BrokenEventsGoStraightToDlq()
    {
        var payload = JsonDocument.Parse("""{"fps": "x"}""").RootElement;
        var ex = Record.Exception(() => payload.GetProperty("fps").GetDouble());
        Assert.True(EventConsumer.IsDataError(ex!));
        Assert.True(EventConsumer.IsDataError(new KeyNotFoundException()));
        Assert.False(EventConsumer.IsOutage(ex!));
    }

    [Fact]
    public void OtherFailuresAreRetriedThenDlq()
    {
        var ex = new NotSupportedException("bug");
        Assert.False(EventConsumer.IsOutage(ex));
        Assert.False(EventConsumer.IsDataError(ex));
    }
}
