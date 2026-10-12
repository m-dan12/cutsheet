from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Settings:
    # Модели MediaPipe скачиваются при первом кадре (не при сборке образа) в model_dir.
    model_dir: str = str(Path.home() / ".cache" / "cutsheet" / "mediapipe")
    model_base_url: str = "https://storage.googleapis.com/mediapipe-models"
    pose_model: str = "pose_landmarker/pose_landmarker_lite/float16/latest/pose_landmarker_lite.task"
    face_model: str = "face_detector/blaze_face_short_range/float16/latest/blaze_face_short_range.tflite"
    object_model: str = "object_detector/efficientdet_lite0/float16/latest/efficientdet_lite0.tflite"
    max_frames: int = 5               # сколько ключевых кадров сцены смотреть
    max_side: int = 960               # кадр уменьшается до этой стороны перед детекцией

    @classmethod
    def from_env(cls) -> "Settings":
        e = os.environ.get
        return cls(
            model_dir=e("ST_MODEL_DIR", cls.model_dir),
            model_base_url=e("ST_MODEL_BASE_URL", cls.model_base_url).rstrip("/"),
            pose_model=e("ST_POSE_MODEL", cls.pose_model),
            face_model=e("ST_FACE_MODEL", cls.face_model),
            object_model=e("ST_OBJECT_MODEL", cls.object_model),
            max_frames=int(e("ST_MAX_FRAMES", str(cls.max_frames))),
            max_side=int(e("ST_MAX_SIDE", str(cls.max_side))),
        )
