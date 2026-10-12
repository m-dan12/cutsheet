namespace Cutsheet.Aggregator.Dialogue;

public sealed record SceneSpan(int Index, long StartMs, long EndMs);

public sealed record Replica(
    long StartMs, long EndMs, string? Role, string Text, string? SpokenText,
    string? ScriptLineId, double? Confidence, bool Matched);

/// <summary>Нарезка реплик по сценам (FR-A2).</summary>
public static class ReplicaSlicer
{
    /// <summary>
    /// Реплика относится к сцене с максимальным пересечением по времени; при равенстве — к более
    /// ранней. Реплика на границе не дублируется. Реплика вне всех сцен (или нулевой длины) —
    /// к ближайшей сцене. Внутри сцены реплики идут по времени.
    /// </summary>
    public static Dictionary<int, List<Replica>> Slice(IReadOnlyList<SceneSpan> scenes, IEnumerable<Replica> replicas)
    {
        var result = scenes.ToDictionary(s => s.Index, _ => new List<Replica>());
        if (scenes.Count == 0) return result;
        var ordered = scenes.OrderBy(s => s.StartMs).ToList();

        foreach (var r in replicas)
        {
            SceneSpan? best = null;
            long bestOverlap = 0;
            foreach (var s in ordered)
            {
                var overlap = Math.Min(r.EndMs, s.EndMs) - Math.Max(r.StartMs, s.StartMs);
                if (overlap > bestOverlap) (best, bestOverlap) = (s, overlap);
            }
            best ??= Nearest(ordered, r);
            result[best.Index].Add(r);
        }
        foreach (var list in result.Values)
            list.Sort((a, b) => a.StartMs != b.StartMs ? a.StartMs.CompareTo(b.StartMs) : a.EndMs.CompareTo(b.EndMs));
        return result;
    }

    private static SceneSpan Nearest(List<SceneSpan> scenes, Replica r)
    {
        var mid = (r.StartMs + r.EndMs) / 2;
        return scenes.MinBy(s => mid < s.StartMs ? s.StartMs - mid : mid >= s.EndMs ? mid - s.EndMs + 1 : 0)!;
    }
}
