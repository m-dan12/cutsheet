import pytest

from scene_detection.detect import detect_cuts, extract_frames, keyframe_times, normalize_scenes


def test_normalize_covers_whole_video_without_gaps():
    scenes = normalize_scenes([2000, 5000, 5400], 7400, 1000)
    assert scenes[0][0] == 0 and scenes[-1][1] == 7400
    assert all(a[1] == b[0] for a, b in zip(scenes, scenes[1:]))
    assert scenes == [(0, 2000), (2000, 5400), (5400, 7400)]  # 0.4 с приклеено к предыдущей


def test_normalize_short_first_and_last():
    assert normalize_scenes([300, 4000], 5000, 1000) == [(0, 4000), (4000, 5000)]
    assert normalize_scenes([2000, 4700], 5000, 1000) == [(0, 2000), (2000, 5000)]
    assert normalize_scenes([], 500, 1000) == [(0, 500)]


def test_normalize_ignores_out_of_range_and_duplicate_cuts():
    assert normalize_scenes([0, 2000, 2000, 9000], 4000, 1000) == [(0, 2000), (2000, 4000)]


def test_normalize_rejects_empty_video():
    with pytest.raises(ValueError):
        normalize_scenes([], 0, 1000)


def test_keyframe_times_inside_scene():
    assert keyframe_times(0, 6000, 3) == [1000, 3000, 5000]
    assert keyframe_times(1000, 2000, 1) == [1500]


def test_detect_cuts_on_synthetic_video(three_shots):
    det = detect_cuts(three_shots, min_scene_ms=300)
    assert det.fps == pytest.approx(25)
    assert det.duration_ms == pytest.approx(7400, abs=40)
    assert [round(c / 100) for c in det.cuts_ms] == [20, 50, 54]


def test_extract_frames(three_shots, tmp_path):
    paths = extract_frames(three_shots, [500, 3000], tmp_path / "f", "s")
    assert [p.name for p in paths] == ["s_0.jpg", "s_1.jpg"]
    assert all(p.stat().st_size > 0 for p in paths)
