using System.Security.Claims;
using System.Security.Cryptography;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Tokens;

namespace Cutsheet.Auth;

/// <summary>Выпуск access-токенов (JWT RS256) и refresh-токенов (FR-AU2).</summary>
public sealed class TokenService(SigningKey key, IConfiguration config)
{
    // iss совпадает с key в jwt_secrets consumer'а Kong: по нему шлюз выбирает ключ проверки.
    public string Issuer { get; } = config["Auth:Issuer"] ?? "cutsheet-auth";
    public string Audience { get; } = config["Auth:Audience"] ?? "cutsheet";
    public TimeSpan AccessLifetime { get; } = TimeSpan.FromMinutes(config.GetValue("Auth:AccessMinutes", 15));
    public TimeSpan RefreshLifetime { get; } = TimeSpan.FromDays(config.GetValue("Auth:RefreshDays", 30));

    public string CreateAccessToken(Guid userId, string email, string role)
    {
        var now = DateTime.UtcNow;
        return new JsonWebTokenHandler().CreateToken(new SecurityTokenDescriptor
        {
            Issuer = Issuer,
            Audience = Audience,
            IssuedAt = now,
            NotBefore = now,
            Expires = now + AccessLifetime,
            SigningCredentials = key.Credentials,
            Subject = new ClaimsIdentity(
            [
                new Claim(JwtRegisteredClaimNames.Sub, userId.ToString()),
                new Claim(JwtRegisteredClaimNames.Email, email),
                new Claim("role", role),
            ]),
        });
    }

    /// <summary>Случайный refresh-токен; в БД хранится только его SHA-256.</summary>
    public static string NewRefreshToken() => Base64UrlEncoder.Encode(RandomNumberGenerator.GetBytes(32));

    public static string Hash(string refreshToken) =>
        Convert.ToHexString(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(refreshToken)));
}
