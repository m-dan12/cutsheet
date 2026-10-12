import pytest

from cutsheet_common import ContractError, Contracts, derive_event_id, new_event

PID = "3f2b8c1e-5d4a-4e6b-9c7d-1a2b3c4d5e6f"


@pytest.fixture(scope="module")
def contracts():
    return Contracts()


def test_new_event_inherits_ids_and_is_deterministic():
    src = new_event("video.uploaded", {"video_uri": "s3://b/k.mp4", "filename": "k.mp4"}, project_id=PID)
    a = new_event("scenes.detected", {}, source=src, producer="scene-detection")
    b = new_event("scenes.detected", {}, source=src, producer="scene-detection")
    assert a.project_id == PID and a.correlation_id == src.correlation_id
    assert a.event_id == b.event_id == derive_event_id("scene-detection", src.event_id, "scenes.detected")


def test_valid_event_passes(contracts):
    ev = new_event("video.uploaded", {"video_uri": "s3://cutsheet/projects/x/video/a.mp4", "filename": "a.mp4"},
                   project_id=PID, producer="test")
    contracts.validate(ev.to_dict())


def test_invalid_event_rejected(contracts):
    ev = new_event("video.uploaded", {"video_uri": "http://not-s3", "filename": "a.mp4"}, project_id=PID)
    with pytest.raises(ContractError, match="video_uri"):
        contracts.validate(ev.to_dict())


def test_unknown_event_rejected(contracts):
    ev = new_event("nope.happened", {}, project_id=PID)
    with pytest.raises(ContractError, match="unknown"):
        contracts.validate(ev.to_dict())
