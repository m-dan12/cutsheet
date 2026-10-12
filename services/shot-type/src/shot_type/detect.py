"""Детекторы MediaPipe: поза, лица, люди. Модели скачиваются при первом использовании."""

from __future__ import annotations

import io
import logging
import os
import tempfile
import threading
import urllib.request
from pathlib import Path
from typing import Protocol

import numpy as np
from PIL import Image

from .classify import Box, FrameObservation, Landmark, Pose, Texture
from .config import Settings

log = logging.getLogger("shot-type.detect")


class Detector(Protocol):
    name: str

    def observe(self, rgb: np.ndarray) -> FrameObservation: ...


def load_rgb(data: bytes, max_side: int) -> np.ndarray:
    img = Image.open(io.BytesIO(data)).convert("RGB")
    img.thumbnail((max_side, max_side))
    return np.asarray(img, dtype=np.uint8)


def texture(rgb: np.ndarray) -> Texture:
    """Средний модуль лапласиана в центральной половине кадра и в рамке по краям."""
    g = rgb.astype(np.float32) @ np.array([0.299, 0.587, 0.114], np.float32)
    if min(g.shape) < 8:
        return Texture(0.0, 0.0)
    lap = np.abs(4 * g[1:-1, 1:-1] - g[:-2, 1:-1] - g[2:, 1:-1] - g[1:-1, :-2] - g[1:-1, 2:])
    h, w = lap.shape
    mask = np.zeros_like(lap, dtype=bool)
    mask[h // 4: h - h // 4, w // 4: w - w // 4] = True
    return Texture(float(lap[mask].mean()), float(lap[~mask].mean()))


def ensure_model(settings: Settings, rel: str) -> Path:
    """Путь к модели; если её нет в model_dir — скачивает (атомарно, через временный файл)."""
    dest = Path(settings.model_dir) / Path(rel).name
    if dest.is_file():
        return dest
    dest.parent.mkdir(parents=True, exist_ok=True)
    url = f"{settings.model_base_url}/{rel}"
    log.info("downloading model %s", url)
    fd, tmp = tempfile.mkstemp(dir=dest.parent, prefix=".part-")
    try:
        with os.fdopen(fd, "wb") as f, urllib.request.urlopen(url, timeout=120) as resp:
            while chunk := resp.read(1 << 20):
                f.write(chunk)
        os.replace(tmp, dest)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    return dest


class MediaPipeDetector:
    """Поза (PoseLandmarker), лица (FaceDetector), люди и предметы (ObjectDetector, классы COCO)."""

    def __init__(self, settings: Settings):
        self.settings = settings
        self.name = "mediapipe:" + "+".join(Path(m).stem for m in
                                            (settings.pose_model, settings.face_model, settings.object_model))
        self._lock = threading.Lock()
        self._tasks = None

    def _init(self):
        with self._lock:
            if self._tasks is None:
                # Импорт здесь: тесты логики и сервиса не требуют mediapipe и моделей.
                from mediapipe.tasks.python import BaseOptions, vision

                s = self.settings
                opts = lambda rel: BaseOptions(model_asset_path=str(ensure_model(s, rel)))  # noqa: E731
                self._tasks = (
                    vision.PoseLandmarker.create_from_options(vision.PoseLandmarkerOptions(
                        base_options=opts(s.pose_model), num_poses=3, min_pose_detection_confidence=0.5)),
                    vision.FaceDetector.create_from_options(vision.FaceDetectorOptions(
                        base_options=opts(s.face_model), min_detection_confidence=0.5)),
                    vision.ObjectDetector.create_from_options(vision.ObjectDetectorOptions(
                        base_options=opts(s.object_model), score_threshold=0.4)),
                )
        return self._tasks

    def observe(self, rgb: np.ndarray) -> FrameObservation:
        import mediapipe as mp

        pose_task, face_task, object_task = self._init()
        h, w = rgb.shape[:2]
        image = mp.Image(image_format=mp.ImageFormat.SRGB, data=np.ascontiguousarray(rgb))

        poses = [Pose(tuple(Landmark(p.x, p.y, p.visibility if p.visibility is not None else 1.0) for p in lm))
                 for lm in pose_task.detect(image).pose_landmarks]
        faces = [_box(d.bounding_box, w, h, d.categories[0].score if d.categories else 1.0)
                 for d in face_task.detect(image).detections]
        persons, objects = [], []
        for d in object_task.detect(image).detections:
            cat = d.categories[0] if d.categories else None
            box = _box(d.bounding_box, w, h, cat.score if cat else 1.0)
            (persons if cat and cat.category_name == "person" else objects).append(box)
        return FrameObservation(poses=poses, faces=faces, persons=persons, objects=objects, texture=texture(rgb))

    def close(self) -> None:
        with self._lock:
            for t in self._tasks or ():
                t.close()
            self._tasks = None


def _box(bb, w: int, h: int, score: float) -> Box:
    return Box(bb.origin_x / w, bb.origin_y / h, (bb.origin_x + bb.width) / w, (bb.origin_y + bb.height) / h, score)
