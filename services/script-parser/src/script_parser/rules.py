"""Разметка эвристиками без LLM.

Работает на типовой записи русских и англоязычных сценариев: заголовок сцены
(«1. ИНТ. КВАРТИРА — ДЕНЬ»), имя персонажа прописными, реплика под ним или в одной
строке («ИВАН: ...»). Используется без доступа к LLM (CI, офлайн) и как база для
сравнения качества с LLM.
"""

from __future__ import annotations

import re

from .docx_reader import Paragraph
from .labels import Label, split_inline

_HEADING = re.compile(
    r"^(?:(?:СЦЕНА|SCENE)\s*\d+|\d+[.)]?\s*(?:ИНТ|НАТ|INT|EXT|ЭКСТ)|(?:ИНТ|НАТ|INT|EXT|ЭКСТ|И/Н|I/E)\b[./ ])",
    re.I)
_TRANSITION = re.compile(r"^(?:ЗТМ|ЗАТЕМНЕНИЕ|СМЕНА КАДРА|ВЫХОД ИЗ ЗТМ|ТИТР|CUT TO|FADE (?:IN|OUT)|ТИТРЫ)\b", re.I)
_LETTERS = re.compile(r"[A-Za-zА-Яа-яЁё]")


def _is_upper_name(text: str) -> bool:
    core = re.sub(r"\([^)]*\)", "", text).strip(" .:")
    letters = _LETTERS.findall(core)
    return (2 <= len(letters) and len(core) <= 40 and len(core.split()) <= 4
            and all(c.isupper() for c in letters))


_COLON = re.compile(r"^[^:.!?]{1,60}?\s*(?:\([^)]*\))?\s*:\s")


def _is_inline_name(name: str, text: str) -> bool:
    """Имя в записи «ИМЯ: реплика»: прописными, либо «Иван:» / «Иван Петрович:» перед двоеточием."""
    if _is_upper_name(name):
        return True
    words = name.split()
    return (bool(_COLON.match(text)) and 1 <= len(words) <= 3
            and all(w[0].isupper() and w.isalpha() for w in words))


def _style(p: Paragraph, *names: str) -> bool:
    s = p.style.lower()
    return any(n in s for n in names)


def classify(paragraphs: list[Paragraph]) -> list[Label]:
    labels: list[Label] = []
    in_dialogue = False
    dialogue_indent = 0.0
    for p in paragraphs:
        text = p.text
        if _style(p, "scene", "heading", "сцена", "заголов") or _HEADING.match(text):
            lab = Label("heading")
        elif _TRANSITION.match(text):
            lab = Label("transition")
        elif in_dialogue and text.startswith("(") and text.endswith(")"):
            lab = Label("parenthetical")
        elif _style(p, "character", "персонаж") or (_is_upper_name(text) and not text.endswith("!")):
            lab = Label("character", text)
        elif (parts := split_inline(text)) and _is_inline_name(parts[0], text):
            lab = Label("character_dialogue", parts[0])
        elif in_dialogue and not p.blank_before and p.indent_cm >= dialogue_indent:
            lab = Label("dialogue")
        else:
            lab = Label("action")
        if lab.type == "character":
            in_dialogue, dialogue_indent = True, 0.0
        elif lab.type == "dialogue" and labels and labels[-1].type in ("character", "parenthetical"):
            # Отступ первой строки реплики: абзац левее него — уже описание действия.
            dialogue_indent = p.indent_cm
        elif lab.type not in ("dialogue", "parenthetical"):
            in_dialogue = False
        labels.append(lab)
    return labels
