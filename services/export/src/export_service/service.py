"""Обработчик export.requested → export.completed / export.failed (ТЗ 5.9)."""

from __future__ import annotations

import json
import logging

from cutsheet_common import Contracts, Event, new_event
from cutsheet_common.storage import Storage

from .config import Settings
from .render_docx import render_docx
from .render_pdf import render_pdf
from .render_xlsx import render_xlsx
from .sheet import build_sheet
from .template import Templates

SERVICE = "export"
log = logging.getLogger(SERVICE)

CONTENT_TYPES = {
    "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "pdf": "application/pdf",
}


def result_key(project_id: str, export_id: str, fmt: str) -> str:
    """Детерминированный ключ: повтор события перезаписывает тот же объект (идемпотентность)."""
    return f"projects/{project_id}/exports/{export_id}/sheet.{fmt}"


class ExportService:
    def __init__(self, storage: Storage, settings: Settings, contracts: Contracts | None = None):
        self.storage = storage
        self.settings = settings
        self.contracts = contracts or Contracts()
        self.templates = Templates(settings.templates_dir)

    def render(self, fmt: str, snapshot: dict, options: dict) -> bytes:
        self.contracts.validate_document("sheet-snapshot", 1, snapshot)
        sheet = build_sheet(snapshot, self.templates.get(options.get("template") or "default"), options)
        if fmt == "xlsx":
            return render_xlsx(sheet)
        if fmt == "docx":
            return render_docx(sheet)
        if fmt == "pdf":
            return render_pdf(sheet, self.settings.font_dirs)
        raise ValueError(f"unknown format: {fmt}")

    def handle(self, event: Event) -> list[Event]:
        if event.event_type != "export.requested":
            return []
        p = event.payload
        export_id, fmt = p["export_id"], p["format"]
        ctx = {"project_id": event.project_id, "correlation_id": event.correlation_id}
        try:
            if not self.storage.exists(p["snapshot_uri"]):
                raise FileNotFoundError("снимок листа не найден в хранилище")
            snapshot = json.loads(self.storage.get_bytes(p["snapshot_uri"]))
            if snapshot.get("export_id") != export_id:
                raise ValueError("снимок относится к другому экспорту")
            data = self.render(fmt, snapshot, p.get("options") or {})
            uri = self.storage.put_bytes(data, self.settings.bucket, result_key(event.project_id, export_id, fmt),
                                         CONTENT_TYPES[fmt])
        except Exception as e:  # noqa: BLE001 — любой сбой экспорта отдаём клиенту как export.failed
            log.exception("export %s (%s) failed", export_id, fmt, extra=ctx)
            return [new_event("export.failed", {"export_id": export_id, "error": f"{type(e).__name__}: {e}"[:2000]},
                              source=event, producer=SERVICE)]
        log.info("export %s (%s): %d bytes, %d scenes", export_id, fmt, len(data), len(snapshot["scenes"]),
                 extra=ctx)
        return [new_event("export.completed", {"export_id": export_id, "result_uri": uri},
                          source=event, producer=SERVICE)]
