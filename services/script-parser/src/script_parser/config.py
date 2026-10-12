from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    mode: str = "llm"            # llm | rules (эвристики без LLM: офлайн, CI, база для сравнения)
    chunk_chars: int = 6000      # размер чанка для LLM (FR-SP3), под контекст локальной модели
    work_dir: str = "/tmp/script-parser"

    @classmethod
    def from_env(cls) -> "Settings":
        e = os.environ.get
        return cls(
            mode=e("SP_MODE", "llm"),
            chunk_chars=int(e("SP_CHUNK_CHARS", "6000")),
            work_dir=e("SP_WORK_DIR", "/tmp/script-parser"),
        )
