"""Снимок листа → таблица строк, общая для всех форматов (FR-E2, FR-E3, FR-E5)."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Any

from .timecode import timecode


@dataclass(frozen=True)
class Column:
    key: str
    title: str
    width: float


@dataclass(frozen=True)
class Sheet:
    title: str
    project: str
    header: list[str]           # строки шапки: проект, дата, количество сцен, длительность
    footer: str                 # {page} — номер страницы, подставляет формат
    columns: list[Column]
    rows: list[list[str]]       # ячейки в порядке columns; переносы строк — "\n"
    template: dict[str, Any]


def dialogue(replicas: list[dict[str, Any]], unknown_role: str | None) -> str:
    """Реплики в ячейке: «РОЛЬ: текст», каждая с новой строки (FR-E2)."""
    lines = []
    for r in replicas:
        role = r.get("role") or unknown_role
        text = (r.get("text") or "").strip()
        lines.append(f"{role}: {text}" if role else text)
    return "\n".join(lines)


def build_sheet(snapshot: dict[str, Any], template: dict[str, Any], options: dict[str, Any] | None = None) -> Sheet:
    options = options or {}
    mode = options.get("timecode") or template["timecode"]
    fps = snapshot.get("fps")
    labels = template["shot_labels"]
    project = snapshot["project"]["name"]
    scenes = snapshot["scenes"]

    duration_ms = snapshot.get("duration_ms")
    if duration_ms is None:
        duration_ms = max((s["end_ms"] for s in scenes), default=0)
    generated = datetime.fromisoformat(snapshot["generated_at"].replace("Z", "+00:00"))
    values = {
        "project": project,
        "date": generated.strftime(template["date_format"]),
        "scenes": len(scenes),
        "duration": timecode(duration_ms, fps, mode),
    }

    def cell(key: str, s: dict[str, Any]) -> str:
        match key:
            case "number":
                return str(s["number"])
            case "start":
                return timecode(s["start_ms"], fps, mode)
            case "end":
                return timecode(s["end_ms"], fps, mode)
            case "duration":
                return timecode(s["end_ms"] - s["start_ms"], fps, mode)
            case "shot":
                return labels.get(s["shot_type"] or "unknown", s["shot_type"] or "")
            case "description":
                return (s.get("description") or "").strip()
            case "dialogue":
                return dialogue(s.get("replicas") or [], template.get("unknown_role"))
        raise KeyError(key)

    columns = [Column(c["key"], c["title"], float(c["width"])) for c in template["columns"]]
    # options.columns: какие колонки шаблона оставить (выбор в клиенте); пустой выбор игнорируется.
    wanted = options.get("columns")
    if isinstance(wanted, list) and (picked := [c for c in columns if c.key in wanted]):
        columns = picked
    rows = [[cell(c.key, s) for c in columns] for s in scenes]
    return Sheet(
        title=template["title"],
        project=project,
        header=[line.format(**values) for line in template["header"]],
        footer=template["footer"].replace("{project}", project),
        columns=columns,
        rows=rows,
        template=template,
    )
