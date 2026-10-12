"""Обработчик script.uploaded → script.parsed."""

from __future__ import annotations

import logging
import shutil
import tempfile
from pathlib import Path

from cutsheet_common import Event, new_event
from cutsheet_common.storage import Storage, parse_s3_uri
from llm_client import LLMClient

from . import rules
from .config import Settings
from .docx_reader import read_script
from .labels import assemble
from .llm import PROMPT_VERSION, label_with_llm

SERVICE = "script-parser"
RULES_VERSION = "script-rules-v1"
log = logging.getLogger(SERVICE)


class ScriptParserService:
    def __init__(self, storage: Storage, settings: Settings, llm: LLMClient | None = None):
        if settings.mode == "llm" and llm is None:
            raise ValueError("SP_MODE=llm requires an LLM client")
        if settings.mode not in ("llm", "rules"):
            raise ValueError(f"unknown SP_MODE: {settings.mode}")
        self.storage = storage
        self.settings = settings
        self.llm = llm

    def handle(self, event: Event) -> list[Event]:
        if event.event_type != "script.uploaded":
            return []
        s = self.settings
        pid = event.project_id
        uri = event.payload["script_uri"]
        Path(s.work_dir).mkdir(parents=True, exist_ok=True)
        work = Path(tempfile.mkdtemp(prefix=f"{pid}-", dir=s.work_dir))
        try:
            _, key = parse_s3_uri(uri)
            path = self.storage.download(uri, work / Path(key).name)
            paragraphs = read_script(path)
        finally:
            shutil.rmtree(work, ignore_errors=True)
        if not paragraphs:
            raise ValueError("script is empty")

        if s.mode == "llm":
            labels = label_with_llm(self.llm, paragraphs, max_chars=s.chunk_chars)
            version, model = PROMPT_VERSION, self.llm.config.model
        else:
            labels = rules.classify(paragraphs)
            version, model = RULES_VERSION, None
        scenes, roles = assemble(paragraphs, labels)
        dialogue = sum(1 for sc in scenes for ln in sc["lines"] if ln["kind"] == "dialogue")
        log.info("parsed %d paragraphs: %d scenes, %d roles, %d dialogue lines", len(paragraphs), len(scenes),
                 len(roles.names), dialogue, extra={"project_id": pid})

        payload = {
            "script_scenes": scenes,
            "roles": roles.names,
            "role_aliases": roles.aliases,
            "prompt_version": version,
            "parser": {"mode": s.mode, **({"model": model} if model else {})},
        }
        return [new_event("script.parsed", payload, source=event, producer=SERVICE)]
