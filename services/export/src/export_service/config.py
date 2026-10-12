from __future__ import annotations

import os
from dataclasses import dataclass, field


@dataclass(frozen=True)
class Settings:
    bucket: str = "cutsheet"
    # FR-E7: свои шаблоны (*.json) кладутся в этот каталог без пересборки образа; имя файла — имя шаблона.
    templates_dir: str | None = None
    # Каталоги со шрифтами TTF для PDF (кириллица): первый найденный файл из шаблона.
    font_dirs: tuple[str, ...] = field(default_factory=lambda: (
        "/usr/share/fonts/truetype/dejavu", "/usr/share/fonts/dejavu", "/usr/share/fonts/TTF",
        "/Library/Fonts", "C:/Windows/Fonts"))

    @classmethod
    def from_env(cls) -> "Settings":
        e = os.environ.get
        extra = tuple(p for p in (e("EXPORT_FONTS_DIR") or "").split(os.pathsep) if p)
        return cls(
            bucket=e("S3_BUCKET", "cutsheet"),
            templates_dir=e("EXPORT_TEMPLATES_DIR") or None,
            font_dirs=extra + cls().font_dirs,
        )
