"""Бэкенд GigaAM (Сбер): русская модель распознавания, которая на обычной речи заметно точнее Whisper.

GigaAM отдаёт только текст фрагмента до ~25 с, без таймкодов слов, а монтажному листу нужны
таймкоды. Поэтому распознавание идёт в два шага:
1. речь режется на фрагменты до 22 с — по словам Whisper (timing="whisper") или по Silero VAD
   из faster-whisper (timing="vad");
2. каждый фрагмент распознаёт GigaAM, а таймкоды его слов берутся у совпавших слов Whisper
   (выравнивание последовательностей с нечётким сравнением слов). Несовпавшие слова и весь режим "vad" получают таймкоды
   пропорционально длине слова внутри промежутка.
Так текст — от GigaAM, границы слов — от Whisper; это вариант G2 эксперимента 03а.
"""

from __future__ import annotations

import logging
import tempfile
import wave
from collections.abc import Callable, Sequence
from pathlib import Path

from .align import Word, _sim, tokenize
from .transcribe import FasterWhisperTranscriber, Transcript

log = logging.getLogger("transcription")

MAX_CHUNK_MS = 22_000   # GigaAM.transcribe принимает до 25 с
PAUSE_MS = 1_000        # пауза между словами Whisper, на которой начинается новый фрагмент
PAD_MS = 200            # запас по краям фрагмента: границы слов Whisper бывают тесными


def _key(token: str) -> str:
    return "".join(tokenize(token))


def chunk_spans(words: Sequence[Word], total_ms: int, max_ms: int = MAX_CHUNK_MS,
                pause_ms: int = PAUSE_MS, pad_ms: int = PAD_MS) -> list[tuple[int, int]]:
    """Фрагменты речи [start, end) в мс по словам Whisper: новый — после паузы или по длине."""
    groups: list[list[int]] = []
    for w in sorted(words, key=lambda w: w.start_ms):
        if groups and w.start_ms - groups[-1][1] <= pause_ms and w.end_ms - groups[-1][0] <= max_ms:
            groups[-1][1] = max(groups[-1][1], w.end_ms)
        else:
            groups.append([w.start_ms, w.end_ms])
    spans: list[tuple[int, int]] = []
    for i, (s, e) in enumerate(groups):
        lo = max(s - pad_ms, spans[-1][1] if spans else 0)
        hi = min(e + pad_ms, groups[i + 1][0] if i + 1 < len(groups) else total_ms)
        spans.append((lo, max(lo, min(hi, lo + max_ms))))
    return spans


