// Auth Service (ТЗ 5.2b): регистрация и вход по email и паролю, JWT RS256 + refresh-токены,
// публичный ключ в JWKS и в файле для Kong.
using System.Net.Mail;
using Cutsheet.Auth;
using Microsoft.AspNetCore.Identity;
using Npgsql;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddSingleton(NpgsqlDataSource.Create(builder.Configuration.GetConnectionString("Postgres")
    ?? "Host=localhost;Database=cutsheet;Username=cutsheet;Password=cutsheet"));
builder.Services.AddSingleton<SigningKey>();
builder.Services.AddSingleton<TokenService>();
builder.Services.AddSingleton<UserStore>();
builder.Services.AddSingleton<IPasswordHasher<User>, PasswordHasher<User>>();
builder.Services.ConfigureHttpJsonOptions(o =>
    o.SerializerOptions.PropertyNamingPolicy = System.Text.Json.JsonNamingPolicy.SnakeCaseLower);
var app = builder.Build();

// Ключ создаётся при старте, а не при первом запросе: Kong ждёт публичный ключ в томе.
app.Services.GetRequiredService<SigningKey>();

app.MapGet("/health", () => Results.Ok(new { service = "auth", status = "ok" }));

var auth = app.MapGroup("/auth");
auth.MapGet("/.well-known/jwks.json", (SigningKey key) => Results.Ok(new { keys = new[] { key.Jwk() } }));

auth.MapPost("/register", async (Credentials body, UserStore users, IPasswordHasher<User> hasher,
    TokenService tokens, CancellationToken ct) =>
{
    if (Validate(body) is { } problem) return problem;
    var email = Normalize(body.Email!);
    var hash = hasher.HashPassword(null!, body.Password!);
    var user = await users.Create(email, hash, ct);
    if (user is null)
        return Results.Problem("пользователь с таким email уже есть", statusCode: StatusCodes.Status409Conflict);
    return Results.Ok(await Issue(user, users, tokens, ct));
});

auth.MapPost("/login", async (Credentials body, UserStore users, IPasswordHasher<User> hasher,
    TokenService tokens, CancellationToken ct) =>
{
    var user = await users.FindByEmail(Normalize(body.Email ?? ""), ct);
    var check = user is null
        ? PasswordVerificationResult.Failed
        : hasher.VerifyHashedPassword(user, user.PasswordHash, body.Password ?? "");
    if (check == PasswordVerificationResult.Failed)
        return Results.Problem("неверный email или пароль", statusCode: StatusCodes.Status401Unauthorized);
    if (check == PasswordVerificationResult.SuccessRehashNeeded)
        await users.UpdatePasswordHash(user!.Id, hasher.HashPassword(user, body.Password!), ct);
    return Results.Ok(await Issue(user!, users, tokens, ct));
});

auth.MapPost("/refresh", async (RefreshRequest body, UserStore users, TokenService tokens, CancellationToken ct) =>
{
    var user = string.IsNullOrEmpty(body.RefreshToken)
        ? null
        : await users.ConsumeRefreshToken(TokenService.Hash(body.RefreshToken), ct);
    return user is null
        ? Results.Problem("refresh-токен недействителен", statusCode: StatusCodes.Status401Unauthorized)
        : Results.Ok(await Issue(user, users, tokens, ct));
});

app.Run();

static async Task<TokenResponse> Issue(User user, UserStore users, TokenService tokens, CancellationToken ct)
{
    var refresh = TokenService.NewRefreshToken();
    await users.AddRefreshToken(user.Id, TokenService.Hash(refresh), DateTimeOffset.UtcNow + tokens.RefreshLifetime, ct);
    return new TokenResponse(tokens.CreateAccessToken(user.Id, user.Email, user.Role), refresh,
        (int)tokens.AccessLifetime.TotalSeconds, "Bearer", new UserInfo(user.Id, user.Email, user.Role));
}

static string Normalize(string email) => email.Trim().ToLowerInvariant();

static IResult? Validate(Credentials c)
{
    var errors = new Dictionary<string, string[]>();
    if (string.IsNullOrWhiteSpace(c.Email) || !MailAddress.TryCreate(c.Email.Trim(), out _))
        errors["email"] = ["некорректный email"];
    if (string.IsNullOrEmpty(c.Password) || c.Password.Length < 8)
        errors["password"] = ["пароль не короче 8 символов"];
    return errors.Count > 0 ? Results.ValidationProblem(errors) : null;
}

record Credentials(string? Email, string? Password);
record RefreshRequest(string? RefreshToken);
record UserInfo(Guid Id, string Email, string Role);
record TokenResponse(string AccessToken, string RefreshToken, int ExpiresIn, string TokenType, UserInfo User);
