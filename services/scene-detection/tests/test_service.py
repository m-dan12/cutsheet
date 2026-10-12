import shutil
from pathlib import Path

from cutsheet_common import Contracts, new_event
from cutsheet_common.storage import parse_s3_uri, s3_uri

from scene_detection.config import Settings
from scene_detection.service import SceneDetectionService

PID = "3f2b8c1e-5d4a-4e6b-9c7d-1a2b3c4d5e6f"


class FakeStorage:
    """S3 в локальной папке: s3://bucket/key -> root/bucket/key."""

    def __init__(self, root: Path):
        self.root = root

    def _path(self, bucket, key):
        p = self.root / bucket / key
        p.parent.mkdir(parents=True, exist_ok=True)
        return p

    def download(self, uri, dest):
        shutil.copy(self._path(*parse_s3_uri(uri)), dest)
        return Path(dest)

    def upload_file(self, src, bucket, key, content_type=None):
        shutil.copy(src, self._path(bucket, key))
        return s3_uri(bucket, key)


def test_video_uploaded_to_scenes_detected(three_shots, tmp_path):
    storage = FakeStorage(tmp_path / "s3")
    shutil.copy(three_shots, storage._path("cutsheet", f"projects/{PID}/video/film.mp4"))
    svc = SceneDetectionService(storage, Settings(work_dir=str(tmp_path / "work")))
    src = new_event("video.uploaded", {"video_uri": f"s3://cutsheet/projects/{PID}/video/film.mp4",
                                       "filename": "film.mp4"}, project_id=PID, producer="test")

    [out] = svc.handle(src)

    Contracts().validate(out.to_dict())
    scenes = out.payload["scenes"]
    assert out.event_type == "scenes.detected" and out.correlation_id == src.correlation_id
    assert [round(s["start_ms"] / 100) for s in scenes] == [0, 20, 50]  # белая вспышка 0.4 с короче минимума: детектор не ставит склейку на 5.4 с
    assert scenes[-1]["end_ms"] == out.payload["duration_ms"]
    assert all(len(s["keyframe_uris"]) == 3 for s in scenes)
    assert (tmp_path / "s3" / "cutsheet" / "projects" / PID / "frames" / "scene_00002_2.jpg").exists()
    # Повтор того же события даёт тот же event_id (идемпотентность у потребителя).
    assert svc.handle(src)[0].event_id == out.event_id
