from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    backend: str = "faster-whisper"     # faster-whisper | whisperx
    model: str = "small"                # на GPU — large-v3 (ТЗ 9, п. 8)
    device: str = "auto"                # auto | cpu | cuda
    compute_type: str = "default"       # int8 для CPU, float16 для GPU
    language: str | None = "ru"         # язык по умолчанию; пусто — определять автоматически (FR-TA2)
    bucket: str = "cutsheet"
    work_dir: str = "/tmp/transcription"

    @classmethod
    def from_env(cls) -> "Settings":
        e = os.environ.get
        return cls(
            backend=e("TA_BACKEND", "faster-whisper"),
            model=e("TA_MODEL", "small"),
            device=e("TA_DEVICE", "auto"),
            compute_type=e("TA_COMPUTE_TYPE", "default"),
            language=e("TA_LANGUAGE", "ru") or None,
            bucket=e("S3_BUCKET", "cutsheet"),
            work_dir=e("TA_WORK_DIR", "/tmp/transcription"),
        )
