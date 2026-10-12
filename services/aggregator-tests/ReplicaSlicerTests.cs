using Cutsheet.Aggregator.Dialogue;
using Xunit;

namespace Cutsheet.Aggregator.Tests;

public class ReplicaSlicerTests
{
    private static readonly SceneSpan[] Scenes = [new(0, 0, 2000), new(1, 2000, 5000), new(2, 5000, 9000)];

    private static Replica R(long start, long end, string text = "x") =>
        new(start, end, "ИВАН", text, text, null, 1.0, true);

    [Fact]
    public void ReplicaGoesToSceneWithMaxOverlap()
    {
        var sliced = ReplicaSlicer.Slice(Scenes, [R(1500, 4000, "a"), R(4800, 5400, "b"), R(100, 900, "c")]);
        Assert.Equal(["c"], sliced[0].Select(r => r.Text));
        Assert.Equal(["a"], sliced[1].Select(r => r.Text));   // 2000 мс во второй против 500 в первой
        Assert.Equal(["b"], sliced[2].Select(r => r.Text));
    }

    [Fact]
    public void BoundaryReplicaIsNotDuplicatedAndTieGoesToEarlierScene()
    {
        var sliced = ReplicaSlicer.Slice(Scenes, [R(1000, 3000)]);
        Assert.Single(sliced[0]);
        Assert.Empty(sliced[1]);
    }

    [Fact]
    public void ZeroLengthAndOutOfRangeReplicasGoToNearestScene()
    {
        var sliced = ReplicaSlicer.Slice(Scenes, [R(2000, 2000, "z"), R(9500, 9800, "tail")]);
        Assert.Equal(["z"], sliced[1].Select(r => r.Text));
        Assert.Equal(["tail"], sliced[2].Select(r => r.Text));
    }

    [Fact]
    public void ReplicasInsideSceneAreOrderedByTime()
    {
        var sliced = ReplicaSlicer.Slice(Scenes, [R(7000, 8000, "late"), R(5100, 5500, "early")]);
        Assert.Equal(["early", "late"], sliced[2].Select(r => r.Text));
    }

    [Fact]
    public void NoScenesGivesEmptyResult() => Assert.Empty(ReplicaSlicer.Slice([], [R(0, 1)]));
}

public class DeterministicGuidTests
{
    [Fact]
    public void MatchesRfc4122Uuid5()
    {
        // python: uuid.uuid5(uuid.NAMESPACE_DNS, "python.org") == 886313e1-3b8a-5372-9b90-0c9aee199e5d
        Assert.Equal(Guid.Parse("886313e1-3b8a-5372-9b90-0c9aee199e5d"),
            DeterministicGuid.Create(Guid.Parse("6ba7b810-9dad-11d1-80b4-00c04fd430c8"), "python.org"));
        Assert.Equal(DeterministicGuid.Create("a"), DeterministicGuid.Create("a"));
        Assert.NotEqual(DeterministicGuid.Create("a"), DeterministicGuid.Create("b"));
    }
}
