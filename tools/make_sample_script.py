"""Тестовый сценарий .docx в типовой записи: заголовки сцен, имена прописными с отступом,
реплики, ремарки в скобках, запись «ИМЯ: реплика» и двухколоночная таблица.

    python tools/make_sample_script.py tools/sample_script.docx
"""

from __future__ import annotations

import sys
from pathlib import Path

from docx import Document
from docx.shared import Cm

# (тип, текст): h — заголовок, a — действие, c — персонаж, d — реплика, p — ремарка в скобках,
# i — имя и реплика в одном абзаце, t — переход, _ — пустая строка.
SAMPLE = [
    ("h", "1. ИНТ. КВАРТИРА ИВАНА — УТРО"),
    ("a", "Иван сидит на кухне и смотрит в окно. Входит Маша."),
    ("_", ""),
    ("c", "МАША"),
    ("d", "Ты опять не спал всю ночь?"),
    ("_", ""),
    ("c", "ИВАН"),
    ("p", "(не оборачиваясь)"),
    ("d", "Я думал о том, что ты сказала вчера."),
    ("d", "Ты была права."),
    ("_", ""),
    ("c", "МАША (за кадром)"),
    ("d", "Тогда собирайся, мы опаздываем на поезд."),
    ("_", ""),
    ("t", "СМЕНА КАДРА"),
    ("_", ""),
    ("h", "2. НАТ. ВОКЗАЛ — ДЕНЬ"),
    ("a", "Толпа на перроне. Иван и Маша бегут к последнему вагону."),
    ("_", ""),
    ("i", "ПРОВОДНИК: Билеты, пожалуйста! Поезд отправляется."),
    ("i", "Иван (запыхавшись): Вот наши билеты, мы успели."),
    ("_", ""),
    ("a", "Поезд трогается."),
]

INDENT = {"c": 7.0, "d": 3.5, "p": 5.0, "i": 0.0}


def build(path: str | Path, items: list[tuple[str, str]] = SAMPLE, *, table: bool = True) -> Path:
    doc = Document()
    for kind, text in items:
        par = doc.add_paragraph(text)
        if kind in INDENT:
            par.paragraph_format.left_indent = Cm(INDENT[kind])
    if table:
        doc.add_paragraph("3. ИНТ. КУПЕ — ВЕЧЕР")
        t = doc.add_table(rows=2, cols=2)
        for row, (who, said) in zip(t.rows, [("МАША", "Куда мы едем?"), ("ИВАН", "К морю.")]):
            row.cells[0].text, row.cells[1].text = who, said
    path = Path(path)
    doc.save(str(path))
    return path


if __name__ == "__main__":
    print(build(sys.argv[1] if len(sys.argv) > 1 else "tools/sample_script.docx"))
