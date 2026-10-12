namespace Cutsheet.Aggregator;

public sealed record SceneInterval(long StartMs, long EndMs);

/// <param name="Reuse">Для каждой новой сцены — индекс старой, чью строку она занимает, или -1.</param>
/// <param name="Orphans">Старые сцены без пары → индекс новой сцены, куда переносятся их правки.</param>
public sealed record SceneMatch(int[] Reuse, Dictionary<int, int> Orphans);

/// <summary>
/// Сопоставление сцен повторной детекции со строками листа (FR-A5): строка сохраняет id, а с ним
/// правки плана, описания и реплик. Пары выбираются жадно по наибольшему пересечению по времени.
/// </summary>
public static class SceneMatcher
{
    public static SceneMatch Match(IReadOnlyList<SceneInterval> old, IReadOnlyList<SceneInterval> fresh)
    {
        var pairs = new List<(long Overlap, int Old, int New)>();
        for (var i = 0; i < old.Count; i++)
            for (var j = 0; j < fresh.Count; j++)
                if (Overlap(old[i], fresh[j]) is var o and > 0) pairs.Add((o, i, j));

        var reuse = Enumerable.Repeat(-1, fresh.Count).ToArray();
        var used = new bool[old.Count];
        foreach (var (_, i, j) in pairs.OrderByDescending(p => p.Overlap).ThenBy(p => p.Old).ThenBy(p => p.New))
        {
            if (used[i] || reuse[j] >= 0) continue;
            used[i] = true;
            reuse[j] = i;
        }

        var orphans = new Dictionary<int, int>();
        if (fresh.Count == 0) return new SceneMatch(reuse, orphans);
        for (var i = 0; i < old.Count; i++)
        {
            if (used[i]) continue;
            var best = Enumerable.Range(0, fresh.Count)
                .OrderByDescending(j => Overlap(old[i], fresh[j]))
                .ThenBy(j => Distance(old[i], fresh[j]))
                .First();
            orphans[i] = best;
        }
        return new SceneMatch(reuse, orphans);
    }

    private static long Overlap(SceneInterval a, SceneInterval b) =>
        Math.Min(a.EndMs, b.EndMs) - Math.Max(a.StartMs, b.StartMs);

    private static long Distance(SceneInterval a, SceneInterval b) =>
        Math.Abs((a.StartMs + a.EndMs) / 2 - (b.StartMs + b.EndMs) / 2);
}
