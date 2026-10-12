import pytest

from cutsheet_common import Contracts, new_event
from cutsheet_common.testing import FakeStorage
from llm_client.testing import FakeLLMServer
from script_parser.config import Settings
from script_parser.service import ScriptParserService
from test_llm import oracle

PID = "3f2b8c1e-5d4a-4e6b-9c7d-1a2b3c4d5e6f"


def uploaded(storage, sample_docx):
    uri = f"s3://cutsheet/projects/{PID}/script/script.docx"
    storage.path(uri).write_bytes(sample_docx.read_bytes())
    return new_event("script.uploaded", {"script_uri": uri, "filename": "script.docx"},
                     project_id=PID, producer="test")


def test_rules_mode_publishes_valid_script_parsed(tmp_path, sample_docx):
    storage = FakeStorage(tmp_path / "s3")
    svc = ScriptParserService(storage, Settings(mode="rules", work_dir=str(tmp_path / "w")))
    src = uploaded(storage, sample_docx)
    [out] = svc.handle(src)
    Contracts().validate(out.to_dict())
    p = out.payload
    assert out.event_type == "script.parsed" and out.correlation_id == src.correlation_id
    assert p["roles"] == ["МАША", "ИВАН", "ПРОВОДНИК"]
    assert p["role_aliases"]["ИВАН"] == ["Иван"] and p["parser"] == {"mode": "rules"}
    assert svc.handle(src)[0].event_id == out.event_id  # идемпотентность


def test_llm_mode(tmp_path, sample_docx):
    from script_parser.docx_reader import read_docx
    storage = FakeStorage(tmp_path / "s3")
    srv = FakeLLMServer(oracle(read_docx(sample_docx)))
    svc = ScriptParserService(storage, Settings(mode="llm", work_dir=str(tmp_path / "w")), srv.client())
    [out] = svc.handle(uploaded(storage, sample_docx))
    Contracts().validate(out.to_dict())
    assert out.payload["prompt_version"] == "script-labels-v1"
    assert out.payload["parser"] == {"mode": "llm", "model": "fake"}


def test_llm_mode_requires_client(tmp_path):
    with pytest.raises(ValueError):
        ScriptParserService(FakeStorage(tmp_path), Settings(mode="llm"))
