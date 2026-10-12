"""Excel (openpyxl)."""

from __future__ import annotations

import io

from openpyxl import Workbook
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter

from .sheet import Sheet


def render_xlsx(sheet: Sheet) -> bytes:
    t = sheet.template
    font = t["font"]
    wb = Workbook()
    ws = wb.active
    ws.title = "Монтажный лист"[:31]

    base = Font(name=font["name"], size=font["size"])
    bold = Font(name=font["name"], size=font["size"], bold=True)
    thin = Side(style="thin", color="999999")
    border = Border(left=thin, right=thin, top=thin, bottom=thin)
    wrap = Alignment(wrap_text=True, vertical="top")

    ws.cell(row=1, column=1, value=sheet.title).font = Font(name=font["name"], size=font["title_size"], bold=True)
    row = 2
    for line in sheet.header:
        ws.cell(row=row, column=1, value=line).font = base
        row += 1
    row += 1

    head = row
    fill = PatternFill("solid", fgColor=t.get("header_fill") or "D9E2F3")
    for i, col in enumerate(sheet.columns, start=1):
        c = ws.cell(row=head, column=i, value=col.title)
        c.font, c.fill, c.border = bold, fill, border
        c.alignment = Alignment(wrap_text=True, vertical="center", horizontal="center")
        ws.column_dimensions[get_column_letter(i)].width = col.width

    for r, values in enumerate(sheet.rows, start=head + 1):
        for i, (col, value) in enumerate(zip(sheet.columns, values), start=1):
            # № — число, чтобы сортировка и фильтр в Excel работали по порядку сцен.
            c = ws.cell(row=r, column=i, value=int(value) if col.key == "number" and value.isdigit() else value)
            c.font, c.alignment, c.border = base, wrap, border

    last = head + len(sheet.rows)
    ws.freeze_panes = ws.cell(row=head + 1, column=1)
    ws.auto_filter.ref = f"A{head}:{get_column_letter(len(sheet.columns))}{max(last, head)}"
    ws.print_title_rows = f"{head}:{head}"
    ws.page_setup.orientation = t["page"]["orientation"]
    ws.page_setup.paperSize = ws.PAPERSIZE_A4 if t["page"].get("size", "A4") == "A4" else ws.PAPERSIZE_LETTER
    ws.page_setup.fitToWidth, ws.page_setup.fitToHeight = 1, 0
    ws.sheet_properties.pageSetUpPr.fitToPage = True
    ws.oddFooter.center.text = sheet.footer.replace("&", "&&").replace("{page}", "&P")
    wb.properties.title = f"{sheet.title}: {sheet.project}"

    out = io.BytesIO()
    wb.save(out)
    return out.getvalue()
