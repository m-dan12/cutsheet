using System.Security.Cryptography;
using Microsoft.IdentityModel.Tokens;

namespace Cutsheet.ProjectApi;

/// <summary>
/// Публичный ключ Auth Service из общего тома (Auth:PublicKeyPath). Kong уже проверил подпись,
/// здесь проверка повторяется, чтобы Project API не доверял запросам в обход шлюза.
/// Файл перечитывается при изменении: Auth мог стартовать позже или сменить ключ.
/// </summary>
public sealed class JwtKeys(IConfiguration config, ILogger<JwtKeys> log)
{
    private readonly string _path = config["Auth:PublicKeyPath"] ?? "/keys/jwt-public.pem";
    private readonly Lock _lock = new();
    private DateTime _loadedAt;
    private SecurityKey[] _keys = [];

    public IEnumerable<SecurityKey> Current()
    {
        lock (_lock)
        {
            if (!File.Exists(_path)) return _keys;
            var mtime = File.GetLastWriteTimeUtc(_path);
            if (mtime == _loadedAt) return _keys;
            try
            {
                var rsa = RSA.Create();
                rsa.ImportFromPem(File.ReadAllText(_path));
                _keys = [new RsaSecurityKey(rsa)];
                _loadedAt = mtime;
                log.LogInformation("loaded JWT public key from {Path}", _path);
            }
            catch (Exception ex) when (ex is IOException or CryptographicException or ArgumentException)
            {
                log.LogWarning("cannot read JWT public key {Path}: {Error}", _path, ex.Message);
            }
            return _keys;
        }
    }
}
