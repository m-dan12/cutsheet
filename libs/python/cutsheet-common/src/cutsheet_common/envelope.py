"""Конверт события (ТЗ 4.1)."""

from __future__ import annotations

import uuid
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from typing import Any

# Пространство имён для детерминированных event_id: повторная обработка того же
# входного события даёт тот же event_id на выходе, и потребитель отбросит дубликат.
_EVENT_NS = uuid.UUID("6f1c3a52-0b7e-4f4d-9a43-8f2a1d7c5e10")


@dataclass
class Event:
    event_type: str
    project_id: str
    correlation_id: str
    payload: dict[str, Any]
    event_id: str = field(default_factory=lambda: str(uuid.uuid4()))
    schema_version: int = 1
    occurred_at: str = field(default_factory=lambda: _now())
    producer: str | None = None

    def to_dict(self) -> dict[str, Any]:
        d = asdict(self)
        if d["producer"] is None:
            del d["producer"]
        return d

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "Event":
        return cls(
            event_type=d["event_type"],
            project_id=d["project_id"],
            correlation_id=d["correlation_id"],
            payload=d["payload"],
            event_id=d["event_id"],
            schema_version=d["schema_version"],
            occurred_at=d["occurred_at"],
            producer=d.get("producer"),
        )


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def derive_event_id(producer: str, source_event_id: str, suffix: str = "") -> str:
    """Детерминированный event_id результата по id входного события."""
    return str(uuid.uuid5(_EVENT_NS, f"{producer}:{source_event_id}:{suffix}"))


def new_event(
    event_type: str,
    payload: dict[str, Any],
    *,
    source: Event | None = None,
    project_id: str | None = None,
    correlation_id: str | None = None,
    producer: str | None = None,
    event_id: str | None = None,
) -> Event:
    """Новое событие; project_id и correlation_id наследуются от source, если он задан."""
    pid = project_id or (source.project_id if source else None)
    if pid is None:
        raise ValueError("project_id is required")
    cid = correlation_id or (source.correlation_id if source else str(uuid.uuid4()))
    if event_id is None:
        event_id = derive_event_id(producer or "", source.event_id, event_type) if source else str(uuid.uuid4())
    return Event(event_type=event_type, project_id=pid, correlation_id=cid, payload=payload,
                 event_id=event_id, producer=producer)
