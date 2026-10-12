import io

from docx import Document
from openpyxl import load_workbook
from pypdf import PdfReader

from export_service.config import Settings
from export_service.render_docx import render_docx
from export_service.render_pdf import render_pdf
from export_service.render_xlsx import render_xlsx
from export_service.sheet import build_sheet
from export_service.template import Templates


def sheet_of(snapshot, scenes=None):
    if scenes is not None:
        snapshot["scenes"] = scenes
    return build_sheet(snapshot, Templates().get())


def test_xlsx(snapshot):
    ws = load_workbook(io.BytesIO(render_xlsx(sheet_of(snapshot)))).active
    values = [[c for c in row] for row in ws.iter_rows(values_only=True)]
    assert values[0][0] == "Монтажный лист"
    assert values[1][0] == "Проект: Короткий метр"
    head = values.index(["№", "Начало", "Конец", "План", "Описание", "Диалоги"])
    assert values[head + 2] == [2, "00:00:02:00", "00:00:05:10", "крупный", "Иван смотрит на небо.",
                                "ИВАН: Ну и погода.\n(за кадром) Опаздываешь!"]
    assert ws.freeze_panes == f"A{head + 2}"
    assert ws.page_setup.orientation == "landscape"


def test_docx(snapshot):
    doc = Document(io.BytesIO(render_docx(sheet_of(snapshot))))
    texts = [p.text for p in doc.paragraphs]
    assert texts[0] == "Монтажный лист" and "Сцен: 3" in texts
    [table] = doc.tables
    assert [c.text for c in table.rows[0].cells] == ["№", "Начало", "Конец", "План", "Описание", "Диалоги"]
    assert table.rows[2].cells[5].text == "ИВАН: Ну и погода.\n(за кадром) Опаздываешь!"
    assert len(table.rows) == 4
    assert doc.sections[0].page_width > doc.sections[0].page_height  # альбомная


def test_pdf_has_cyrillic_text(snapshot):
    data = render_pdf(sheet_of(snapshot), Settings().font_dirs)
    assert data.startswith(b"%PDF")
    text = "".join(page.extract_text() for page in PdfReader(io.BytesIO(data)).pages)
    for expected in ("Монтажный лист", "Короткий метр", "ИВАН: Ну и погода.", "00:00:05:10", "стр. 1"):
        assert expected in text


def test_long_sheet_spans_pages_with_repeated_header(snapshot):
    scenes = [{"number": i + 1, "start_ms": i * 2000, "end_ms": (i + 1) * 2000, "shot_type": "medium",
               "description": "Длинное описание сцены " * 8, "replicas": [{"role": "АННА", "text": "Реплика"}]}
              for i in range(120)]
    snapshot["duration_ms"] = 240_000
    pdf = PdfReader(io.BytesIO(render_pdf(sheet_of(snapshot, scenes), Settings().font_dirs)))
    assert len(pdf.pages) > 3
    assert all("Описание" in p.extract_text() for p in pdf.pages)  # шапка таблицы на каждой странице
    doc = Document(io.BytesIO(render_docx(sheet_of(snapshot, scenes))))
    assert len(doc.tables[0].rows) == 121


def test_empty_sheet(snapshot):
    sheet = sheet_of(snapshot, [])
    assert render_xlsx(sheet) and render_docx(sheet)
    assert render_pdf(sheet, Settings().font_dirs).startswith(b"%PDF")
