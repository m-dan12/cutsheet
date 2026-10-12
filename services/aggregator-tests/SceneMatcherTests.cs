using Xunit;

namespace Cutsheet.Aggregator.Tests;

public sealed class SceneMatcherTests
{
    private static List<SceneInterval> Spans(params long[] bounds) =>
        bounds.Zip(bounds.Skip(1), (a, b) => new SceneInterval(a, b)).ToList();

    [Fact]
    public void SameScenesKeepTheirRows()
    {
        var m = SceneMatcher.Match(Spans(0, 2000, 5000, 9000), Spans(0, 2000, 5000, 9000));
        Assert.Equal([0, 1, 2], m.Reuse);
        Assert.Empty(m.Orphans);
    }

    [Fact]
    public void ShiftedCutsStillMatchByOverlap()
    {
        var m = SceneMatcher.Match(Spans(0, 2000, 5000, 9000), Spans(0, 2200, 4800, 9000));
        Assert.Equal([0, 1, 2], m.Reuse);
    }

    [Fact]
    public void MergedSceneLeavesOrphanPointingToItsSuccessor()
    {
        // Старые 0–2 и 2–5 стали одной сценой 0–5: её строка — старая 2–5 (больше пересечение).
        var m = SceneMatcher.Match(Spans(0, 2000, 5000, 9000), Spans(0, 5000, 9000));
        Assert.Equal([1, 2], m.Reuse);
        Assert.Equal(new Dictionary<int, int> { [0] = 0 }, m.Orphans);
    }

    [Fact]
    public void NewCutAddsRow()
    {
        var m = SceneMatcher.Match(Spans(0, 5000, 9000), Spans(0, 2000, 5000, 9000));
        Assert.Equal([-1, 0, 1], m.Reuse);
        Assert.Empty(m.Orphans);
    }
}
