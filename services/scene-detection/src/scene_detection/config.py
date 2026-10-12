from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    detector: str = "content"          # content | adaptive (FR-SD1)
    threshold: float = 27.0            # для content; для adaptive — adaptive_threshold
    min_scene_ms: int = 1000           # FR-SD2: короткие сцены склеиваются с соседней
    keyframes: int = 3                 # FR-SD3
    jpeg_quality: int = 85
    bucket: str = "cutsheet"
    work_dir: str = "/tmp/scene-detection"

    @classmethod
    def from_env(cls) -> "Settings":
        e = os.environ.get
        default_threshold = "27.0" if e("SD_DETECTOR", "content") == "content" else "3.0"
        return cls(
            detector=e("SD_DETECTOR", "content"),
            threshold=float(e("SD_THRESHOLD", default_threshold)),
            min_scene_ms=int(e("SD_MIN_SCENE_MS", "1000")),
            keyframes=int(e("SD_KEYFRAMES", "3")),
            jpeg_quality=int(e("SD_JPEG_QUALITY", "85")),
            bucket=e("S3_BUCKET", "cutsheet"),
            work_dir=e("SD_WORK_DIR", "/tmp/scene-detection"),
        )
