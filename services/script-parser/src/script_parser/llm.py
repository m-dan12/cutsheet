"""Разметка абзацев сценария через LLM (FR-SP2–SP4).

Модель не пересказывает текст, а только размечает пронумерованные абзацы: тип и роль.
Так ответ короткий, текст реплик остаётся дословным, а проверка полноты простая —
каждый номер абзаца чанка должен встретиться ровно один раз. Большой сценарий идёт
чанками; список известных ролей и состояние на конце чанка передаются в следующий (FR-SP3).
"""

from __future__ import annotations

from typing import Any

from llm_client import LLMClient

from .docx_reader import Paragraph
from .labels import TYPES, Label
from .roles import normalize_role

PROMPT_VERSION = "script-labels-v1"

SYSTEM = """Ты размечаешь киносценарий для монтажного листа. На входе пронумерованные абзацы \
сценария, перед текстом в фигурных скобках оформление (стиль, отступ в см, выравнивание).
Для КАЖДОГО абзаца верни тип:
- heading — заголовок сцены (например «1. ИНТ. КВАРТИРА — ДЕНЬ», «СЦЕНА 3», «НАТ. ДВОР. НОЧЬ»);
- character — строка с именем говорящего персонажа перед репликой;
- dialogue — текст реплики (может занимать несколько абзацев подряд);
- character_dialogue — имя и реплика в одном абзаце («ИВАН: Привет», «МАША (за кадром). Иди сюда»);
- parenthetical — пояснение в скобках внутри реплики («(шёпотом)»);
- action — описание действия, ремарка автора;
- transition — переход («ЗТМ», «СМЕНА КАДРА», «ТИТР»).
Для character, character_dialogue и dialogue укажи role — имя персонажа в каноническом виде \
(прописными, без пометок вроде «за кадром», «ПРОД.»). Если персонаж уже есть в списке известных \
ролей, используй имя из списка. Для остальных типов role = null.
Не пропускай и не объединяй абзацы. Верни только JSON."""

SCHEMA: dict[str, Any] = {
    "type": "object",
    "required": ["labels"],
    "properties": {
        "labels": {
            "type": "array",
            "items": {
                "type": "object",
                "required": ["p", "type"],
                "properties": {
                    "p": {"type": "integer"},
                    "type": {"enum": list(TYPES)},
                    "role": {"type": ["string", "null"]},
                },
            },
        },
    },
}

_MAX_PARAGRAPH_CHARS = 300  # для разметки достаточно начала абзаца; экономит контекст модели


def _format(p: Paragraph) -> str:
    fmt = []
    if p.style and p.style not in ("Normal", "Обычный"):
        fmt.append(f"стиль {p.style}")
    if p.indent_cm:
        fmt.append(f"отступ {p.indent_cm:g}")
    if p.align and p.align != "left":
        fmt.append(p.align)
    text = p.text if len(p.text) <= _MAX_PARAGRAPH_CHARS else p.text[:_MAX_PARAGRAPH_CHARS] + "…"
    gap = "\n" if p.blank_before else ""
    return f"{gap}[{p.i}] {{{', '.join(fmt)}}} {text}" if fmt else f"{gap}[{p.i}] {text}"


def chunks(paragraphs: list[Paragraph], max_chars: int) -> list[list[Paragraph]]:
    out: list[list[Paragraph]] = []
    cur: list[Paragraph] = []
    size = 0
    for p in paragraphs:
        n = len(_format(p)) + 1
        # Стараемся резать перед заголовком сцены, чтобы не разрывать сцену без нужды.
        if cur and (size + n > max_chars or (size > max_chars * 0.6 and _looks_like_heading(p))):
            out.append(cur)
            cur, size = [], 0
        cur.append(p)
        size += n
    if cur:
        out.append(cur)
    return out


def _looks_like_heading(p: Paragraph) -> bool:
    from .rules import _HEADING
    return bool(_HEADING.match(p.text))


def label_with_llm(client: LLMClient, paragraphs: list[Paragraph], *, max_chars: int = 6000) -> list[Label]:
    labels: dict[int, Label] = {}
    known: list[str] = []
    state = "начало сценария"
    for chunk in chunks(paragraphs, max_chars):
        expected = [p.i for p in chunk]

        def check(value: dict[str, Any], expected: list[int] = expected) -> None:
            got = [item["p"] for item in value["labels"]]
            missing = sorted(set(expected) - set(got))
            extra = sorted(set(got) - set(expected))
            dup = len(got) != len(set(got))
            if missing or extra or dup:
                raise ValueError(f"нужна ровно одна метка на каждый абзац {expected[0]}–{expected[-1]}; "
                                 f"пропущены: {missing[:20]}, лишние: {extra[:20]}, повторы: {dup}")
            for item in value["labels"]:
                if item["type"] in ("character", "character_dialogue") and not item.get("role"):
                    raise ValueError(f"абзац {item['p']}: для типа {item['type']} нужна role")

        user = (f"Известные роли: {', '.join(known) if known else 'пока нет'}\n"
                f"Перед этим фрагментом: {state}\n\nАбзацы:\n" + "\n".join(_format(p) for p in chunk))
        value = client.complete_json([{"role": "system", "content": SYSTEM}, {"role": "user", "content": user}],
                                     SCHEMA, prompt_version=PROMPT_VERSION, name="script_labels", check=check)
        for item in value["labels"]:
            role = item.get("role") or None
            labels[item["p"]] = Label(item["type"], role)
            if role and (canon := normalize_role(role)) and canon not in known:
                known.append(canon)
        last = labels[expected[-1]]
        state = (f"последний абзац — {last.type}" + (f", говорит {last.role}" if last.role else ""))
    return [labels[p.i] for p in paragraphs]
