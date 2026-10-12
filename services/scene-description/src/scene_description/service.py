"""Обработчик: script.parsed → индекс сценария в S3; scene.ready-for-enrichment → scene.enriched."""

from __future__ import annotations

import json
import logging

from cutsheet_common import Event, new_event
from cutsheet_common.storage import Storage, s3_uri
from llm_client import LLMClient

from .config import Settings
from .context import build_context, dumps, index_key, script_index
from .describe import describe, load_prompt, prepare_frame

SERVICE = "scene-description"
STUB_VERSION = "stub-v1"
log = logging.getLogger(SERVICE)


def pick(items: list[str], n: int) -> list[str]:
    """n элементов, равномерно по списку (ключевые кадры идут по времени сцены)."""
    if len(items) <= n:
        return items
    return [items[round(i * (len(items) - 1) / (n - 1))] for i in range(n)] if n > 1 else [items[len(items) // 2]]


class SceneDescriptionService:
    def __init__(self, storage: Storage, settings: Settings, llm: LLMClient | None = None):
        if settings.mode not in ("llm", "stub"):
            raise ValueError(f"unknown SDS_MODE: {settings.mode}")
        if settings.mode == "llm" and llm is None:
            raise ValueError("SDS_MODE=llm requires an LLM client")
        self.storage = storage
        self.settings = settings
        self.llm = llm
        self.prompt, self.prompt_version = load_prompt(settings)

    def handle(self, event: Event) -> list[Event]:
        if event.event_type == "script.parsed":
            self._save_script(event)
            return []
        if event.event_type != "scene.ready-for-enrichment":
            return []
        s = self.settings
        p = event.payload
        replicas = p.get("replicas") or []
        if s.mode == "stub":
            text, version, model = "Описание не сгенерировано: LLM отключена (SDS_MODE=stub).", STUB_VERSION, "stub"
        else:
            frames = [prepare_frame(self.storage.get_bytes(u), s.frame_max_side)
                      for u in pick(p["keyframe_uris"], s.max_frames)]
            if not frames:
                raise ValueError(f"scene {p['index']} has no keyframes")
            context = build_context(replicas, self._load_script(event.project_id), s.max_context_chars)
            text = describe(self.llm, self.prompt, self.prompt_version, frames, context, replicas)
            version, model = self.prompt_version, self.llm.config.model
        log.info("scene %d described (%d chars, %s)", p["index"], len(text), version,
                 extra={"project_id": event.project_id})
        return [new_event("scene.enriched", {
            "scene_id": p["scene_id"],
            "source": "description",
            "description": text,
            "prompt_version": version,
            "model": model,
            "request_event_id": event.event_id,
        }, source=event, producer=SERVICE)]

    def _save_script(self, event: Event) -> None:
        index = script_index(event.payload)
        self.storage.put_bytes(dumps(index), self.settings.bucket, index_key(event.project_id), "application/json")
        log.info("script index saved: %d scenes", len(index["scenes"]), extra={"project_id": event.project_id})

    def _load_script(self, project_id: str) -> dict | None:
        # Сценарий необязателен: без него описание строится по кадрам и репликам.
        uri = s3_uri(self.settings.bucket, index_key(project_id))
        if not self.storage.exists(uri):
            return None
        return json.loads(self.storage.get_bytes(uri))
