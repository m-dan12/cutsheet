"""Сравнение описаний сцен двумя моделями на эталонных кадрах (FR-SDS3).

Модель A настраивается переменными LLM_* (по умолчанию локальная Ollama), модель B — CMP_LLM_*
(например, внешний API). Каждая подпапка FRAMES_DIR — один план: его кадры *.jpg / *.png по
порядку и необязательный context.txt (реплики «РОЛЬ: текст» по строке). Отдельные картинки в
корне FRAMES_DIR — план из одного кадра. Итог — таблица Markdown для ручной оценки.

    LLM_MODEL=qwen2.5vl:7b \
    CMP_LLM_BASE_URL=https://api.example.com/v1 CMP_LLM_MODEL=... CMP_LLM_API_KEY=... \
    python tools/compare_descriptions.py frames/ --out compare.md
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

from llm_client import LLMClient, LLMConfig, LLMError
from scene_description.config import Settings
from scene_description.describe import describe, load_prompt, prepare_frame

IMAGES = {".jpg", ".jpeg", ".png", ".webp"}


def shots(root: Path) -> list[tuple[str, list[Path], list[dict]]]:
    out = []
    for p in sorted(root.iterdir()):
        if p.is_dir():
            frames = sorted(f for f in p.iterdir() if f.suffix.lower() in IMAGES)
            ctx = p / "context.txt"
            replicas = []
            if ctx.is_file():
                for line in ctx.read_text(encoding="utf-8").splitlines():
                    role, sep, text = line.partition(":")
                    if line.strip():
                        replicas.append({"role": role.strip() if sep else None, "text": (text if sep else line).strip()})
            if frames:
                out.append((p.name, frames, replicas))
        elif p.suffix.lower() in IMAGES:
            out.append((p.stem, [p], []))
    return out


def run(client: LLMClient, prompt: str, version: str, settings: Settings, frames: list[Path],
        replicas: list[dict]) -> tuple[str, float]:
    from scene_description.context import build_context

    data = [prepare_frame(f.read_bytes(), settings.frame_max_side) for f in frames[:settings.max_frames]]
    started = time.monotonic()
    try:
        text = describe(client, prompt, version, data, build_context(replicas, None, settings.max_context_chars),
                        replicas)
    except LLMError as e:
        text = f"**ошибка:** {e}"
    return text, time.monotonic() - started


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("frames", type=Path)
    ap.add_argument("--out", type=Path, default=Path("compare_descriptions.md"))
    args = ap.parse_args()

    settings = Settings.from_env()
    prompt, version = load_prompt(settings)
    a, b = LLMConfig.from_env("LLM_"), LLMConfig.from_env("CMP_LLM_")
    clients = [LLMClient(a), LLMClient(b)]
    rows = [f"Промпт `{version}`. A — `{a.model}` ({a.base_url}), B — `{b.model}` ({b.base_url}).", "",
            "| План | A | B |", "|---|---|---|"]
    for name, frames, replicas in shots(args.frames):
        cells = []
        for c in clients:
            text, seconds = run(c, prompt, version, settings, frames, replicas)
            cells.append(f"{text} _({seconds:.1f} с)_".replace("|", "\\|"))
        rows.append(f"| {name} | {cells[0]} | {cells[1]} |")
        print(f"{name}: done", file=sys.stderr)
    args.out.write_text("\n".join(rows) + "\n", encoding="utf-8")
    print(args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
