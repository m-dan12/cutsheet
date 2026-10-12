from transcription.align import AlignConfig, ScriptLine, Word, align, local_align, tokenize

SCRIPT = [
    ScriptLine("p00003", "МАША", "Ты опять не спал всю ночь?"),
    ScriptLine("p00005", "ИВАН", "Я думал о том, что ты сказала вчера. Ты была права."),
    ScriptLine("p00007", "МАША", "Тогда собирайся, мы опаздываем на поезд."),
    ScriptLine("p00010", "ПРОВОДНИК", "Билеты, пожалуйста! Поезд отправляется."),
    ScriptLine("p00011", "ИВАН", "Да."),
    ScriptLine("p00012", "МАША", "Вот наши билеты, мы успели."),
]


def speech(*utterances: str, word_ms: int = 300, pause_ms: int = 1500) -> list[Word]:
    """Слова с таймкодами: каждое высказывание — свой сегмент, между ними пауза."""
    words, t = [], 0
    for seg, u in enumerate(utterances):
        for w in u.split():
            words.append(Word(t, t + word_ms - 20, w, seg, 0.9))
            t += word_ms
        t += pause_ms
    return words


def by_line(replicas):
    return {r["script_line_id"]: r for r in replicas if r["matched"]}


def test_tokenize():
    assert tokenize("Ёлки-палки, ПРИВЕТ!") == ["елки", "палки", "привет"]


def test_local_align_finds_span_inside_window():
    a, b, matched, f1 = local_align(["мы", "опаздываем", "на", "поезд"],
                                    ["ну", "что", "мы", "опаздываем", "на", "поезд", "вот"], AlignConfig())
    assert (a, b) == (2, 6) and matched == 4 and f1 == 1.0


def test_in_order_dialogue_is_fully_matched():
    words = speech(*(ln.text for ln in SCRIPT))
    reps, stats = align(words, SCRIPT)
    assert [(r["role"], r["script_line_id"]) for r in reps] == [(ln.role, ln.line_id) for ln in SCRIPT]
    assert all(r["matched"] and r["confidence"] == 1.0 for r in reps)
    assert reps[0]["start_ms"] == words[0].start_ms and reps[0]["end_ms"] == words[5].end_ms
    assert stats == {"script_lines": 6, "matched_lines": 6, "unmatched_speech": 0, "words": len(words)}


def test_reordered_scenes_cut_lines_and_improvisation():
    # Монтаж: сцена на вокзале раньше квартиры; реплика Маши про поезд вырезана; есть импровизация.
    words = speech("Билеты пожалуйста поезд отправляется", "Да", "Вот наши билеты мы успели",
                   "Слушай а где мой зонт",
                   "Ты опять не спал всю ночь", "Я думал о том что ты сказала вчера ты была права")
    reps, stats = align(words, SCRIPT)
    lines = by_line(reps)
    assert set(lines) == {"p00010", "p00011", "p00012", "p00003", "p00005"}
    assert lines["p00011"]["role"] == "ИВАН"  # короткое «Да» найдено между соседями
    improv = [r for r in reps if not r["matched"]]
    assert [(r["role"], r["text"], r["script_line_id"]) for r in improv] == [(None, "Слушай а где мой зонт", None)]
    assert improv[0]["confidence"] == 0.9
    assert [r["start_ms"] for r in reps] == sorted(r["start_ms"] for r in reps)
    assert stats["matched_lines"] == 5 and stats["unmatched_speech"] == 1


def test_asr_errors_and_inflections():
    words = speech("ты опять не спала всю ночь", "я думала о том что ты сказал вчера ты была права",
                   "тогда собираися мы опоздаем на поезд")
    lines = by_line(align(words, SCRIPT[:3])[0])
    assert set(lines) == {"p00003", "p00005", "p00007"}
    assert all(0.5 <= r["confidence"] < 1.0 for r in lines.values())
    assert lines["p00007"]["spoken_text"] == "тогда собираися мы опоздаем на поезд"
    assert lines["p00007"]["text"] == "Тогда собирайся, мы опаздываем на поезд."


def test_short_line_is_not_matched_far_from_neighbours():
    # «Да» звучит, но рядом нет соседних реплик сценария — не приписываем его Ивану.
    script = [SCRIPT[0], ScriptLine("x", "ИВАН", "Да."), *SCRIPT[2:4]]
    far = speech("Ты опять не спал всю ночь", *(f"слово{i}" for i in range(100)), "да")
    lines = by_line(align(far, script)[0])
    assert "x" not in lines
    near = by_line(align(speech("Ты опять не спал всю ночь", "да"), script)[0])
    assert "x" in near


def test_repeated_lines_get_distinct_spans():
    script = [ScriptLine("a", "ИВАН", "Привет, как дела?"), ScriptLine("b", "МАША", "Нормально, а у тебя?"),
              ScriptLine("c", "ИВАН", "Привет, как дела?")]
    words = speech("Привет как дела", "Нормально а у тебя", "Привет как дела")
    reps, _ = align(words, script)
    spans = {r["script_line_id"]: r["start_ms"] for r in reps if r["matched"]}
    assert set(spans) == {"a", "b", "c"} and len(set(spans.values())) == 3
    assert spans["a"] < spans["b"] < spans["c"]


def test_no_speech_and_no_script():
    assert align([], SCRIPT) == ([], {"script_lines": 6, "matched_lines": 0, "unmatched_speech": 0, "words": 0})
    reps, _ = align(speech("кто здесь"), [])
    assert [(r["role"], r["matched"]) for r in reps] == [(None, False)]
