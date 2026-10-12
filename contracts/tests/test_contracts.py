"""Контрактные тесты: примеры валидны, каждый топик описан схемой и наоборот."""

import json
from pathlib import Path

import pytest

from cutsheet_common import ContractError, Contracts

ROOT = Path(__file__).resolve().parents[1]
EXAMPLES = sorted((ROOT / "examples").glob("*.json"))


def topics() -> set[str]:
    lines = (ROOT / "topics.txt").read_text(encoding="utf-8").splitlines()
    return {ln.split()[0] for ln in lines if ln.strip() and not ln.startswith("#")}


@pytest.fixture(scope="module")
def contracts():
    return Contracts(ROOT / "schemas")


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
