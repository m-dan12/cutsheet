"""Нормализация имён ролей (FR-SP3): «ИВАН», «Иван», «ИВАН (за кадром)» — одна роль."""

from __future__ import annotations

import re

# Пометки при имени: (за кадром), (З.К.), (ПРОД.), (CONT'D), (V.O.) и т.п. — любые скобки.
_PAREN = re.compile(r"\s*[(\[][^)\]]*[)\]]\s*")
# Пометки без скобок в конце имени.
_SUFFIX = re.compile(r"\s+(?:З\.?\s?К\.?|ЗА\s+КАДРОМ|ПРОД\.?|V\.?O\.?|O\.?S\.?|CONT'?D)\s*$", re.I)


def normalize_role(name: str) -> str:
    """Каноническое имя роли: без пометок, ё→Е, верхний регистр, без хвостовой пунктуации."""
    s = _PAREN.sub(" ", name)
    s = _SUFFIX.sub("", s.strip())
    s = s.strip(" .:;,—-–").upper().replace("Ё", "Е")
    return " ".join(s.split())


class RoleBook:
    """Единый список ролей между чанками: канон, варианты написания, порядок появления."""

    def __init__(self) -> None:
        self._aliases: dict[str, list[str]] = {}

    def add(self, raw: str) -> str | None:
        canon = normalize_role(raw)
        if not canon:
            return None
        variants = self._aliases.setdefault(canon, [])
        raw = " ".join(raw.split()).strip(" .:")
        if raw and raw != canon and raw not in variants:
            variants.append(raw)
        return canon

    @property
    def names(self) -> list[str]:
        return list(self._aliases)

    @property
    def aliases(self) -> dict[str, list[str]]:
        return {k: v for k, v in self._aliases.items() if v}
