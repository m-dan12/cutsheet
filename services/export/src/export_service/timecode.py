"""Таймкод `ЧЧ:ММ:СС:КК` без drop-frame (FR-E3), как в клиенте (client/lib/src/timecode.dart)."""

from __future__ import annotations

DEFAULT_FPS = 25.0


def timecode(ms: int, fps: float | None, mode: str = "frames") -> str:
    """frames — `ЧЧ:ММ:СС:КК` по fps видео; ms — `ЧЧ:ММ:СС.ммм`."""
    total_s, rest = divmod(int(ms), 1000)
    h, m, s = total_s // 3600, total_s % 3600 // 60, total_s % 60
    if mode == "ms":
        return f"{h:02d}:{m:02d}:{s:02d}.{rest:03d}"
    if mode != "frames":
        raise ValueError(f"unknown timecode mode: {mode}")
    rate = fps if fps and fps > 0 else DEFAULT_FPS
    frames = int(rest * rate // 1000)
    return f"{h:02d}:{m:02d}:{s:02d}:{frames:02d}"
