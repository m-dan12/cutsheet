using Cutsheet.Messaging;
using Microsoft.AspNetCore.SignalR;

namespace Cutsheet.ProjectApi;

/// <summary>
/// Читает export.completed / export.failed (Export Service → Project API), записывает итог в exports
/// и сообщает клиенту через SignalR (FR-G6, FR-E6). Общая группа и чтение с начала: итог экспорта
/// не теряется, даже если Project API был недоступен, а повтор события отсекает processed_events.
/// При нескольких экземплярах Project API клиенту нужен backplane SignalR (этап 6); до тех пор
/// клиент дополнительно опрашивает GET /exports/{id}.
/// </summary>
public sealed class ExportConsumer(EventBus bus, ExportStore exports, IHubContext<ProjectsHub> hub,
    ILogger<ExportConsumer> logger) : EventConsumer(bus, logger)
{
    protected override string[] Topics => ["export.completed", "export.failed"];
    protected override string GroupId => ExportStore.Consumer;

    protected override async Task HandleAsync(Envelope e, CancellationToken ct)
    {
        var p = e.Payload;
        var exportId = p.GetProperty("export_id").GetGuid();
        var completed = e.EventType == "export.completed";
        var row = await exports.Finish(e.EventId, exportId,
            completed ? p.GetProperty("result_uri").GetString() : null,
            completed ? null : p.GetProperty("error").GetString() ?? "ошибка экспорта", ct);
        if (row is null) return;
        await hub.Clients.Group(ProjectsHub.Group(row.ProjectId)).SendAsync("export",
            new ExportMessage(row.ProjectId, row.Id, row.Format, row.Status, row.Error), ct);
        Log.LogInformation("export {ExportId} {Status}", row.Id, row.Status);
    }
}
