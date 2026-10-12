// Project API (ТЗ 5.2). Этап 1: проекты, загрузка видео в S3 по presigned URL (multipart с докачкой),
// публикация video.uploaded / script.uploaded, список сцен, статусы через SignalR.
// Этап 4: монтажный лист — правки строк с row_version, split/merge, перезапуск без потери правок.
using System.Text.Json;
using Cutsheet.Messaging;
using Cutsheet.ProjectApi;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.IdentityModel.Tokens;

var builder = WebApplication.CreateBuilder(args);
var config = builder.Configuration;

builder.Services.AddSingleton<EventBus>();
builder.Services.AddSingleton(Postgres.CreateDataSource(config));
builder.Services.AddSingleton<ProjectStore>();
builder.Services.AddSingleton<SheetStore>();
builder.Services.AddSingleton<ObjectStorage>();
builder.Services.AddSingleton<JwtKeys>();
builder.Services.AddHostedService<StatusConsumer>();

builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme).AddJwtBearer();
builder.Services.AddOptions<JwtBearerOptions>(JwtBearerDefaults.AuthenticationScheme)
    .Configure<JwtKeys>((o, keys) =>
    {
        o.MapInboundClaims = false;
        o.TokenValidationParameters = new TokenValidationParameters
        {
            ValidIssuer = config["Auth:Issuer"] ?? "cutsheet-auth",
            ValidAudience = config["Auth:Audience"] ?? "cutsheet",
            IssuerSigningKeyResolver = (_, _, _, _) => keys.Current(),
            ClockSkew = TimeSpan.FromSeconds(30),
        };
        o.Events = new JwtBearerEvents
        {
            // WebSocket не умеет заголовки: SignalR передаёт токен в access_token (его же читает Kong).
            OnMessageReceived = ctx =>
            {
                if (ctx.HttpContext.Request.Path.StartsWithSegments("/hubs")
                    && ctx.Request.Query["access_token"] is { Count: > 0 } token)
                    ctx.Token = token;
                return Task.CompletedTask;
            },
        };
    });
builder.Services.AddAuthorization();
builder.Services.AddSignalR().AddJsonProtocol(o =>
    o.PayloadSerializerOptions.PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower);
builder.Services.ConfigureHttpJsonOptions(o =>
    o.SerializerOptions.PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower);
builder.Services.AddOpenApi();

var app = builder.Build();
app.UseAuthentication();
app.UseAuthorization();

app.MapGet("/health", () => Results.Ok(new { service = "project-api", status = "ok" }));
app.MapOpenApi("/api/v1/openapi.json");
app.MapHub<ProjectsHub>(ProjectsHub.Path);

var api = app.MapGroup("/api/v1");
api.MapGet("/health", (HttpContext ctx) => Results.Ok(new
{
    service = "project-api",
    status = "ok",
    correlation_id = ctx.Request.Headers["X-Correlation-ID"].ToString(),
}));

var projects = api.MapGroup("/projects").RequireAuthorization();
projects.MapGet("/", Endpoints.ListProjects);
projects.MapPost("/", Endpoints.CreateProject);
projects.MapGet("/{id:guid}", Endpoints.GetProject);
projects.MapPost("/{id:guid}/uploads", Endpoints.StartUpload);
projects.MapGet("/{id:guid}/uploads/{uploadId:guid}", Endpoints.GetUpload);
projects.MapPost("/{id:guid}/uploads/{uploadId:guid}/complete", Endpoints.CompleteUpload);
SheetEndpoints.Map(projects);

app.Run();
