import json

from cutsheet_common import Contracts, new_event
from cutsheet_common.testing import FakeStorage
from transcription.align import Word
from transcription.audio import has_audio
from transcription.config import Settings
from transcription.service import TranscriptionService
from transcription.transcribe import Transcript

PID = "3f2b8c1e-5d4a-4e6b-9c7d-1a2b3c4d5e6f"
VIDEO = f"s3://cutsheet/projects/{PID}/video/film.mp4"

SCRIPT_PAYLOAD = {
    "script_scenes": [{"index": 0, "heading": "1. ИНТ. КУХНЯ", "lines": [
        {"line_id": "p00001", "kind": "action", "role": None, "text": "Иван у окна."},
        {"line_id": "p00003", "kind": "dialogue", "role": "МАША", "text": "Ты опять не спал всю ночь?"},
        {"line_id": "p00005", "kind": "dialogue", "role": "ИВАН", "text": "Я думал о том, что ты сказала."},
    ]}],
    "roles": ["МАША", "ИВАН"],
}


class FakeTranscriber:
    name = "fake:tiny"

    def __init__(self):
        self.calls = []

    def transcribe(self, wav, language):
        self.calls.append((wav.name, language))
        words, t = [], 0
        for seg, utt in enumerate(["ты опять не спал всю ночь", "ну и погода сегодня", "я думал о том что ты сказала"]):
            for w in utt.split():
                words.append(Word(t, t + 250, w, seg, 0.8))
                t += 300
            t += 1200
        return Transcript("ru", self.name, words)


def make(tmp_path, video):
    storage = FakeStorage(tmp_path / "s3")
    storage.path(VIDEO).write_bytes(video.read_bytes())
    tr = FakeTranscriber()
    svc = TranscriptionService(storage, Settings(work_dir=str(tmp_path / "w")), tr)
    return svc, storage, tr


def video_event(**extra):
    return new_event("video.uploaded", {"video_uri": VIDEO, "filename": "film.mp4", **extra},
                     project_id=PID, producer="test")


def script_event():
    return new_event("script.parsed", SCRIPT_PAYLOAD, project_id=PID, producer="script-parser")


def test_has_audio(video_with_audio, video_without_audio):
    assert has_audio(video_with_audio) and not has_audio(video_without_audio)


def test_video_then_script(tmp_path, video_with_audio):
    svc, storage, tr = make(tmp_path, video_with_audio)
    assert svc.handle(video_event()) == []  # ждём сценарий
    assert tr.calls == [("audio.wav", "ru")]
    cached = json.loads(storage.get_bytes(f"s3://cutsheet/projects/{PID}/transcript/transcript.json"))
    assert cached["model"] == "fake:tiny" and len(cached["words"]) == 17

    src = script_event()
    [out] = svc.handle(src)
    Contracts().validate(out.to_dict())
    reps = out.payload["replicas"]
    assert [(r["role"], r["script_line_id"], r["matched"]) for r in reps] == [
        ("МАША", "p00003", True), (None, None, False), ("ИВАН", "p00005", True)]
    assert reps[1]["text"] == "ну и погода сегодня"
    assert out.payload["language"] == "ru" and out.payload["stats"]["matched_lines"] == 2
    assert out.correlation_id == src.correlation_id
    assert svc.handle(src)[0].event_id == out.event_id  # повторная доставка — тот же id


def test_script_then_video_and_transcript_cache(tmp_path, video_with_audio):
    svc, _, tr = make(tmp_path, video_with_audio)
    assert svc.handle(script_event()) == []  # ждём транскрипт
    v1 = video_event()
    [out1] = svc.handle(v1)
    assert out1.event_type == "dialogue.aligned"
    # Повторная загрузка того же видео: транскрипт из кэша, но новый результат (новый id).
    [out2] = svc.handle(video_event())
    assert len(tr.calls) == 1 and out2.event_id != out1.event_id
    # Другой язык проекта — распознаём заново.
    svc.handle(video_event(language="en"))
    assert tr.calls[-1] == ("audio.wav", "en")


def test_video_without_audio_gives_empty_dialogue(tmp_path, video_without_audio):
    svc, _, tr = make(tmp_path, video_without_audio)
    svc.handle(script_event())
    [out] = svc.handle(video_event())
    Contracts().validate(out.to_dict())
    assert tr.calls == [] and out.payload["replicas"] == []
