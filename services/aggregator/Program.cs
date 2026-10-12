// Aggregator / Orchestrator (ТЗ 5.6). Сохраняет scenes.detected в PostgreSQL (сцены, ключевые
// кадры, состояние пайплайна), делает join сцен с dialogue.aligned, режет реплики по сценам,
// публикует scene.ready-for-enrichment и project.status-changed. Сбор обогащения — этап 3.
using Cutsheet.Aggregator;
using Cutsheet.Aggregator.Dialogue;
using Cutsheet.Messaging;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddSingleton<EventBus>();
builder.Services.AddSingleton(Postgres.CreateDataSource(builder.Configuration));
builder.Services.AddSingleton<IEventPublisher>(sp => sp.GetRequiredService<EventBus>());
builder.Services.AddSingleton<DialogueJoin>();
builder.Services.AddHostedService<PipelineConsumer>();
var app = builder.Build();

app.MapGet("/health", () => Results.Ok(new { service = "aggregator", status = "ok" }));
app.Run();
