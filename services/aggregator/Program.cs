// Aggregator / Orchestrator (ТЗ 5.6). Этап 0: читает scenes.detected и pipeline.failed,
// пишет в лог и публикует project.status-changed. Join, PostgreSQL и дедупликация — этапы 1–2.
using Cutsheet.Aggregator;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddSingleton<EventBus>();
builder.Services.AddHostedService<PipelineConsumer>();
var app = builder.Build();

app.MapGet("/health", () => Results.Ok(new { service = "aggregator", status = "ok" }));
app.Run();