def spread(tokens: Sequence[str], start_ms: int, end_ms: int, segment: int) -> list[Word]:
    """Таймкоды слов пропорционально их длине внутри промежутка."""
    if not tokens:
        return []
    end_ms = max(start_ms, end_ms)
    weights = [len(t) + 1 for t in tokens]
    total, acc, out = sum(weights), 0, []
    for t, wt in zip(tokens, weights):
        s = start_ms + (end_ms - start_ms) * acc // total
        acc += wt
        out.append(Word(s, start_ms + (end_ms - start_ms) * acc // total, t, segment))
    return out


def _pairs(a: Sequence[str], b: Sequence[str], min_sim: float) -> list[tuple[int, int]]:
    """Монотонные пары похожих слов с наибольшей суммарной похожестью (выравнивание как в LCS)."""
    n, m = len(a), len(b)
    score = [[0.0] * (m + 1) for _ in range(n + 1)]
    for i in range(n):
        for j in range(m):
            sim = _sim(a[i], b[j]) if a[i] and b[j] else 0.0
            diag = score[i][j] + sim if sim >= min_sim else -1.0
            score[i + 1][j + 1] = max(score[i][j + 1], score[i + 1][j], diag)
    pairs, i, j = [], n, m
    while i and j:
        if score[i][j] == score[i - 1][j]:
            i -= 1
        elif score[i][j] == score[i][j - 1]:
            j -= 1
        else:
            pairs.append((i - 1, j - 1))
            i, j = i - 1, j - 1
    return pairs[::-1]


def transfer_timings(tokens: Sequence[str], ref: Sequence[Word], start_ms: int, end_ms: int,
                     segment: int, min_sim: float = 0.5) -> list[Word]:
    """Слова GigaAM с таймкодами похожих слов Whisper; остальные — пропорционально между соседями."""
    tokens = [t for t in tokens if _key(t)]
    anchors = dict(_pairs([_key(t) for t in tokens], [_key(w.text) for w in ref], min_sim))
    out: list[Word] = []
    run: list[str] = []
    for i, t in enumerate([*tokens, None]):
        j = anchors.get(i)
        if t is not None and j is None:
            run.append(t)
            continue
        lo = out[-1].end_ms if out else start_ms
        hi = ref[j].start_ms if j is not None else end_ms
        out += spread(run, lo, max(lo, hi), segment)
        run = []
        if j is not None:
            out.append(Word(max(ref[j].start_ms, lo), max(ref[j].end_ms, lo), t, segment))
    return out


def _cut(wav: Path, start_ms: int, end_ms: int, dst: Path) -> Path:
    with wave.open(str(wav), "rb") as src:
        rate = src.getframerate()
        src.setpos(min(src.getnframes(), start_ms * rate // 1000))
        frames = src.readframes(max(0, (end_ms - start_ms) * rate // 1000))
        with wave.open(str(dst), "wb") as out:
            out.setparams(src.getparams())
            out.writeframes(frames)
    return dst


def _duration_ms(wav: Path) -> int:
    with wave.open(str(wav), "rb") as src:
        return src.getnframes() * 1000 // src.getframerate()


def _vad_spans(wav: Path) -> list[tuple[int, int]]:
    import numpy as np
    from faster_whisper.vad import VadOptions, get_speech_timestamps

    with wave.open(str(wav), "rb") as src:     # 16 кГц моно s16 из audio.extract_audio
        audio = np.frombuffer(src.readframes(src.getnframes()), np.int16).astype(np.float32) / 32768.0
    opts = VadOptions(max_speech_duration_s=MAX_CHUNK_MS / 1000, min_silence_duration_ms=500, speech_pad_ms=PAD_MS)
    return [(ts["start"] // 16, ts["end"] // 16) for ts in get_speech_timestamps(audio, opts)]


class GigaAMTranscriber:
    def __init__(self, model: str = "v3_e2e_rnnt", device: str = "auto", timing: str = "whisper",
                 whisper: FasterWhisperTranscriber | None = None, download_root: str | None = None,
                 recognizer: Callable[[Path], str] | None = None):
        if timing not in ("whisper", "vad"):
            raise ValueError(f"unknown TA_GIGAAM_TIMING: {timing}")
        if timing == "whisper" and whisper is None:
            raise ValueError("timing=whisper needs a Whisper transcriber")
        self.model_name, self.device, self.timing, self.whisper = model, device, timing, whisper
        self.download_root = download_root
        self.name = f"gigaam:{model}+" + (whisper.name if timing == "whisper" else "vad")
        self._recognize = recognizer       # подмена модели в тестах
        self._model = None

    def _text(self, chunk: Path) -> str:
        if self._recognize is not None:
            return self._recognize(chunk)
        if self._model is None:
            import gigaam

            self._model = gigaam.load_model(self.model_name, device=None if self.device == "auto" else self.device,
                                            download_root=self.download_root)
        result = self._model.transcribe(str(chunk))
        return result if isinstance(result, str) else getattr(result, "text", str(result))

    def transcribe(self, wav: Path, language: str | None) -> Transcript:
        if language not in (None, "ru"):
            log.warning("GigaAM распознаёт только русскую речь, язык %s не учитывается", language)
        total = _duration_ms(wav)
        ref: list[Word] = []
        if self.timing == "whisper":
            ref = self.whisper.transcribe(wav, "ru").words
            spans = chunk_spans(ref, total)
        else:
            spans = _vad_spans(wav)
        words: list[Word] = []
        with tempfile.TemporaryDirectory() as tmp:
            for si, (s, e) in enumerate(spans):
                text = self._text(_cut(wav, s, e, Path(tmp) / f"{si}.wav"))
                inside = [w for w in ref if s <= (w.start_ms + w.end_ms) // 2 < e]
                words += transfer_timings(text.split(), inside, s, e, si)
        log.info("transcribed %d words in %d chunks (gigaam, timing=%s)", len(words), len(spans), self.timing)
        return Transcript("ru", self.name, words)
