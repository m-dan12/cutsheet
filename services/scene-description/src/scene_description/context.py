"""Контекст для описания (FR-SDS1): реплики сцены и фрагмент сценария по script_line_id.

Сценарий приходит раньше сцен (script.parsed), поэтому сервис сохраняет из него компактный
индекс в S3: заголовок и ремарки каждой сцены сценария и сцену для каждого line_id.
"""

from __future__ import annotations

import json
from typing import Any

MAX_ACTION_LINES = 6


def script_index(payload: dict[str, Any]) -> dict[str, Any]:
    """Индекс из script.parsed: заголовок и ремарки сцен, line_id → номер сцены."""
    scenes, line_scene = [], {}
    for i, sc in enumerate(payload["script_scenes"]):
        scenes.append({"heading": sc["heading"],
                       "action": [ln["text"] for ln in sc["lines"] if ln["kind"] == "action"][:MAX_ACTION_LINES]})
        for ln in sc["lines"]:
            line_scene[ln["line_id"]] = i
    return {"scenes": scenes, "line_scene": line_scene}


def index_key(project_id: str) -> str:
    return f"projects/{project_id}/scene-description/script.json"


def dumps(index: dict[str, Any]) -> bytes:
    return json.dumps(index, ensure_ascii=False).encode("utf-8")


def build_context(replicas: list[dict[str, Any]], index: dict[str, Any] | None, max_chars: int) -> str:
    parts = []
    if replicas:
        lines = [f"{r.get('role') or 'неизвестный'}: {r['text']}" for r in replicas]
        parts.append("Реплики в этом плане:\n" + "\n".join(lines))
    else:
        parts.append("Реплик в этом плане нет.")
    if index:
        seen: list[int] = []
        for r in replicas:
            i = index["line_scene"].get(r.get("script_line_id") or "")
            if i is not None and i not in seen:
                seen.append(i)
        for i in seen[:2]:
            sc = index["scenes"][i]
            parts.append("Фрагмент сценария:\n" + "\n".join([sc["heading"], *sc["action"]]).strip())
    text = "\n\n".join(parts)
    return text if len(text) <= max_chars else text[:max_chars].rstrip() + "…"
