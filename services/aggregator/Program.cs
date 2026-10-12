// Aggregator / Orchestrator (ТЗ 5.6): читает scenes.detected, dialogue.aligned и pipeline.failed,
// делает join сцен и диалогов в PostgreSQL и публикует scene.ready-for-enrichment и project.status-changed.
using Cutsheet.Aggregator;
using Cutsheet.Aggregator.Dialogue;
using Npgsql;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddSingleton(_ => NpgsqlDataSource.Create(
    builder.Configuration.GetConnectionString("Postgres")
    ?? "Host=localhost;Database=cutsheet;Username=cutsheet;Password=cutsheet"));
builder.Services.AddSingleton<EventBus>();
builder.Services.AddSingleton<IEventPublisher>(sp => sp.GetRequiredService<EventBus>());
builder.Services.AddSingleton<DialogueJoin>();
builder.Services.AddHostedService<PipelineConsumer>();
var app = builder.Build();

app.MapGet("/health", () => Results.Ok(new { service = "aggregator", status = "ok" }));
app.Run();
