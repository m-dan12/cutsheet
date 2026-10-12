"""Word (python-docx)."""

from __future__ import annotations

import io

from docx import Document
from docx.enum.section import WD_ORIENT
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Mm, Pt, RGBColor

from .sheet import Sheet

PAGE_MM = {"A4": (210, 297), "Letter": (215.9, 279.4)}


def _field(run, instr: str) -> None:
    """Поле Word (номер страницы): begin / instrText / end."""
    for kind, text in (("begin", None), (None, instr), ("end", None)):
        if kind:
            el = OxmlElement("w:fldChar")
            el.set(qn("w:fldCharType"), kind)
        else:
            el = OxmlElement("w:instrText")
            el.set(qn("xml:space"), "preserve")
            el.text = text
        run._r.append(el)


def _shade(cell, color: str) -> None:
    shd = OxmlElement("w:shd")
    shd.set(qn("w:val"), "clear")
    shd.set(qn("w:color"), "auto")
    shd.set(qn("w:fill"), color)
    cell._tc.get_or_add_tcPr().append(shd)


def _lines(paragraph, text: str, bold: bool = False) -> None:
    for i, line in enumerate(text.split("\n")):
        run = paragraph.add_run()
        run.bold = bold
        if i:
            run.add_break()
        run.add_text(line)


def render_docx(sheet: Sheet) -> bytes:
    t = sheet.template
    font, page = t["font"], t["page"]
    doc = Document()

    normal = doc.styles["Normal"]
    normal.font.name = font["name"]
    normal.font.size = Pt(font["size"])
    # Кириллица берёт шрифт из w:cs / w:eastAsia, если их не задать — Word подставит свой.
    rfonts = normal.element.get_or_add_rPr().get_or_add_rFonts()
    for attr in ("w:ascii", "w:hAnsi", "w:cs", "w:eastAsia"):
        rfonts.set(qn(attr), font["name"])

    sec = doc.sections[0]
    w, h = PAGE_MM.get(page.get("size", "A4"), PAGE_MM["A4"])
    if page["orientation"] == "landscape":
        w, h = h, w
        sec.orientation = WD_ORIENT.LANDSCAPE
    sec.page_width, sec.page_height = Mm(w), Mm(h)
    margin = Mm(page.get("margin_mm", 12))
    sec.left_margin = sec.right_margin = sec.top_margin = sec.bottom_margin = margin

    title = doc.add_paragraph()
    run = title.add_run(sheet.title)
    run.bold, run.font.size = True, Pt(font["title_size"])
    for line in sheet.header:
        p = doc.add_paragraph(line)
        p.paragraph_format.space_after = Pt(0)
    doc.add_paragraph()

    table = doc.add_table(rows=1, cols=len(sheet.columns))
    table.style = "Table Grid"
    table.alignment = WD_TABLE_ALIGNMENT.CENTER
    table.autofit = False
    usable = sec.page_width - sec.left_margin - sec.right_margin
    total = sum(c.width for c in sheet.columns)
    widths = [int(usable * c.width / total) for c in sheet.columns]

    hdr = table.rows[0]
    tr_pr = hdr._tr.get_or_add_trPr()
    repeat = OxmlElement("w:tblHeader")  # шапка таблицы повторяется на каждой странице
    repeat.set(qn("w:val"), "true")
    tr_pr.append(repeat)
    for cell, col, width in zip(hdr.cells, sheet.columns, widths):
        cell.width = width
        _lines(cell.paragraphs[0], col.title, bold=True)
        _shade(cell, t.get("header_fill") or "D9E2F3")

    for values in sheet.rows:
        cells = table.add_row().cells
        for cell, value, width in zip(cells, values, widths):
            cell.width = width
            _lines(cell.paragraphs[0], value)

    footer = sec.footer.paragraphs[0]
    before, _, after = sheet.footer.partition("{page}")
    footer.add_run(before).font.color.rgb = RGBColor(0x66, 0x66, 0x66)
    if "{page}" in sheet.footer:
        _field(footer.add_run(), "PAGE")
        footer.add_run(after)
    doc.core_properties.title = f"{sheet.title}: {sheet.project}"

    out = io.BytesIO()
    doc.save(out)
    return out.getvalue()
