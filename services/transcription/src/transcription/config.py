from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    backend: str = "faster-whisper"     # faster-whisper | whisperx | gigaam
    model: str = "small"                # модель Whisper; на GPU — large-v3 (ТЗ 9, п. 8)
    device: str = "auto"                # auto | cpu | cuda
    compute_type: str = "default"       # int8 для CPU, float16 для GPU
    gigaam_model: str = "v3_e2e_rnnt"   # модель GigaAM для TA_BACKEND=gigaam
    gigaam_timing: str = "whisper"      # whisper — таймкоды слов от Whisper (TA_MODEL) | vad — по VAD
    gigaam_dir: str | None = None       # куда качать веса GigaAM
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
            gigaam_model=e("TA_GIGAAM_MODEL", "v3_e2e_rnnt"),
            gigaam_timing=e("TA_GIGAAM_TIMING", "whisper"),
            gigaam_dir=e("TA_GIGAAM_DIR") or None,
            language=e("TA_LANGUAGE", "ru") or None,
            bucket=e("S3_BUCKET", "cutsheet"),
            work_dir=e("TA_WORK_DIR", "/tmp/transcription"),
        )
