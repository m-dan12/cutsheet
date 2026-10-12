"""Текст сценария с сохранением структуры (FR-SP1): абзацы, стиль, отступ, выравнивание."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from docx import Document
from docx.table import Table
from docx.text.paragraph import Paragraph as DocxParagraph

EMU_PER_CM = 360000


@dataclass(frozen=True)
class Paragraph:
    i: int                  # порядковый номер среди непустых абзацев; из него строится line_id
    text: str
    style: str = ""
    indent_cm: float = 0.0  # левый отступ с учётом стиля
    align: str = ""         # left / center / right / justify
    blank_before: bool = False  # перед абзацем была пустая строка


def _style_attr(par: DocxParagraph, attr: str):
    """Значение из формата абзаца, иначе по цепочке стилей."""
    v = getattr(par.paragraph_format, attr)
    style = par.style
    while v is None and style is not None:
        v = getattr(style.paragraph_format, attr)
        style = style.base_style
    return v


def _describe(par: DocxParagraph) -> tuple[str, float, str]:
    indent = _style_attr(par, "left_indent") or 0
    align = _style_attr(par, "alignment")
    return (par.style.name if par.style is not None else "",
            round(indent / EMU_PER_CM, 1),
            align.name.lower() if align is not None else "")


def _iter_blocks(doc):
    """Абзацы и таблицы тела документа в исходном порядке."""
    body = doc.element.body
    for child in body.iterchildren():
        tag = child.tag.rsplit("}", 1)[-1]
        if tag == "p":
            yield DocxParagraph(child, doc)
        elif tag == "tbl":
            yield Table(child, doc)


def read_docx(path: str | Path) -> list[Paragraph]:
    doc = Document(str(path))
    raw: list[tuple[str, str, float, str]] = []
    for block in _iter_blocks(doc):
        if isinstance(block, DocxParagraph):
            raw.append((block.text, *_describe(block)))
            continue
        # Двухколоночная запись (часто в ТВ-сценариях): «РОЛЬ | реплика» → «РОЛЬ: реплика».
        for row in block.rows:
            cells = [c.text.strip() for c in row.cells]
            if len(cells) == 2 and cells[0] and len(cells[0]) <= 40 and cells[1]:
                raw.append((f"{cells[0]}: {cells[1]}", "Table", 0.0, ""))
            else:
                raw.extend((c, "Table", 0.0, "") for c in cells)
            raw.append(("", "", 0.0, ""))
    return _compact(raw)


def read_text(path: str | Path) -> list[Paragraph]:
    lines = Path(path).read_text(encoding="utf-8-sig").splitlines()
    return _compact([(ln.rstrip(), "", (len(ln) - len(ln.lstrip(" "))) * 0.25, "") for ln in lines])


def _compact(raw: list[tuple[str, str, float, str]]) -> list[Paragraph]:
    out: list[Paragraph] = []
    blank = False
    for text, style, indent, align in raw:
        text = " ".join(text.replace(" ", " ").split())
        if not text:
            blank = True
            continue
        out.append(Paragraph(len(out), text, style, indent, align, blank_before=blank))
        blank = False
    return out


def read_script(path: str | Path) -> list[Paragraph]:
    return read_text(path) if str(path).lower().endswith(".txt") else read_docx(path)
