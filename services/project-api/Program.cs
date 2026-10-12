// Project API (ТЗ 5.2). Этап 0: каркас с healthcheck; REST, SignalR и публикация команд — этап 1.
var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

app.MapGet("/health", () => Results.Ok(new { service = "project-api", status = "ok" }));

var api = app.MapGroup("/api/v1");
api.MapGet("/health", (HttpContext ctx) => Results.Ok(new
{
    service = "project-api",
    status = "ok",
    correlationId = ctx.Request.Headers["X-Correlation-ID"].ToString(),
}));
api.MapGet("/projects", () => Results.Ok(Array.Empty<object>()));
api.MapPost("/projects", () =>
    Results.Problem("создание проекта: этап 1", statusCode: StatusCodes.Status501NotImplemented));

app.Run();
