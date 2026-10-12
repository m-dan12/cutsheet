from script_parser import rules
from script_parser.docx_reader import read_docx, read_text
from script_parser.labels import Label, assemble, split_inline
from script_parser.roles import RoleBook, normalize_role


def dialogue(scenes):
    return [(ln["role"], ln["text"]) for sc in scenes for ln in sc["lines"] if ln["kind"] == "dialogue"]


def test_normalize_role_variants():
    for raw in ("ИВАН", "Иван", "ИВАН (за кадром)", "ИВАН (ПРОД.)", "Иван:", "ИВАН З.К.", "иван (V.O.)"):
        assert normalize_role(raw) == "ИВАН", raw
    assert normalize_role("Пётр Иваныч") == "ПЕТР ИВАНЫЧ"
    book = RoleBook()
    assert book.add("Маша (за кадром)") == book.add("МАША") == "МАША"
    assert book.names == ["МАША"] and book.aliases == {"МАША": ["Маша (за кадром)"]}


def test_split_inline():
    assert split_inline("ИВАН: Привет") == ("ИВАН", "Привет")
    assert split_inline("МАША (за кадром). Иди сюда!") == ("МАША", "Иди сюда!")
    assert split_inline("Он молчит") is None


def test_read_docx_keeps_structure(sample_docx):
    ps = read_docx(sample_docx)
    by_text = {p.text: p for p in ps}
    assert by_text["МАША"].indent_cm == 7.0 and by_text["Ты была права."].indent_cm == 3.5
    assert by_text["МАША"].blank_before and not by_text["Ты была права."].blank_before
    assert ps[-2].text == "МАША: Куда мы едем?" and ps[-1].text == "ИВАН: К морю."  # таблица
    assert [p.i for p in ps] == list(range(len(ps)))


def test_rules_on_sample(sample_docx):
    ps = read_docx(sample_docx)
    scenes, roles = assemble(ps, rules.classify(ps))
    assert [s["heading"] for s in scenes] == ["1. ИНТ. КВАРТИРА ИВАНА — УТРО", "2. НАТ. ВОКЗАЛ — ДЕНЬ",
                                              "3. ИНТ. КУПЕ — ВЕЧЕР"]
    assert roles.names == ["МАША", "ИВАН", "ПРОВОДНИК"]
    assert dialogue(scenes) == [
        ("МАША", "Ты опять не спал всю ночь?"),
        ("ИВАН", "Я думал о том, что ты сказала вчера. Ты была права."),
        ("МАША", "Тогда собирайся, мы опаздываем на поезд."),
        ("ПРОВОДНИК", "Билеты, пожалуйста! Поезд отправляется."),
        ("ИВАН", "Вот наши билеты, мы успели."),
        ("МАША", "Куда мы едем?"),
        ("ИВАН", "К морю."),
    ]
    actions = [ln["text"] for sc in scenes for ln in sc["lines"] if ln["kind"] == "action"]
    assert actions == ["Иван сидит на кухне и смотрит в окно. Входит Маша.",
                       "Толпа на перроне. Иван и Маша бегут к последнему вагону.", "Поезд трогается."]
    ids = [ln["line_id"] for sc in scenes for ln in sc["lines"]]
    assert len(ids) == len(set(ids))


def test_plain_text_script(tmp_path):
    f = tmp_path / "s.txt"
    f.write_text("ИНТ. ОФИС. ДЕНЬ\n\nПусто.\n\n          ОЛЕГ\n    Где все?\n\nОн садится.\n", encoding="utf-8")
    ps = read_text(f)
    scenes, roles = assemble(ps, rules.classify(ps))
    assert roles.names == ["ОЛЕГ"] and dialogue(scenes) == [("ОЛЕГ", "Где все?")]
    assert [ln["kind"] for ln in scenes[0]["lines"]] == ["action", "dialogue", "action"]


def test_text_before_first_heading_and_unknown_speaker():
    from script_parser.docx_reader import Paragraph
    ps = [Paragraph(0, "Пролог."), Paragraph(1, "Кто-то говорит."), Paragraph(2, "1. ИНТ. ДОМ")]
    scenes, _ = assemble(ps, [Label("action"), Label("dialogue"), Label("heading")])
    assert scenes[0]["heading"] == "" and [ln["kind"] for ln in scenes[0]["lines"]] == ["action", "action"]
    assert scenes[1] == {"index": 1, "heading": "1. ИНТ. ДОМ", "lines": []}
