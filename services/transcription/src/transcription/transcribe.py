"""Распознавание речи с пословными таймкодами (FR-TA1, FR-TA2).

Бэкенды выбираются конфигурацией (TA_BACKEND):
- faster-whisper — CTranslate2, работает на CPU без torch; образ по умолчанию;
- whisperx — faster-whisper + пословное выравнивание wav2vec2, точнее границы слов; нужен GPU.
Модели загружаются лениво и один раз на процесс.
"""

from __future__ import annotations

import logging
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Protocol

from .align import Word

log = logging.getLogger("transcription")


@dataclass
class Transcript:
    language: str | None
    model: str
    words: list[Word] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {"language": self.language, "model": self.model, "words": [asdict(w) for w in self.words]}

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "Transcript":
        return cls(d.get("language"), d["model"], [Word(**w) for w in d["words"]])


class Transcriber(Protocol):
    name: str

    def transcribe(self, wav: Path, language: str | None) -> Transcript: ...


def _ms(seconds: float) -> int:
    return max(0, round(seconds * 1000))


class FasterWhisperTranscriber:
    def __init__(self, model: str = "small", device: str = "auto", compute_type: str = "default",
                 beam_size: int = 5):
        self.model_name, self.device, self.compute_type, self.beam_size = model, device, compute_type, beam_size
        self.name = f"faster-whisper:{model}"
        self._model = None

    def transcribe(self, wav: Path, language: str | None) -> Transcript:
        from faster_whisper import WhisperModel

        if self._model is None:
            self._model = WhisperModel(self.model_name, device=self.device, compute_type=self.compute_type)
        segments, info = self._model.transcribe(str(wav), language=language, word_timestamps=True,
                                                vad_filter=True, beam_size=self.beam_size)
        words = [Word(_ms(w.start), _ms(w.end), w.word.strip(), si, round(w.probability, 3))
                 for si, seg in enumerate(segments) for w in (seg.words or [])]
        log.info("transcribed %d words, language=%s (p=%.2f)", len(words), info.language,
                 info.language_probability)
        return Transcript(info.language, self.name, words)


class WhisperXTranscriber:
    def __init__(self, model: str = "large-v3", device: str = "cuda", compute_type: str = "float16",
                 batch_size: int = 16):
        self.model_name, self.device, self.compute_type, self.batch_size = model, device, compute_type, batch_size
        self.name = f"whisperx:{model}"
        self._model = None
        self._align: dict[str, Any] = {}

    def transcribe(self, wav: Path, language: str | None) -> Transcript:
        import whisperx

        if self._model is None:
            self._model = whisperx.load_model(self.model_name, self.device, compute_type=self.compute_type)
        audio = whisperx.load_audio(str(wav))
        result = self._model.transcribe(audio, batch_size=self.batch_size, language=language)
        lang = result["language"]
        if lang not in self._align:
            self._align[lang] = whisperx.load_align_model(language_code=lang, device=self.device)
        model_a, meta = self._align[lang]
        aligned = whisperx.align(result["segments"], model_a, meta, audio, self.device)
        words: list[Word] = []
        for si, seg in enumerate(aligned["segments"]):
            seg_start, seg_end = _ms(seg["start"]), _ms(seg["end"])
            for w in seg.get("words", []):
                # Числа и символы wav2vec2 не выравнивает: берём границу предыдущего слова или сегмента.
                start = _ms(w["start"]) if "start" in w else (words[-1].end_ms if words and words[-1].segment == si
                                                              else seg_start)
                end = _ms(w["end"]) if "end" in w else min(seg_end, start + 300)
                words.append(Word(start, max(start, end), w["word"].strip(), si,
                                  round(w["score"], 3) if "score" in w else None))
        log.info("transcribed %d words, language=%s", len(words), lang)
        return Transcript(lang, self.name, words)


def make_transcriber(backend: str, model: str, device: str, compute_type: str) -> Transcriber:
    if backend == "faster-whisper":
        return FasterWhisperTranscriber(model, device, compute_type)
    if backend == "whisperx":
        return WhisperXTranscriber(model, "cuda" if device == "auto" else device,
                                   "float16" if compute_type == "default" else compute_type)
    raise ValueError(f"unknown TA_BACKEND: {backend}")
