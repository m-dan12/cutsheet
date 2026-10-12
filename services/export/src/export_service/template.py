"""Шаблоны оформления (FR-E7): JSON-файлы, которые меняются без пересборки сервиса.

Встроенный шаблон `default` лежит в пакете. Каталог EXPORT_TEMPLATES_DIR может добавить свои
шаблоны или переопределить встроенный: файл `<имя>.json` накладывается поверх `default`, так что
в нём достаточно указать только отличающиеся ключи.
"""

from __future__ import annotations

import json
import re
from importlib import resources
from pathlib import Path
from typing import Any

_NAME = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
COLUMN_KEYS = {"number", "start", "end", "duration", "shot", "description", "dialogue"}


class TemplateError(ValueError):
    pass


def _merge(base: dict[str, Any], over: dict[str, Any]) -> dict[str, Any]:
    out = dict(base)
    for k, v in over.items():
        out[k] = _merge(out[k], v) if isinstance(v, dict) and isinstance(out.get(k), dict) else v
    return out


class Templates:
    def __init__(self, directory: str | Path | None = None):
        self.dir = Path(directory) if directory else None
        self._default = json.loads(resources.files(__package__).joinpath("templates/default.json")
                                   .read_text(encoding="utf-8"))

    def get(self, name: str = "default") -> dict[str, Any]:
        if not _NAME.match(name):
            raise TemplateError(f"bad template name: {name!r}")
        base = self._default
        own = self.dir / f"{name}.json" if self.dir else None
        if own is not None and own.is_file():
            try:
                tpl = _merge(base, json.loads(own.read_text(encoding="utf-8")))
            except json.JSONDecodeError as e:
                raise TemplateError(f"template {name}: {e}") from e
        elif name == "default":
            tpl = base
        else:
            raise TemplateError(f"template not found: {name}")
        _check(tpl, name)
        return tpl


def _check(tpl: dict[str, Any], name: str) -> None:
    cols = tpl.get("columns")
    if not isinstance(cols, list) or not cols:
        raise TemplateError(f"template {name}: columns must be a non-empty list")
    for c in cols:
        if c.get("key") not in COLUMN_KEYS:
            raise TemplateError(f"template {name}: unknown column {c.get('key')!r}")
        if not isinstance(c.get("width"), (int, float)) or c["width"] <= 0:
            raise TemplateError(f"template {name}: column {c['key']} needs a positive width")
    if tpl.get("timecode") not in ("frames", "ms"):
        raise TemplateError(f"template {name}: timecode must be frames or ms")
    if tpl["page"].get("orientation") not in ("portrait", "landscape"):
        raise TemplateError(f"template {name}: page.orientation must be portrait or landscape")
