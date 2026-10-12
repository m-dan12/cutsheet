using System.Text.Json;
using Confluent.Kafka;
using Cutsheet.Messaging;
using Microsoft.AspNetCore.SignalR;

namespace Cutsheet.ProjectApi;

/// <summary>
/// Читает project.status-changed (Aggregator → Project API), обновляет статус проекта и
/// рассылает его подписчикам хаба (FR-G8).
/// </summary>
public sealed class StatusConsumer(EventBus bus, ProjectStore projects, IHubContext<ProjectsHub> hub,
    ILogger<StatusConsumer> logger) : EventConsumer(bus, logger)
{
    protected override string[] Topics => ["project.status-changed"];

    // Своя группа на экземпляр: каждый экземпляр держит свои SignalR-подключения и должен видеть
    // все статусы. Обновление строки проекта идемпотентно.
    protected override string GroupId => $"project-api-{Environment.MachineName}";
    protected override AutoOffsetReset OffsetReset => AutoOffsetReset.Latest;

    protected override async Task HandleAsync(Envelope e, CancellationToken ct)
    {
        var p = e.Payload;
        var msg = new StatusMessage(e.ProjectId, p.GetProperty("stage").GetString()!, p.GetProperty("status").GetString()!,
            p.TryGetProperty("progress", out var pr) && pr.ValueKind == JsonValueKind.Number ? pr.GetDouble() : null,
            p.TryGetProperty("error", out var er) && er.ValueKind == JsonValueKind.String ? er.GetString() : null);
        await projects.SetStatus(e.ProjectId, msg.Stage, msg.Status, msg.Error, ct);
        await hub.Clients.Group(ProjectsHub.Group(e.ProjectId)).SendAsync("status", msg, ct);
        Log.LogInformation("status {Stage}/{Status} for project {ProjectId}", msg.Stage, msg.Status, e.ProjectId);
    }
}
