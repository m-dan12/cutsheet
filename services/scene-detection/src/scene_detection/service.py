"""Обработчик video.uploaded → scenes.detected."""

from __future__ import annotations

import logging
import shutil
import tempfile
from pathlib import Path

from cutsheet_common import Event, new_event
from cutsheet_common.storage import Storage, parse_s3_uri

from .config import Settings
from .detect import detect_cuts, extract_frames, keyframe_times, normalize_scenes

SERVICE = "scene-detection"
log = logging.getLogger(SERVICE)


class SceneDetectionService:
    def __init__(self, storage: Storage, settings: Settings):
        self.storage = storage
        self.settings = settings

    def handle(self, event: Event) -> list[Event]:
        if event.event_type != "video.uploaded":
            return []
        s = self.settings
        pid = event.project_id
        video_uri = event.payload["video_uri"]
        Path(s.work_dir).mkdir(parents=True, exist_ok=True)
        work = Path(tempfile.mkdtemp(prefix=f"{pid}-", dir=s.work_dir))
        try:
            # Этап 0: качаем файл целиком. Для фильмов на десятки ГБ позже можно
            # читать по presigned URL напрямую (OpenCV/ffmpeg умеют http).
            _, key = parse_s3_uri(video_uri)
            video = self.storage.download(video_uri, work / Path(key).name)
            det = detect_cuts(video, s.detector, s.threshold, s.min_scene_ms)
            spans = normalize_scenes(det.cuts_ms, det.duration_ms, s.min_scene_ms)
            log.info("detected %d scenes", len(spans), extra={"project_id": pid})

            scenes = []
            for idx, (start, end) in enumerate(spans):
                prefix = f"scene_{idx:05d}"
                frames = extract_frames(video, keyframe_times(start, end, s.keyframes), work / "frames",
                                        prefix, s.jpeg_quality)
                # Детерминированные ключи: повторная обработка перезаписывает те же объекты.
                uris = [self.storage.upload_file(f, s.bucket, f"projects/{pid}/frames/{f.name}", "image/jpeg")
                        for f in frames]
                scenes.append({"index": idx, "start_ms": start, "end_ms": end, "keyframe_uris": uris})

            return [new_event("scenes.detected", {
                "fps": det.fps,
                "duration_ms": det.duration_ms,
                "scenes": scenes,
                "detector": {"name": s.detector, "threshold": s.threshold, "min_scene_ms": s.min_scene_ms},
            }, source=event, producer=SERVICE)]
        finally:
            shutil.rmtree(work, ignore_errors=True)
