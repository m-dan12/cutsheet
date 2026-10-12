"""Обработчик scene.ready-for-enrichment → scene.enriched (source = shot_type)."""

from __future__ import annotations

import logging

from cutsheet_common import Event, new_event
from cutsheet_common.storage import Storage

from .classify import ALGORITHM_VERSION, aggregate, classify_frame
from .config import Settings
from .detect import Detector, load_rgb

SERVICE = "shot-type"
log = logging.getLogger(SERVICE)


def pick(items: list[str], n: int) -> list[str]:
    """n элементов, равномерно по списку (ключевые кадры идут по времени сцены)."""
    if len(items) <= n:
        return items
    return [items[round(i * (len(items) - 1) / (n - 1))] for i in range(n)] if n > 1 else [items[len(items) // 2]]


class ShotTypeService:
    def __init__(self, storage: Storage, settings: Settings, detector: Detector):
        self.storage = storage
        self.settings = settings
        self.detector = detector

    def handle(self, event: Event) -> list[Event]:
        if event.event_type != "scene.ready-for-enrichment":
            return []
        p = event.payload
        verdicts = []
        for uri in pick(p["keyframe_uris"], self.settings.max_frames):
            rgb = load_rgb(self.storage.get_bytes(uri), self.settings.max_side)
            verdicts.append(classify_frame(self.detector.observe(rgb)))
        result = aggregate(verdicts)
        log.info("scene %d: %s (%.2f, by %s) from %d frames", p["index"], result.shot_type, result.confidence,
                 result.basis, len(verdicts), extra={"project_id": event.project_id})
        return [new_event("scene.enriched", {
            "scene_id": p["scene_id"],
            "source": "shot_type",
            "shot_type": result.shot_type,
            "confidence": result.confidence,
            "prompt_version": ALGORITHM_VERSION,
            "model": self.detector.name,
            "request_event_id": event.event_id,
        }, source=event, producer=SERVICE)]
