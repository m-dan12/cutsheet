"""Разметка абзацев сценария и сборка script.parsed из неё.

Разметку делает LLM (llm.py) или эвристики (rules.py); сборка общая и детерминированная:
текст реплик берётся из документа дословно, LLM его не переписывает.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any

from .docx_reader import Paragraph
from .roles import RoleBook

TYPES = ("heading", "character", "dialogue", "character_dialogue", "parenthetical", "action", "transition")


@dataclass(frozen=True)
class Label:
    type: str
    role: str | None = None


def line_id(p: Paragraph) -> str:
    """Стабильный id реплики (FR-SP5): номер абзаца, где она начинается."""
    return f"p{p.i:05d}"


_INLINE = re.compile(r"^(?P<name>[^:.!?]{1,60}?)\s*(?:\([^)]*\))?\s*[:.]\s+(?P<text>\S.*)$")


def split_inline(text: str) -> tuple[str, str] | None:
    """«ИВАН: Привет» / «ИВАН (за кадром). Привет» → (имя, реплика)."""
    m = _INLINE.match(text)
    return (m.group("name"), m.group("text")) if m else None


def assemble(paragraphs: list[Paragraph], labels: list[Label],
             roles: RoleBook | None = None) -> tuple[list[dict[str, Any]], RoleBook]:
    """Сцены сценария с репликами и ремарками в формате payload script.parsed."""
    roles = roles or RoleBook()
    scenes: list[dict[str, Any]] = []
    role: str | None = None             # текущий говорящий
    open_line: dict[str, Any] | None = None  # реплика, к которой дописываются абзацы

    def scene() -> dict[str, Any]:
        if not scenes:  # текст до первого заголовка — сцена без заголовка
            scenes.append({"index": 0, "heading": "", "lines": []})
        return scenes[-1]

    def add(kind: str, p: Paragraph, text: str, who: str | None) -> dict[str, Any]:
        line = {"line_id": line_id(p), "kind": kind, "role": who, "text": text}
        scene()["lines"].append(line)
        return line

    for p, lab in zip(paragraphs, labels, strict=True):
        t = lab.type
        if t == "heading":
            scenes.append({"index": len(scenes), "heading": p.text, "lines": []})
            role, open_line = None, None
        elif t == "character":
            role, open_line = roles.add(lab.role or p.text), None
        elif t == "character_dialogue":
            parts = split_inline(p.text)
            name = lab.role or (parts[0] if parts else None)
            text = parts[1] if parts else p.text
            role = roles.add(name) if name else None
            open_line = add("dialogue", p, text, role) if role else add("action", p, p.text, None)
        elif t == "parenthetical":
            continue  # ремарка в скобках внутри реплики: говорящий не меняется
        elif t == "dialogue" and (lab.role or role):
            who = roles.add(lab.role) if lab.role else role
            if open_line is not None and open_line["role"] == who:
                open_line["text"] += " " + p.text
            else:
                open_line = add("dialogue", p, p.text, who)
            role = who
        elif t == "transition":
            role, open_line = None, None  # ЗТМ, СМЕНА КАДРА — в лист не идут
        else:  # action, а также dialogue без известного говорящего
            add("action", p, p.text, None)
            role, open_line = None, None
    return scenes, roles
