using Npgsql;

namespace Cutsheet.Auth;

public sealed record User(Guid Id, string Email, string PasswordHash, string Role);

/// <summary>Доступ к схеме auth (пишет только Auth Service, ТЗ 6.1).</summary>
public sealed class UserStore(NpgsqlDataSource db)
{
    public async Task<User?> FindByEmail(string email, CancellationToken ct)
    {
        await using var cmd = db.CreateCommand(
            "SELECT id, email, password_hash, role FROM auth.users WHERE email = $1");
        cmd.Parameters.AddWithValue(email);
        return await ReadUser(cmd, ct);
    }

    /// <summary>Создаёт пользователя; null — email уже занят.</summary>
    public async Task<User?> Create(string email, string passwordHash, CancellationToken ct)
    {
        await using var cmd = db.CreateCommand("""
            INSERT INTO auth.users (id, email, password_hash) VALUES ($1, $2, $3)
            ON CONFLICT (email) DO NOTHING
            RETURNING id, email, password_hash, role
            """);
        cmd.Parameters.AddWithValue(Guid.NewGuid());
        cmd.Parameters.AddWithValue(email);
        cmd.Parameters.AddWithValue(passwordHash);
        return await ReadUser(cmd, ct);
    }

    public async Task UpdatePasswordHash(Guid userId, string passwordHash, CancellationToken ct)
    {
        await using var cmd = db.CreateCommand("UPDATE auth.users SET password_hash = $2 WHERE id = $1");
        cmd.Parameters.AddWithValue(userId);
        cmd.Parameters.AddWithValue(passwordHash);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task AddRefreshToken(Guid userId, string tokenHash, DateTimeOffset expiresAt, CancellationToken ct)
    {
        await using var cmd = db.CreateCommand(
            "INSERT INTO auth.refresh_tokens (id, user_id, token_hash, expires_at) VALUES ($1, $2, $3, $4)");
        cmd.Parameters.AddWithValue(Guid.NewGuid());
        cmd.Parameters.AddWithValue(userId);
        cmd.Parameters.AddWithValue(tokenHash);
        cmd.Parameters.AddWithValue(expiresAt);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    /// <summary>
    /// Отзывает действующий refresh-токен и возвращает его владельца. Токен одноразовый:
    /// повторное предъявление (или чужой, просроченный токен) даёт null.
    /// </summary>
    public async Task<User?> ConsumeRefreshToken(string tokenHash, CancellationToken ct)
    {
        await using var cmd = db.CreateCommand("""
            WITH t AS (
                UPDATE auth.refresh_tokens SET revoked_at = now()
                WHERE token_hash = $1 AND revoked_at IS NULL AND expires_at > now()
                RETURNING user_id)
            SELECT u.id, u.email, u.password_hash, u.role FROM auth.users u JOIN t ON t.user_id = u.id
            """);
        cmd.Parameters.AddWithValue(tokenHash);
        return await ReadUser(cmd, ct);
    }

    private static async Task<User?> ReadUser(NpgsqlCommand cmd, CancellationToken ct)
    {
        await using var r = await cmd.ExecuteReaderAsync(ct);
        return await r.ReadAsync(ct)
            ? new User(r.GetGuid(0), r.GetString(1), r.GetString(2), r.GetString(3))
            : null;
    }
}
