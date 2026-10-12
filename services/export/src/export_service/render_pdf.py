"""PDF (reportlab). Встроенные шрифты PDF не знают кириллицу, поэтому нужен TTF из шаблона."""

from __future__ import annotations

import io
from pathlib import Path
from xml.sax.saxutils import escape

from reportlab.lib import colors
from reportlab.lib.pagesizes import A4, LETTER, landscape, portrait
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import LongTable, Paragraph, SimpleDocTemplate, Spacer, TableStyle

from .sheet import Sheet


class FontNotFound(RuntimeError):
    pass


def register_fonts(files: dict[str, str], dirs: tuple[str, ...]) -> tuple[str, str]:
    """Регистрирует regular / bold TTF; возвращает имена шрифтов для reportlab."""
    names = []
    for kind in ("regular", "bold"):
        filename = files[kind]
        name = f"cutsheet-{Path(filename).stem}"
        if name not in pdfmetrics.getRegisteredFontNames():
            path = next((Path(d) / filename for d in dirs if (Path(d) / filename).is_file()), None)
            if path is None:
                raise FontNotFound(f"font {filename} not found in {', '.join(dirs)} (EXPORT_FONTS_DIR)")
            pdfmetrics.registerFont(TTFont(name, str(path)))
        names.append(name)
    return names[0], names[1]


def _para(text: str, style: ParagraphStyle) -> Paragraph:
    return Paragraph(escape(text).replace("\n", "<br/>"), style)


def render_pdf(sheet: Sheet, font_dirs: tuple[str, ...]) -> bytes:
    t = sheet.template
    font, page = t["font"], t["page"]
    regular, bold = register_fonts(t["pdf_fonts"], font_dirs)
    size = {"A4": A4, "Letter": LETTER}.get(page.get("size", "A4"), A4)
    size = landscape(size) if page["orientation"] == "landscape" else portrait(size)
    margin = page.get("margin_mm", 12) * mm

    body = ParagraphStyle("body", fontName=regular, fontSize=font["size"], leading=font["size"] * 1.25)
    head = ParagraphStyle("head", parent=body, fontName=bold)
    title = ParagraphStyle("title", parent=body, fontName=bold, fontSize=font["title_size"],
                           leading=font["title_size"] * 1.3, spaceAfter=4)

    usable = size[0] - 2 * margin
    total = sum(c.width for c in sheet.columns)
    widths = [usable * c.width / total for c in sheet.columns]
    data = [[_para(c.title, head) for c in sheet.columns]]
    data += [[_para(v, body) for v in row] for row in sheet.rows]
    table = LongTable(data, colWidths=widths, repeatRows=1)
    table.setStyle(TableStyle([
        ("GRID", (0, 0), (-1, -1), 0.4, colors.HexColor("#999999")),
        ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#" + (t.get("header_fill") or "D9E2F3"))),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LEFTPADDING", (0, 0), (-1, -1), 3),
        ("RIGHTPADDING", (0, 0), (-1, -1), 3),
    ]))

    def footer(canvas, doc):
        canvas.saveState()
        canvas.setFont(regular, font["size"] - 1)
        canvas.setFillColor(colors.HexColor("#666666"))
        canvas.drawCentredString(size[0] / 2, margin / 2, sheet.footer.replace("{page}", str(doc.page)))
        canvas.restoreState()

    out = io.BytesIO()
    doc = SimpleDocTemplate(out, pagesize=size, leftMargin=margin, rightMargin=margin, topMargin=margin,
                            bottomMargin=margin, title=f"{sheet.title}: {sheet.project}", author="cutsheet")
    story = [_para(sheet.title, title), *[_para(line, body) for line in sheet.header], Spacer(1, 4 * mm), table]
    doc.build(story, onFirstPage=footer, onLaterPages=footer)
    return out.getvalue()
