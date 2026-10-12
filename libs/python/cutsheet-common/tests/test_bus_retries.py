"""Повторы, DLQ и дедупликация в KafkaBus (этап 6) на поддельном продюсере."""

import json

import pytest

from cutsheet_common import new_event
from cutsheet_common.bus import KafkaBus, PermanentError

PID = "3f2b8c1e-5d4a-4e6b-9c7d-1a2b3c4d5e6f"


class FakeProducer:
    def __init__(self):
        self.sent: list[dict] = []

    def produce(self, topic, key=None, value=None, headers=None):
        self.sent.append({"topic": topic, "key": key, "value": value,
                          "headers": {k: v.decode() for k, v in headers or []}})

    def flush(self, timeout=None):
        return 0

    def topics(self):
        return [m["topic"] for m in self.sent]


@pytest.fixture
def bus():
    sleeps: list[float] = []
    b = KafkaBus("scene-detection", producer=FakeProducer(), max_attempts=3, backoff_s=1.0, sleep=sleeps.append)
    b.sleeps = sleeps
    return b


def uploaded() -> bytes:
    ev = new_event("video.uploaded", {"video_uri": "s3://cutsheet/projects/x/video/a.mp4", "filename": "a.mp4"},
                   project_id=PID, producer="project-api")
    return json.dumps(ev.to_dict()).encode()


def detected(src):
    return [new_event("scenes.detected", {"fps": 25.0, "duration_ms": 1000, "scenes": [
        {"index": 0, "start_ms": 0, "end_ms": 1000, "keyframe_uris": ["s3://cutsheet/projects/x/frames/0.jpg"]}]},
        source=src, producer="scene-detection")]


def test_invalid_message_goes_to_dlq_without_retry(bus):
    calls = []
    assert bus.process("video.uploaded", b"not json", calls.append, key=b"k", partition=1, offset=7)
    assert calls == []
    [dlq] = bus._producer.sent
    assert dlq["topic"] == "video.uploaded.dlq" and dlq["value"] == b"not json" and dlq["key"] == b"k"
    assert dlq["headers"]["x-dlq-reason"] == "invalid"
    assert dlq["headers"]["x-dlq-offset"] == "7" and dlq["headers"]["x-dlq-service"] == "scene-detection"


def test_transient_failure_is_retried_with_backoff(bus):
    attempts = []

    def handler(ev):
        attempts.append(1)
        if len(attempts) < 3:
            raise ConnectionError("s3 unavailable")
        return detected(ev)

    assert bus.process("video.uploaded", uploaded(), handler)
    assert len(attempts) == 3 and bus.sleeps == [1.0, 2.0]
    assert bus._producer.topics() == ["scenes.detected"]


def test_exhausted_retries_go_to_dlq_and_pipeline_failed(bus):
    def handler(ev):
        raise ConnectionError("s3 unavailable")

    raw = uploaded()
    assert bus.process("video.uploaded", raw, handler)
    assert bus.sleeps == [1.0, 2.0]
    assert bus._producer.topics() == ["video.uploaded.dlq", "pipeline.failed"]
    dlq, failed = bus._producer.sent
    assert dlq["value"] == raw
    assert dlq["headers"]["x-dlq-reason"] == "failed" and dlq["headers"]["x-dlq-attempts"] == "3"
    payload = json.loads(failed["value"])["payload"]
    assert payload["retryable"] is True and payload["error"].startswith("ConnectionError")


@pytest.mark.parametrize("exc", [ValueError("video has zero duration"), PermanentError("broken file")])
def test_data_errors_are_not_retried(bus, exc):
    def handler(ev):
        raise exc

    assert bus.process("video.uploaded", uploaded(), handler)
    assert bus.sleeps == []
    assert bus._producer.topics() == ["video.uploaded.dlq", "pipeline.failed"]
    assert json.loads(bus._producer.sent[1]["value"])["payload"]["retryable"] is False


def test_duplicate_is_skipped_but_failed_event_can_be_replayed(bus):
    calls = []
    raw = uploaded()
    bus.process("video.uploaded", raw, lambda ev: calls.append(ev) or detected(ev))
    bus.process("video.uploaded", raw, lambda ev: calls.append(ev) or detected(ev))
    assert len(calls) == 1

    other = uploaded()
    bus.process("video.uploaded", other, lambda ev: (_ for _ in ()).throw(PermanentError("x")))
    bus.process("video.uploaded", other, lambda ev: calls.append(ev) or detected(ev))
    assert len(calls) == 2


def test_stop_during_backoff_leaves_message_uncommitted(bus):
    def handler(ev):
        bus.stop()
        raise ConnectionError("down")

    assert bus.process("video.uploaded", uploaded(), handler) is False
    assert bus._producer.sent == []
