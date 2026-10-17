import subprocess

import pytest
from transcription.align import Word
from transcription.giga import GigaAMTranscriber, chunk_spans, spread, transfer_timings
from transcription.transcribe import Transcript, make_transcriber


def _words(*spans):
    return [Word(s, e, t) for t, s, e in spans]


def test_chunks_split_on_pause_and_length():
    ws = _words(("а", 0, 400), ("б", 500, 900), ("в", 3000, 3400), ("г", 3500, 20_000), ("д", 20_500, 26_000))
    spans = chunk_spans(ws, total_ms=30_000)
    assert spans == [(0, 1100), (2800, 20_200), (20_300, 26_200)]
    assert all(e - s <= 22_000 for s, e in spans)


def test_spread_is_proportional_and_monotonic():
    out = spread(["я", "думал"], 1000, 2000, 3)
    assert [(w.start_ms, w.end_ms, w.segment) for w in out] == [(1000, 1250, 3), (1250, 2000, 3)]


def test_transfer_takes_whisper_timings_for_matched_words():
    ref = _words(("Ты", 0, 200), ("опять", 300, 600), ("не", 700, 800), ("спал", 900, 1200))
    # Whisper ошибся в «спал» и пропустил «всю ночь» — их GigaAM расставит после «спал»
    ref[3] = Word(900, 1200, "спел")
    out = transfer_timings(["Ты", "опять", "не", "спал", "всю", "ночь?"], ref, 0, 2000, 0)
    assert [w.text for w in out] == ["Ты", "опять", "не", "спал", "всю", "ночь?"]
    assert [(w.start_ms, w.end_ms) for w in out[:4]] == [(0, 200), (300, 600), (700, 800), (900, 1200)]
    assert 1200 <= out[4].start_ms < out[5].start_ms and out[5].end_ms == 2000


def test_transfer_without_reference_spreads_and_drops_punctuation_tokens():
    out = transfer_timings(["Да", "—", "конечно."], [], 100, 1100, 1)
    assert [w.text for w in out] == ["Да", "конечно."]
    assert out[0].start_ms == 100 and out[-1].end_ms == 1100


class FakeWhisper:
    name = "faster-whisper:small"

    def transcribe(self, wav, language):
        return Transcript("ru", self.name, _words(("ты", 100, 300), ("апять", 350, 700), ("ну", 2500, 2700)))


@pytest.fixture
def wav(tmp_path):
    path = tmp_path / "a.wav"
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "sine=duration=4",
                    "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(path)], check=True)
    return path


def test_gigaam_transcriber_end_to_end_with_fake_models(wav):
    texts = iter(["Ты опять", "Ну и погода."])
    seen = []

    def recognize(chunk):
        seen.append(chunk.stat().st_size)
        return next(texts)

    t = GigaAMTranscriber(timing="whisper", whisper=FakeWhisper(), recognizer=recognize)
    tr = t.transcribe(wav, "ru")
    assert tr.model == "gigaam:v3_e2e_rnnt+faster-whisper:small" and tr.language == "ru"
    assert [w.text for w in tr.words] == ["Ты", "опять", "Ну", "и", "погода."]
    assert (tr.words[1].start_ms, tr.words[1].end_ms) == (350, 700)
    assert [w.segment for w in tr.words] == [0, 0, 1, 1, 1]
    assert len(seen) == 2 and all(size > 44 for size in seen)


def test_make_transcriber_gigaam_and_bad_timing():
    t = make_transcriber("gigaam", "small", "cpu", "int8", gigaam_timing="whisper")
    assert t.name == "gigaam:v3_e2e_rnnt+faster-whisper:small"
    assert make_transcriber("gigaam", "small", "cpu", "int8", gigaam_timing="vad").name == "gigaam:v3_e2e_rnnt+vad"
    with pytest.raises(ValueError):
        make_transcriber("gigaam", "small", "cpu", "int8", gigaam_timing="nope")
