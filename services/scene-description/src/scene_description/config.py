from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    mode: str = "llm"                  # llm | stub (без LLM: CI и офлайн; описание-заглушка)
    prompt: str = "scene-description-v1"   # имя промпта из prompts/ — оно же версия в результате
    prompt_file: str | None = None     # свой промпт из файла; версия — имя файла без расширения
    max_frames: int = 3                # кадров сцены в запросе
    frame_max_side: int = 768          # кадр уменьшается до этой стороны: меньше токенов и памяти GPU
    max_context_chars: int = 1500      # реплики и фрагмент сценария в запросе
    bucket: str = "cutsheet"

    @classmethod
    def from_env(cls) -> "Settings":
        e = os.environ.get
        return cls(
            mode=e("SDS_MODE", cls.mode),
            prompt=e("SDS_PROMPT", cls.prompt),
            prompt_file=e("SDS_PROMPT_FILE") or None,
            max_frames=int(e("SDS_MAX_FRAMES", str(cls.max_frames))),
            frame_max_side=int(e("SDS_FRAME_MAX_SIDE", str(cls.frame_max_side))),
            max_context_chars=int(e("SDS_MAX_CONTEXT_CHARS", str(cls.max_context_chars))),
            bucket=e("S3_BUCKET", cls.bucket),
        )
