from pathlib import Path

import cv2
import numpy as np
import pytest


def make_video(path: Path, segments: list[tuple[tuple[int, int, int], float]], fps: int = 25) -> Path:
    """Видео из однотонных сегментов (BGR-цвет, секунды) с лёгким шумом."""
    w, h = 160, 90
    writer = cv2.VideoWriter(str(path), cv2.VideoWriter_fourcc(*"mp4v"), fps, (w, h))
    rng = np.random.default_rng(0)
    for color, seconds in segments:
        for _ in range(round(seconds * fps)):
            frame = np.full((h, w, 3), color, np.uint8)
            frame = np.clip(frame.astype(int) + rng.integers(-3, 4, frame.shape), 0, 255).astype(np.uint8)
            writer.write(frame)
    writer.release()
    return path


@pytest.fixture
def three_shots(tmp_path):
    # тёмно-серый 2 с, красный 3 с, белый 0.4 с (короче минимума), синий 2 с.
    # Цвета отличаются по яркости/насыщенности: ContentDetector слабо реагирует на смену одного оттенка.
    return make_video(tmp_path / "film.mp4", [((30, 30, 30), 2), ((0, 0, 255), 3), ((255, 255, 255), 0.4),
                                              ((200, 80, 0), 2)])
