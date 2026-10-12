import json

import pytest

from export_service.sheet import build_sheet, dialogue
from export_service.template import TemplateError, Templates
from export_service.timecode import timecode


def test_timecode_frames_and_ms():
    assert timecode(0, 25) == "00:00:00:00"
    assert timecode(3_723_480, 25) == "01:02:03:12"
    assert timecode(1_999, 24) == "00:00:01:23"
    assert timecode(1_500, None) == "00:00:01:12"  # fps неизвестен — 25
    assert timecode(3_723_480, 25, "ms") == "01:02:03.480"


def test_dialogue_role_text_per_line():
    reps = [{"role": "ИВАН", "text": " Привет "}, {"role": None, "text": "Кто там?"}]
    assert dialogue(reps, None) == "ИВАН: Привет\nКто там?"
    assert dialogue(reps, "?") == "ИВАН: Привет\n?: Кто там?"


def test_build_sheet_from_snapshot(snapshot):
    sheet = build_sheet(snapshot, Templates().get())
    assert [c.title for c in sheet.columns] == ["№", "Начало", "Конец", "План", "Описание", "Диалоги"]
    assert sheet.header == ["Проект: Короткий метр", "Дата: 12.10.2026", "Сцен: 3", "Длительность: 00:00:07:10"]
    assert sheet.rows[1] == ["2", "00:00:02:00", "00:00:05:10", "крупный", "Иван смотрит на небо.",
                             "ИВАН: Ну и погода.\n(за кадром) Опаздываешь!"]
    assert sheet.rows[2][3:] == ["", "", ""]


def test_options_override_timecode(snapshot):
    sheet = build_sheet(snapshot, Templates().get(), {"timecode": "ms"})
    assert sheet.rows[1][2] == "00:00:05.400"


def test_options_pick_columns(snapshot):
    sheet = build_sheet(snapshot, Templates().get(), {"columns": ["number", "description", "nope"]})
    assert [c.key for c in sheet.columns] == ["number", "description"]
    assert sheet.rows[1] == ["2", "Иван смотрит на небо."]
    assert len(build_sheet(snapshot, Templates().get(), {"columns": []}).columns) == 6


def test_custom_template_overrides_default(tmp_path, snapshot):
    (tmp_path / "short.json").write_text(json.dumps({
        "columns": [{"key": "number", "title": "#", "width": 3}, {"key": "duration", "title": "Длит.", "width": 8}],
        "font": {"size": 11},
    }), encoding="utf-8")
    tpl = Templates(tmp_path).get("short")
    assert tpl["font"] == {"name": "DejaVu Sans", "size": 11, "title_size": 14}
    assert build_sheet(snapshot, tpl).rows[0] == ["1", "00:00:02:00"]


@pytest.mark.parametrize("name", ["missing", "../etc/passwd"])
def test_unknown_template(name):
    with pytest.raises(TemplateError):
        Templates().get(name)


def test_bad_column_rejected(tmp_path):
    (tmp_path / "bad.json").write_text(json.dumps({"columns": [{"key": "nope", "width": 3}]}), encoding="utf-8")
    with pytest.raises(TemplateError, match="nope"):
        Templates(tmp_path).get("bad")
