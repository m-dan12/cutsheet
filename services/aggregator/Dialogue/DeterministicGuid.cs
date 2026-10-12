using System.Security.Cryptography;
using System.Text;

namespace Cutsheet.Aggregator.Dialogue;

/// <summary>UUID v5 (RFC 4122): одинаковый вход — одинаковый id. Повторная обработка события
/// даёт те же id сцен и событий, и потребители отбрасывают дубликаты.</summary>
public static class DeterministicGuid
{
    private static readonly Guid Namespace = Guid.Parse("2d1f6b0e-3c9a-4b57-9e0d-6a8f4c2b1e73");

    public static Guid Create(string name) => Create(Namespace, name);

    public static Guid Create(Guid ns, string name)
    {
        var nsBytes = ns.ToByteArray(true); // big-endian, как в RFC
        var input = nsBytes.Concat(Encoding.UTF8.GetBytes(name)).ToArray();
        var hash = SHA1.HashData(input);
        var b = hash[..16];
        b[6] = (byte)((b[6] & 0x0F) | 0x50);
        b[8] = (byte)((b[8] & 0x3F) | 0x80);
        return new Guid(b, true);
    }
}
