"""Контрактные тесты: примеры валидны, каждый топик описан схемой и наоборот."""

import json
from pathlib import Path

import pytest

from cutsheet_common import ContractError, Contracts

ROOT = Path(__file__).resolve().parents[1]
EXAMPLES = sorted((ROOT / "examples").glob("*.json"))


def registry() -> set[str]:
    lines = (ROOT / "topics.txt").read_text(encoding="utf-8").splitlines()
    return {ln.split()[0] for ln in lines if ln.strip() and not ln.startswith("#")}


def topics() -> set[str]:
    """Топики событий; у DLQ своей схемы нет — в них лежат исходные сообщения как есть."""
    return {t for t in registry() if not t.endswith(".dlq")}


@pytest.fixture(scope="module")
def contracts():
    return Contracts(ROOT / "schemas")


def test_every_topic_has_dlq():
    assert {t for t in registry() if t.endswith(".dlq")} == {f"{t}.dlq" for t in topics()}


def test_every_topic_has_schema_and_example(contracts):
    assert topics() == contracts.event_types
    assert {p.name.rsplit(".v", 1)[0] for p in EXAMPLES} == contracts.event_types


@pytest.mark.parametrize("path", EXAMPLES, ids=lambda p: p.name)
def test_example_is_valid(contracts, path):
    contracts.validate(json.loads(path.read_text(encoding="utf-8")))


def test_payload_violations_are_caught(contracts):
    ev = json.loads((ROOT / "examples" / "scene.enriched.v1.json").read_text(encoding="utf-8"))
    del ev["payload"]["shot_type"]  # source=shot_type требует shot_type
    with pytest.raises(ContractError):
        contracts.validate(ev)
    ev = json.loads((ROOT / "examples" / "scenes.detected.v1.json").read_text(encoding="utf-8"))
    ev["payload"]["scenes"] = []
    with pytest.raises(ContractError):
        contracts.validate(ev)


DOCUMENTS = sorted((ROOT / "examples" / "documents").glob("*.json"))


@pytest.mark.parametrize("path", DOCUMENTS, ids=lambda p: p.name)
def test_document_example_is_valid(contracts, path):
    name, ver = path.name.removesuffix(".json").rsplit(".v", 1)
    contracts.validate_document(name, int(ver), json.loads(path.read_text(encoding="utf-8")))


def test_every_document_schema_has_example():
    schemas = {p.name for p in (ROOT / "schemas" / "documents").glob("*.json")}
    assert schemas == {p.name for p in DOCUMENTS}


def test_snapshot_violations_are_caught(contracts):
    doc = json.loads((ROOT / "examples" / "documents" / "sheet-snapshot.v1.json").read_text(encoding="utf-8"))
    doc["scenes"][0]["shot_type"] = "huge"
    with pytest.raises(ContractError, match="shot_type"):
        contracts.validate_document("sheet-snapshot", 1, doc)
