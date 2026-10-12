import io
import json

from openpyxl import load_workbook

from cutsheet_common import Contracts, new_event
from cutsheet_common.testing import FakeStorage

from export_service.config import Settings
from export_service.service import ExportService

PID = "3f2b8c1e-5d4a-4e6b-9c7d-1a2b3c4d5e6f"
EXPORT = "1e2d3c4b-5a69-4788-9a0b-c1d2e3f4a5b6"
SNAPSHOT = f"s3://cutsheet/projects/{PID}/exports/{EXPORT}/snapshot.json"


def request(fmt="xlsx", options=None, snapshot_uri=SNAPSHOT):
    return new_event("export.requested", {"export_id": EXPORT, "format": fmt, "snapshot_uri": snapshot_uri,
                                          "options": options or {}}, project_id=PID, producer="project-api")


def service(tmp_path, snapshot=None):
    storage = FakeStorage(tmp_path / "s3")
    if snapshot is not None:
        storage.path(SNAPSHOT).write_text(json.dumps(snapshot, ensure_ascii=False), encoding="utf-8")
    return ExportService(storage, Settings()), storage


def test_export_requested_to_completed(tmp_path, snapshot):
    svc, storage = service(tmp_path, snapshot)
    src = request("xlsx")

    [out] = svc.handle(src)

    Contracts().validate(out.to_dict())
    assert out.event_type == "export.completed" and out.correlation_id == src.correlation_id
    assert out.payload == {"export_id": EXPORT,
                           "result_uri": f"s3://cutsheet/projects/{PID}/exports/{EXPORT}/sheet.xlsx"}
    ws = load_workbook(io.BytesIO(storage.get_bytes(out.payload["result_uri"]))).active
    assert ws["A2"].value == "Проект: Короткий метр"
    assert svc.handle(src)[0].event_id == out.event_id  # повтор события — тот же результат


def test_all_formats(tmp_path, snapshot):
    svc, storage = service(tmp_path, snapshot)
    for fmt, magic in (("docx", b"PK"), ("pdf", b"%PDF")):
        [out] = svc.handle(request(fmt))
        assert out.event_type == "export.completed", out.payload
        assert storage.get_bytes(out.payload["result_uri"]).startswith(magic)


def test_missing_snapshot_fails(tmp_path):
    svc, _ = service(tmp_path)
    [out] = svc.handle(request())
    Contracts().validate(out.to_dict())
    assert out.event_type == "export.failed" and "не найден" in out.payload["error"]


def test_invalid_snapshot_fails(tmp_path, snapshot):
    snapshot["scenes"][0]["start_ms"] = -1
    svc, _ = service(tmp_path, snapshot)
    [out] = svc.handle(request())
    assert out.event_type == "export.failed" and "ContractError" in out.payload["error"]


def test_unknown_template_fails(tmp_path, snapshot):
    svc, _ = service(tmp_path, snapshot)
    [out] = svc.handle(request(options={"template": "nope"}))
    assert out.event_type == "export.failed" and "template not found" in out.payload["error"]


def test_other_events_ignored(tmp_path):
    svc, _ = service(tmp_path)
    assert svc.handle(new_event("video.uploaded", {}, project_id=PID)) == []
