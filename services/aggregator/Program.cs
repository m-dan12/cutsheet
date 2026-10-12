// Aggregator / Orchestrator (ТЗ 5.6). Этап 1: сохраняет scenes.detected в PostgreSQL
// (сцены, ключевые кадры, состояние пайплайна) и публикует project.status-changed.
// Join с диалогами и обогащением — этапы 2–3.
using Cutsheet.Aggregator;
using Cutsheet.Messaging;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddSingleton<EventBus>();
builder.Services.AddSingleton(Postgres.CreateDataSource(builder.Configuration));
builder.Services.AddHostedService<PipelineConsumer>();
var app = builder.Build();

app.MapGet("/health", () => Results.Ok(new { service = "aggregator", status = "ok" }));
app.Run();
