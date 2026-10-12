"""Чистая логика детекции: PySceneDetect, нормализация сцен, ключевые кадры."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import cv2


@dataclass(frozen=True)
class Detection:
    fps: float
    duration_ms: int
    cuts_ms: list[int]


def detect_cuts(video_path: str | Path, detector: str = "content", threshold: float = 27.0,
                min_scene_ms: int = 1000) -> Detection:
    """Находит склейки. Возвращает fps, длительность и моменты склеек в мс."""
    from scenedetect import AdaptiveDetector, ContentDetector, SceneManager, open_video

    video = open_video(str(video_path))
    fps = float(video.frame_rate)
    min_len = max(1, round(min_scene_ms * fps / 1000))
    if detector == "content":
        det = ContentDetector(threshold=threshold, min_scene_len=min_len)
    elif detector == "adaptive":
        det = AdaptiveDetector(adaptive_threshold=threshold, min_scene_len=min_len)
    else:
        raise ValueError(f"unknown detector: {detector}")
    sm = SceneManager()
    sm.add_detector(det)
    sm.detect_scenes(video)
    scenes = sm.get_scene_list()
    duration_ms = round(video.duration.seconds * 1000)
    # Начало каждой сцены, кроме первой, — это склейка.
    cuts = [round(start.seconds * 1000) for start, _ in scenes[1:]]
    return Detection(fps=fps, duration_ms=duration_ms, cuts_ms=cuts)


def normalize_scenes(cuts_ms: list[int], duration_ms: int, min_scene_ms: int) -> list[tuple[int, int]]:
    """Сцены без дыр от 0 до конца видео (FR-SD5), короткие склеены с соседями (FR-SD2)."""
    if duration_ms <= 0:
        raise ValueError("video has zero duration")
    bounds = sorted({c for c in cuts_ms if 0 < c < duration_ms})
    edges = [0, *bounds, duration_ms]
    scenes = [[a, b] for a, b in zip(edges, edges[1:])]
    merged: list[list[int]] = []
    for s in scenes:
        if merged and (s[1] - s[0] < min_scene_ms or merged[-1][1] - merged[-1][0] < min_scene_ms):
            merged[-1][1] = s[1]  # склеиваем с предыдущей
        else:
            merged.append(s)
    # Последняя сцена могла остаться короткой — приклеиваем к предыдущей.
    if len(merged) > 1 and merged[-1][1] - merged[-1][0] < min_scene_ms:
        merged[-2][1] = merged.pop()[1]
    return [(a, b) for a, b in merged]


def keyframe_times(start_ms: int, end_ms: int, n: int) -> list[int]:
    """n моментов внутри сцены: начало / середина / конец при n=3.

    Берём центры n равных отрезков (1/6, 1/2, 5/6 сцены), чтобы не попасть на
    кадр перехода у самой склейки.
    """
    length = end_ms - start_ms
    return [start_ms + round(length * (i + 0.5) / n) for i in range(n)]


def extract_frames(video_path: str | Path, times_ms: list[int], out_dir: str | Path,
                   prefix: str, jpeg_quality: int = 85) -> list[Path]:
    """Сохраняет кадры в JPEG. Возвращает пути в порядке times_ms."""
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        raise RuntimeError(f"cannot open video: {video_path}")
    paths = []
    try:
        for i, t in enumerate(times_ms):
            cap.set(cv2.CAP_PROP_POS_MSEC, t)
            ok, frame = cap.read()
            if not ok:
                raise RuntimeError(f"cannot read frame at {t} ms")
            p = out_dir / f"{prefix}_{i}.jpg"
            cv2.imwrite(str(p), frame, [cv2.IMWRITE_JPEG_QUALITY, jpeg_quality])
            paths.append(p)
    finally:
        cap.release()
    return paths
