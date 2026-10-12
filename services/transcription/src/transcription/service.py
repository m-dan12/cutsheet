"""Обработчик video.uploaded + script.parsed → dialogue.aligned.

Сервис ждёт оба входа (FR-TA3), а в БД не ходит: состояние лежит в S3 по
детерминированным ключам проекта.
- video.uploaded: распознаёт речь, кладёт транскрипт в `projects/{id}/transcript/transcript.json`
  (кэш: тот же файл видео и та же модель — повторно не распознаём).
- script.parsed: кладёт разобранный сценарий в `projects/{id}/transcript/script.json`.
После каждого из них, если второй вход уже есть, выполняется сопоставление. Каждый
обработчик сначала пишет своё, потом читает чужое, поэтому из двух событий хотя бы одно
увидит оба входа. event_id результата выводится из id обоих входных событий: повторная
доставка даёт тот же id, и Aggregator отбросит дубликат.
"""

from __future__ import annotations

import json
import logging
import shutil
import tempfile
from pathlib import Path
from typing import Any

from cutsheet_common import Event, derive_event_id, new_event
from cutsheet_common.storage import Storage, parse_s3_uri, s3_uri

from .align import AlignConfig, ScriptLine, align
from .audio import extract_audio, has_audio
from .config import Settings
from .transcribe import Transcriber, Transcript

SERVICE = "transcription"
log = logging.getLogger(SERVICE)


class TranscriptionService:
    def __init__(self, storage: Storage, settings: Settings, transcriber: Transcriber,
                 align_config: AlignConfig | None = None):
        self.storage = storage
        self.settings = settings
        self.transcriber = transcriber
        self.align_config = align_config or AlignConfig()

    def _uri(self, pid: str, name: str) -> str:
        return s3_uri(self.settings.bucket, f"projects/{pid}/transcript/{name}")

    def _put_json(self, uri: str, data: dict[str, Any]) -> None:
        bucket, key = parse_s3_uri(uri)
        self.storage.put_bytes(json.dumps(data, ensure_ascii=False).encode("utf-8"), bucket, key,
                               "application/json")

    def _get_json(self, uri: str) -> dict[str, Any] | None:
        return json.loads(self.storage.get_bytes(uri)) if self.storage.exists(uri) else None

    def handle(self, event: Event) -> list[Event]:
        if event.event_type == "video.uploaded":
            self._on_video(event)
        elif event.event_type == "script.parsed":
            self._put_json(self._uri(event.project_id, "script.json"),
                           {"source_event_id": event.event_id, "payload": event.payload})
        else:
            return []
        return self._try_align(event)

    # ---------- распознавание ----------

    def _on_video(self, event: Event) -> None:
        pid = event.project_id
        video_uri = event.payload["video_uri"]
        language = event.payload.get("language") or self.settings.language
        uri = self._uri(pid, "transcript.json")
        cached = self._get_json(uri)
        if cached and (cached["video_uri"], cached["model"], cached.get("requested_language")) == \
                (video_uri, self.transcriber.name, language):
            log.info("transcript cache hit", extra={"project_id": pid})
            cached["video_event_id"] = event.event_id
            self._put_json(uri, cached)
            return

        s = self.settings
        Path(s.work_dir).mkdir(parents=True, exist_ok=True)
        work = Path(tempfile.mkdtemp(prefix=f"{pid}-", dir=s.work_dir))
        try:
            _, key = parse_s3_uri(video_uri)
            video = self.storage.download(video_uri, work / Path(key).name)
            if has_audio(video):
                transcript = self.transcriber.transcribe(extract_audio(video, work / "audio.wav"), language)
            else:
                log.warning("video has no audio track", extra={"project_id": pid})
                transcript = Transcript(language, self.transcriber.name, [])
        finally:
            shutil.rmtree(work, ignore_errors=True)
        self._put_json(uri, {"video_uri": video_uri, "video_event_id": event.event_id,
                             "requested_language": language, **transcript.to_dict()})

    # ---------- сопоставление ----------

    def _try_align(self, event: Event) -> list[Event]:
        pid = event.project_id
        transcript_uri = self._uri(pid, "transcript.json")
        tr = self._get_json(transcript_uri)
        script = self._get_json(self._uri(pid, "script.json"))
        if tr is None or script is None:
            log.info("waiting for %s", "script.parsed" if tr else "transcript", extra={"project_id": pid})
            return []

        transcript = Transcript.from_dict(tr)
        lines = [ScriptLine(ln["line_id"], ln.get("role"), ln["text"])
                 for sc in script["payload"]["script_scenes"] for ln in sc["lines"] if ln["kind"] == "dialogue"]
        replicas, stats = align(transcript.words, lines, self.align_config)
        log.info("aligned: %s", json.dumps(stats), extra={"project_id": pid})

        payload: dict[str, Any] = {"replicas": replicas, "stats": stats, "model": transcript.model,
                                   "transcript_uri": transcript_uri}
        if transcript.language:
            payload["language"] = transcript.language
        eid = derive_event_id(SERVICE, f"{tr['video_event_id']}+{script['source_event_id']}", "dialogue.aligned")
        return [new_event("dialogue.aligned", payload, source=event, producer=SERVICE, event_id=eid)]
