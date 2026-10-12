"""Аудиодорожка из видео через ffmpeg: 16 кГц моно WAV — формат, который ждёт Whisper."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path


def has_audio(video: str | Path) -> bool:
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "a", "-show_entries", "stream=index",
                          "-of", "json", str(video)], check=True, capture_output=True, text=True).stdout
    return bool(json.loads(out or "{}").get("streams"))


def extract_audio(video: str | Path, wav: str | Path) -> Path:
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(video), "-vn", "-ac", "1", "-ar", "16000",
                    "-c:a", "pcm_s16le", str(wav)], check=True, capture_output=True)
    return Path(wav)
