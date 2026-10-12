"""Проверка событий по JSON Schema из каталога contracts/schemas."""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator, FormatChecker
from referencing import Registry, Resource


class ContractError(ValueError):
    """Событие не соответствует контракту. Такие ошибки не ретраятся (ТЗ 4.3)."""


def _default_dir() -> Path:
    env = os.environ.get("CUTSHEET_CONTRACTS_DIR")
    if env:
        return Path(env)
    # В репозитории: ищем contracts/schemas вверх от текущего файла и cwd.
    for start in (Path(__file__).resolve(), Path.cwd().resolve()):
        for p in (start, *start.parents):
            cand = p / "contracts" / "schemas"
            if cand.is_dir():
                return cand
    raise FileNotFoundError("contracts/schemas not found; set CUTSHEET_CONTRACTS_DIR")


class Contracts:
    def __init__(self, schemas_dir: str | Path | None = None):
        self.dir = Path(schemas_dir) if schemas_dir else _default_dir()
        resources = []
        self._by_event: dict[tuple[str, int], dict[str, Any]] = {}
        # Документы в S3, которые передаются ссылкой из события (снимок листа для экспорта).
        self._by_document: dict[tuple[str, int], dict[str, Any]] = {}
        for path in sorted(self.dir.rglob("*.json")):
            schema = json.loads(path.read_text(encoding="utf-8"))
            resources.append((schema["$id"], Resource.from_contents(schema)))
            if path.parent.name in ("events", "documents"):
                name, ver = path.name.removesuffix(".json").rsplit(".v", 1)
                target = self._by_event if path.parent.name == "events" else self._by_document
                target[(name, int(ver))] = schema
        self._registry = Registry().with_resources(resources)
        self._validators = {
            k: Draft202012Validator(s, registry=self._registry, format_checker=FormatChecker())
            for k, s in self._by_event.items()
        }
        self._document_validators = {
            k: Draft202012Validator(s, registry=self._registry, format_checker=FormatChecker())
            for k, s in self._by_document.items()
        }

    @property
    def event_types(self) -> set[str]:
        return {name for name, _ in self._by_event}

    def validate(self, event: dict[str, Any]) -> None:
        key = (event.get("event_type"), event.get("schema_version"))
        validator = self._validators.get(key)  # type: ignore[arg-type]
        if validator is None:
            raise ContractError(f"unknown event type/version: {key}")
        _check(validator, event, f"{key[0]} v{key[1]}")

    def validate_document(self, name: str, version: int, doc: Any) -> None:
        """Проверка документа из schemas/documents (например, sheet-snapshot v1)."""
        validator = self._document_validators.get((name, version))
        if validator is None:
            raise ContractError(f"unknown document type/version: {(name, version)}")
        _check(validator, doc, f"{name} v{version}")


def _check(validator: Draft202012Validator, data: Any, what: str) -> None:
    errors = sorted(validator.iter_errors(data), key=lambda e: list(e.absolute_path))
    if errors:
        msg = "; ".join(f"{'/'.join(map(str, e.absolute_path)) or '<root>'}: {e.message}" for e in errors[:5])
        raise ContractError(f"{what}: {msg}")
