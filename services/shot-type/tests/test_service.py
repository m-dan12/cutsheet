import io

import numpy as np
from PIL import Image

from cutsheet_common import Contracts, new_event
from cutsheet_common.testing import FakeStorage
from shot_type.classify import FEET, HIPS, KNEES, SHOULDERS, Box, FrameObservation
from shot_type.config import Settings
from shot_type.service import ShotTypeService, pick
from test_classify import PERSON, pose

PID = "3f2b8c1e-5d4a-4e6b-9c7d-1a2b3c4d5e6f"
SCENE = "7c6d5e4f-3a2b-4c1d-9e8f-7a6b5c4d3e2f"


class FakeDetector:
    """Красный кадр — человек во весь рост, зелёный — по пояс, остальное — пусто."""
    name = "fake"

    def __init__(self):
        self.calls = 0

    def observe(self, rgb):
        self.calls += 1
        r, g, _ = rgb[0, 0]
        if r > 200:
            return FrameObservation(poses=[pose(SHOULDERS, HIPS, KNEES, FEET)], persons=[PERSON])
        if g > 200:
            return FrameObservation(poses=[pose(SHOULDERS, HIPS)], persons=[Box(0.2, 0.2, 0.8, 1.0)])
        return FrameObservation()


def jpeg(color) -> bytes:
    buf = io.BytesIO()
    Image.fromarray(np.full((90, 160, 3), color, np.uint8)).save(buf, "JPEG")
    return buf.getvalue()


def ready(storage, colors):
    uris = []
    for i, c in enumerate(colors):
        uri = f"s3://cutsheet/projects/{PID}/frames/scene_00003_{i}.jpg"
        storage.put_bytes(jpeg(c), "cutsheet", uri.split("/", 3)[3])
        uris.append(uri)
    return new_event("scene.ready-for-enrichment", {
        "scene_id": SCENE, "index": 3, "start_ms": 1000, "end_ms": 5000, "keyframe_uris": uris, "replicas": [],
    }, project_id=PID, producer="aggregator")


def test_publishes_valid_scene_enriched(tmp_path):
    storage = FakeStorage(tmp_path)
    svc = ShotTypeService(storage, Settings(), FakeDetector())
    src = ready(storage, [(0, 255, 0), (255, 0, 0), (0, 255, 0)])
    [out] = svc.handle(src)
    Contracts().validate(out.to_dict())
    p = out.payload
    assert out.event_type == "scene.enriched" and out.correlation_id == src.correlation_id
    assert p["scene_id"] == SCENE and p["source"] == "shot_type" and p["shot_type"] == "medium"
    assert p["request_event_id"] == src.event_id and p["model"] == "fake"
    assert p["prompt_version"] == "shot-rules-v1" and 0 < p["confidence"] < 1
    assert svc.handle(src)[0].event_id == out.event_id  # идемпотентность


def test_frames_are_limited_and_no_frames_gives_unknown(tmp_path):
    storage = FakeStorage(tmp_path)
    det = FakeDetector()
    svc = ShotTypeService(storage, Settings(max_frames=2), det)
    svc.handle(ready(storage, [(255, 0, 0)] * 5))
    assert det.calls == 2
    [out] = svc.handle(ready(storage, []))
    assert out.payload["shot_type"] == "unknown" and out.payload["confidence"] == 0
    Contracts().validate(out.to_dict())


def test_pick_spreads_evenly():
    assert pick(list("abcde"), 3) == ["a", "c", "e"]
    assert pick(list("abcde"), 1) == ["c"]
    assert pick(list("ab"), 5) == ["a", "b"]


def test_ignores_other_events(tmp_path):
    svc = ShotTypeService(FakeStorage(tmp_path), Settings(), FakeDetector())
    assert svc.handle(new_event("scenes.detected", {}, project_id=PID)) == []
