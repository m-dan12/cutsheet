"""Описание плана мультимодальной LLM (FR-SDS1–SDS3)."""

from __future__ import annotations

import io
import re
from importlib import resources
from pathlib import Path
from typing import Any

from PIL import Image

from llm_client import LLMClient, image_part

from .config import Settings

SCHEMA: dict[str, Any] = {
    "type": "object",
    "required": ["description"],
    "properties": {"description": {"type": "string", "minLength": 1}},
}

MAX_SENTENCES = 3
MAX_CHARS = 400
QUOTE_WORDS = 5          # столько слов реплики подряд в описании — уже цитата

_SENTENCE_END = re.compile(r"[.!?…]+(?:\s|$)")
_WORD = re.compile(r"[\w-]+", re.U)


def load_prompt(settings: Settings) -> tuple[str, str]:
    """(текст промпта, версия). Версия — имя промпта или файла: она пишется в результат (FR-SDS3)."""
    if settings.prompt_file:
        path = Path(settings.prompt_file)
        return path.read_text(encoding="utf-8").strip(), path.stem
    text = resources.files(__package__).joinpath("prompts", f"{settings.prompt}.txt").read_text(encoding="utf-8")
    return text.strip(), settings.prompt


def prepare_frame(data: bytes, max_side: int) -> bytes:
    img = Image.open(io.BytesIO(data)).convert("RGB")
    img.thumbnail((max_side, max_side))
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=85)
    return buf.getvalue()


def _words(text: str) -> list[str]:
    return [w.lower().replace("ё", "е") for w in _WORD.findall(text)]


def check_description(text: str, replicas: list[dict[str, Any]]) -> None:
    """Требования FR-SDS2; ValueError с текстом для модели, если не выполнены."""
    text = text.strip()
    if len(text) > MAX_CHARS:
        raise ValueError(f"описание длиннее {MAX_CHARS} символов, сократи до 1–3 предложений")
    sentences = len(_SENTENCE_END.findall(text if text[-1:] in ".!?…" else text + "."))
    if sentences > MAX_SENTENCES:
        raise ValueError(f"в описании {sentences} предложений, нужно не больше {MAX_SENTENCES}")
    letters = [c for c in text if c.isalpha()]
    cyrillic = sum(1 for c in letters if "а" <= c.lower() <= "я" or c.lower() == "ё")
    if not letters or cyrillic / len(letters) < 0.7:
        raise ValueError("описание должно быть на русском языке")
    words = _words(text)
    grams = {tuple(words[i:i + QUOTE_WORDS]) for i in range(len(words) - QUOTE_WORDS + 1)}
    for r in replicas:
        rw = _words(r.get("text", ""))
        for i in range(len(rw) - QUOTE_WORDS + 1):
            if tuple(rw[i:i + QUOTE_WORDS]) in grams:
                raise ValueError("описание цитирует реплику; опиши происходящее, не пересказывая диалог")


def describe(llm: LLMClient, prompt: str, prompt_version: str, frames: list[bytes], context: str,
             replicas: list[dict[str, Any]]) -> str:
    content: list[dict[str, Any]] = [{"type": "text", "text": f"{context}\n\nКадры плана ({len(frames)}):"}]
    content += [image_part(f) for f in frames]
    value = llm.complete_json(
        [{"role": "system", "content": prompt}, {"role": "user", "content": content}],
        SCHEMA, prompt_version=prompt_version, name="scene_description",
        check=lambda v: check_description(v["description"], replicas))
    return " ".join(value["description"].split())
