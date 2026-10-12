import io
import json

import numpy as np
import pytest
from PIL import Image

from cutsheet_common import Contracts, new_event
from cutsheet_common.testing import FakeStorage
from llm_client import LLMInvalidOutput
from llm_client.testing import FakeLLMServer
from scene_description.config import Settings
from scene_description.context import build_context, script_index
from scene_description.describe import check_description
from scene_description.service import SceneDescriptionService, pick

PID = "3f2b8c1e-5d4a-4e6b-9c7d-1a2b3c4d5e6f"
SCENE = "7c6d5e4f-3a2b-4c1d-9e8f-7a6b5c4d3e2f"
REPLICAS = [
    {"start_ms": 1200, "end_ms": 3400, "role": "ИВАН", "text": "Ты опять не спал всю ночь и даже не ел?",
     "script_line_id": "p00004", "matched": True},
    {"start_ms": 3500, "end_ms": 4000, "role": None, "text": "ну и погода", "script_line_id": None},
]
SCRIPT = {"script_scenes": [
    {"index": 0, "heading": "1. ИНТ. КУХНЯ — УТРО", "lines": [
        {"line_id": "p00002", "kind": "action", "text": "Маша наливает чай. Иван сидит у окна."},
        {"line_id": "p00004", "kind": "dialogue", "role": "ИВАН", "text": "Ты опять не спал всю ночь?"},
    ]},
    {"index": 1, "heading": "2. НАТ. ПЕРРОН — ДЕНЬ", "lines": []},
], "roles": ["ИВАН"]}
GOOD = '{"description": "Иван сидит у окна на кухне, Маша наливает чай."}'


def jpeg(w=1600, h=900) -> bytes:
    buf = io.BytesIO()
    Image.fromarray(np.full((h, w, 3), (90, 60, 30), np.uint8)).save(buf, "JPEG")
    return buf.getvalue()


def ready(storage, n_frames=3, replicas=REPLICAS):
    uris = []
    for i in range(n_frames):
        key = f"projects/{PID}/frames/scene_00002_{i}.jpg"
        uris.append(storage.put_bytes(jpeg(), "cutsheet", key))
    return new_event("scene.ready-for-enrichment", {
        "scene_id": SCENE, "index": 2, "start_ms": 1000, "end_ms": 5000, "keyframe_uris": uris, "replicas": replicas,
    }, project_id=PID, producer="aggregator")


def service(tmp_path, replies, **settings):
    srv = FakeLLMServer(replies)
    svc = SceneDescriptionService(FakeStorage(tmp_path), Settings(**settings), srv.client(model="qwen2.5vl:7b"))
    return svc, srv


def test_describes_scene_with_frames_and_script_context(tmp_path):
    svc, srv = service(tmp_path, [GOOD], max_frames=2)
    assert svc.handle(new_event("script.parsed", SCRIPT, project_id=PID, producer="script-parser")) == []
    src = ready(svc.storage)
    [out] = svc.handle(src)
    Contracts().validate(out.to_dict())
    p = out.payload
    assert p == {"scene_id": SCENE, "source": "description",
                 "description": "Иван сидит у окна на кухне, Маша наливает чай.",
                 "prompt_version": "scene-description-v1", "model": "qwen2.5vl:7b", "request_event_id": src.event_id}

    [req] = srv.requests[:1]
    system, user = req["messages"]
    assert "1–3 коротких предложения" in system["content"]
    text, *images = user["content"]
    assert "ИВАН: Ты опять не спал" in text["text"] and "неизвестный: ну и погода" in text["text"]
    assert "1. ИНТ. КУХНЯ — УТРО" in text["text"] and "Маша наливает чай" in text["text"]
    assert len(images) == 2 and images[0]["image_url"]["url"].startswith("data:image/jpeg;base64,")
    # Кадр уменьшен до frame_max_side.
    import base64
    img = Image.open(io.BytesIO(base64.b64decode(images[0]["image_url"]["url"].split(",", 1)[1])))
    assert max(img.size) == 768


def test_invalid_descriptions_are_retried(tmp_path):
    quote = '{"description": "Иван говорит: ты опять не спал всю ночь и даже не ел."}'
    english = '{"description": "A man sits by the window."}'
    svc, srv = service(tmp_path, [quote, english, GOOD])
    [out] = svc.handle(ready(svc.storage))
    assert out.payload["description"].startswith("Иван сидит")
    assert "цитирует реплику" in srv.requests[1]["messages"][-1]["content"]
    assert "на русском" in srv.requests[2]["messages"][-1]["content"]


def test_gives_up_after_attempts(tmp_path):
    long = json.dumps({"description": "Иван сидит. Маша стоит. Кот спит. Чайник кипит."}, ensure_ascii=False)
    svc, _ = service(tmp_path, [long] * 3)
    with pytest.raises(LLMInvalidOutput, match="предложений"):
        svc.handle(ready(svc.storage))


def test_stub_mode_without_llm(tmp_path):
    svc = SceneDescriptionService(FakeStorage(tmp_path), Settings(mode="stub"))
    [out] = svc.handle(ready(svc.storage))
    Contracts().validate(out.to_dict())
    assert out.payload["model"] == "stub" and out.payload["description"]


def test_mode_validation(tmp_path):
    with pytest.raises(ValueError):
        SceneDescriptionService(FakeStorage(tmp_path), Settings(mode="llm"))
    with pytest.raises(ValueError):
        SceneDescriptionService(FakeStorage(tmp_path), Settings(mode="magic"))


def test_prompt_file_sets_version(tmp_path):
    f = tmp_path / "my-prompt-v7.txt"
    f.write_text("Опиши кадр.", encoding="utf-8")
    svc, srv = service(tmp_path, [GOOD], prompt_file=str(f))
    [out] = svc.handle(ready(svc.storage, n_frames=1))
    assert out.payload["prompt_version"] == "my-prompt-v7"
    assert srv.requests[0]["messages"][0]["content"] == "Опиши кадр."


def test_check_description():
    check_description("Иван сидит у окна.", REPLICAS)
    check_description("Двое идут по перрону, мимо проходит поезд", [])
    with pytest.raises(ValueError):
        check_description("x" * 500, [])


def test_context_is_limited_and_works_without_script():
    ctx = build_context(REPLICAS, None, 1500)
    assert "Фрагмент сценария" not in ctx and "ИВАН:" in ctx
    assert build_context([], None, 1500) == "Реплик в этом плане нет."
    idx = script_index(SCRIPT)
    assert idx["line_scene"] == {"p00002": 0, "p00004": 0}
    assert len(build_context(REPLICAS, idx, 40)) <= 41


def test_pick():
    assert pick(list("abcde"), 3) == ["a", "c", "e"]
