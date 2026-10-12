"""Структурные логи в JSON с project_id / correlation_id (ТЗ 7, наблюдаемость)."""

from __future__ import annotations

import json
import logging
import os
import sys

_CTX_FIELDS = ("project_id", "correlation_id", "event_id")


class JsonFormatter(logging.Formatter):
    def __init__(self, service: str):
        super().__init__()
        self.service = service

    def format(self, record: logging.LogRecord) -> str:
        out = {
            "ts": self.formatTime(record, "%Y-%m-%dT%H:%M:%S"),
            "level": record.levelname.lower(),
            "service": self.service,
            "logger": record.name,
            "msg": record.getMessage(),
        }
        for f in _CTX_FIELDS:
            if hasattr(record, f):
                out[f] = getattr(record, f)
        if record.exc_info:
            out["exc"] = self.formatException(record.exc_info)
        return json.dumps(out, ensure_ascii=False)


def setup_logging(service: str) -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter(service))
    logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO").upper(), handlers=[handler], force=True)
