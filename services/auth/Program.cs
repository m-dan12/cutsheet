// Auth Service (ТЗ 5.2b). Этап 0: каркас с healthcheck и заглушками эндпоинтов.
var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

app.MapGet("/health", () => Results.Ok(new { service = "auth", status = "ok" }));

var auth = app.MapGroup("/auth");
auth.MapGet("/.well-known/jwks.json", () => Results.Ok(new { keys = Array.Empty<object>() }));
auth.MapPost("/register", () => NotImplemented("register"));
auth.MapPost("/login", () => NotImplemented("login"));
auth.MapPost("/refresh", () => NotImplemented("refresh"));

app.Run();

static IResult NotImplemented(string what) =>
    Results.Problem($"{what}: будет на этапе 1", statusCode: StatusCodes.Status501NotImplemented);
