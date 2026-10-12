using System.Security.Cryptography;
using Microsoft.IdentityModel.Tokens;

namespace Cutsheet.Auth;

/// <summary>
/// RSA-ключ подписи JWT. При первом старте генерируется и сохраняется в каталог Auth:KeyDir
/// (том auth-keys): закрытый ключ читает только Auth Service, публичный — Kong (consumer jwt)
/// и Project API. Ротация ключей — вне этапа 1.
/// </summary>
public sealed class SigningKey
{
    public const string PrivateFile = "jwt-private.pem";
    public const string PublicFile = "jwt-public.pem";

    public SigningKey(IConfiguration config, ILogger<SigningKey> log)
    {
        var dir = config["Auth:KeyDir"] ?? Path.Combine(AppContext.BaseDirectory, "keys");
        Directory.CreateDirectory(dir);
        var privatePath = Path.Combine(dir, PrivateFile);
        RSA rsa;
        if (File.Exists(privatePath))
        {
            rsa = RSA.Create();
            rsa.ImportFromPem(File.ReadAllText(privatePath));
        }
        else
        {
            rsa = RSA.Create(2048);
            WriteAtomic(privatePath, rsa.ExportRSAPrivateKeyPem(), UnixFileMode.UserRead | UnixFileMode.UserWrite);
            log.LogInformation("generated new JWT signing key in {Dir}", dir);
        }
        // Публичный ключ перезаписывается при каждом старте: Kong ждёт его появления.
        WriteAtomic(Path.Combine(dir, PublicFile), rsa.ExportSubjectPublicKeyInfoPem(),
            UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.GroupRead | UnixFileMode.OtherRead);

        var p = rsa.ExportParameters(false);
        KeyId = Base64UrlEncoder.Encode(SHA256.HashData([.. p.Modulus!, .. p.Exponent!]))[..16];
        Key = new RsaSecurityKey(rsa) { KeyId = KeyId };
        Credentials = new SigningCredentials(Key, SecurityAlgorithms.RsaSha256);
    }

    public string KeyId { get; }
    public RsaSecurityKey Key { get; }
    public SigningCredentials Credentials { get; }

    /// <summary>Публичная часть ключа в формате JWK (FR-AU2).</summary>
    public object Jwk()
    {
        var p = Key.Rsa.ExportParameters(false);
        return new
        {
            kty = "RSA",
            use = "sig",
            alg = SecurityAlgorithms.RsaSha256,
            kid = KeyId,
            n = Base64UrlEncoder.Encode(p.Modulus),
            e = Base64UrlEncoder.Encode(p.Exponent),
        };
    }

    private static void WriteAtomic(string path, string content, UnixFileMode mode)
    {
        var tmp = path + ".tmp";
        File.WriteAllText(tmp, content);
        if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(tmp, mode);
        File.Move(tmp, path, overwrite: true);
    }
}
