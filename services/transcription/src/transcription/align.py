"""Сопоставление реплик сценария с распознанной речью (FR-TA3–TA5).

Монтаж переставляет и выкидывает сцены, актёры импровизируют, ASR ошибается, поэтому
выравнивание не монотонное:
1. Кандидаты: для каждой реплики сценария ищем в транскрипте места, где встречаются её
   слова (точно или по префиксу — устойчиво к окончаниям), и голосуем за позицию начала.
2. Уточнение: локальное выравнивание Смита — Уотермана слов реплики с окном транскрипта
   с нечётким сравнением слов; оценка — F1 по совпавшим словам.
3. Выбор: жадно от самых надёжных (длинных и точных) пар; каждая реплика сценария и
   каждое слово речи используются не больше одного раза. Порядок сценария не требуется.
4. Короткие реплики («Да.», «Ну?») неоднозначны — их ищем только в промежутке между уже
   найденными соседями по сценарию.
5. Речь, не попавшая ни в одну реплику, остаётся репликой с неизвестным говорящим.
"""

from __future__ import annotations

import math
import re
from collections import defaultdict
from dataclasses import dataclass
from functools import lru_cache
from typing import Any

from rapidfuzz.distance import Levenshtein


@dataclass(frozen=True)
class Word:
    start_ms: int
    end_ms: int
    text: str
    segment: int = 0
    probability: float | None = None


@dataclass(frozen=True)
class ScriptLine:
    line_id: str
    role: str | None
    text: str


@dataclass(frozen=True)
class AlignConfig:
    min_confidence: float = 0.5        # порог для реплик, найденных по всему транскрипту
    min_gap_confidence: float = 0.75   # порог для поиска в промежутке между соседями
    max_gap_tokens: int = 80           # промежуток длиннее — короткую реплику не ищем
    word_similarity: float = 0.7       # слова считаются совпавшими с этого сходства
    pause_ms: int = 800                # пауза, разделяющая несопоставленную речь на реплики
    candidates_per_line: int = 6


@dataclass
class Match:
    line: int
    start: int          # индексы токенов транскрипта, [start, end)
    end: int
    confidence: float


_TOKEN = re.compile(r"[0-9a-zа-я]+")


def tokenize(text: str) -> list[str]:
    return _TOKEN.findall(text.lower().replace("ё", "е"))


@lru_cache(maxsize=200_000)
def _sim(a: str, b: str) -> float:
    if a == b:
        return 1.0
    return Levenshtein.normalized_similarity(a, b)


def local_align(line: list[str], window: list[str], cfg: AlignConfig) -> tuple[int, int, float, float] | None:
    """Смит — Уотерман: лучший участок окна для реплики.

    Возвращает (начало, конец) в окне, сумму сходств совпавших слов и F1-оценку.
    """
    n, m = len(line), len(window)
    if not n or not m:
        return None
    gap, mismatch = -0.5, -0.6
    H = [[0.0] * (m + 1) for _ in range(n + 1)]
    S = [[0.0] * (m + 1) for _ in range(n + 1)]   # сумма сходств на лучшем пути
    T = [[0] * (m + 1) for _ in range(n + 1)]     # 0 стоп, 1 диагональ, 2 вверх, 3 влево
    best = (0.0, 0, 0)
    for i in range(1, n + 1):
        a = line[i - 1]
        for j in range(1, m + 1):
            s = _sim(a, window[j - 1])
            hit = s >= cfg.word_similarity
            d = H[i - 1][j - 1] + (s if hit else mismatch)
            u = H[i - 1][j] + gap
            lft = H[i][j - 1] + gap
            v = max(0.0, d, u, lft)
            H[i][j] = v
            if v == 0.0:
                continue
            if v == d:
                T[i][j], S[i][j] = 1, S[i - 1][j - 1] + (s if hit else 0.0)
            elif v == u:
                T[i][j], S[i][j] = 2, S[i - 1][j]
            else:
                T[i][j], S[i][j] = 3, S[i][j - 1]
            if v > best[0]:
                best = (v, i, j)
    if best[0] == 0.0:
        return None
    _, i, j = best
    end, matched = j, S[i][j]
    while i > 0 and j > 0 and T[i][j]:
        t = T[i][j]
        if t == 1:
            i, j = i - 1, j - 1
        elif t == 2:
            i -= 1
        else:
            j -= 1
    start = j
    f1 = 2 * matched / (n + (end - start))
    return start, end, matched, f1


class Aligner:
    def __init__(self, words: list[Word], lines: list[ScriptLine], cfg: AlignConfig | None = None):
        self.cfg = cfg or AlignConfig()
        self.words = words
        self.lines = lines
        self.tokens: list[str] = []
        self.token_word: list[int] = []   # токен → индекс слова
        for wi, w in enumerate(words):
            for t in tokenize(w.text):
                self.tokens.append(t)
                self.token_word.append(wi)
        self.line_tokens = [tokenize(ln.text) for ln in lines]
        self._exact: dict[str, list[int]] = defaultdict(list)
        self._prefix: dict[str, list[int]] = defaultdict(list)
        for pos, t in enumerate(self.tokens):
            self._exact[t].append(pos)
            if len(t) >= 5:
                self._prefix[t[:4]].append(pos)
        self._max_postings = 30 + len(self.tokens) // 200  # частые слова («что», «это») не голосуют

    # ---------- 1–2: кандидаты ----------

    def _starts(self, toks: list[str]) -> list[int]:
        votes: dict[int, float] = defaultdict(float)
        for k, t in enumerate(toks):
            if len(t) < 3:
                continue
            posting = self._exact.get(t, [])
            if len(t) >= 5:
                posting = sorted(set(posting) | set(self._prefix.get(t[:4], [])))
            if not posting or len(posting) > self._max_postings:
                continue
            weight = 1.0 / math.log(2 + len(posting))
            for pos in posting:
                votes[pos - k] += weight
        # Соседние позиции — одна и та же находка: сглаживаем окном ±2.
        ranked = sorted(votes, key=lambda s: -sum(votes.get(s + d, 0) for d in range(-2, 3)))
        picked: list[int] = []
        for s in ranked:
            if all(abs(s - p) > 2 for p in picked):
                picked.append(s)
            if len(picked) == self.cfg.candidates_per_line:
                break
        return picked

    def _refine(self, li: int, lo: int, hi: int, min_conf: float) -> Match | None:
        lo, hi = max(0, lo), min(len(self.tokens), hi)
        res = local_align(self.line_tokens[li], self.tokens[lo:hi], self.cfg)
        if res is None:
            return None
        a, b, _, f1 = res
        if f1 < min_conf:
            return None
        return Match(li, lo + a, lo + b, round(f1, 3))

    def candidates(self) -> list[Match]:
        out: list[Match] = []
        for li, toks in enumerate(self.line_tokens):
            pad = max(3, len(toks) // 2)
            seen: set[tuple[int, int]] = set()
            for s in self._starts(toks):
                m = self._refine(li, s - pad, s + len(toks) + pad, self.cfg.min_confidence)
                if m and (m.start, m.end) not in seen:
                    seen.add((m.start, m.end))
                    out.append(m)
        return out

    # ---------- 3–4: выбор ----------

    def select(self) -> dict[int, Match]:
        used = [False] * len(self.tokens)
        chosen: dict[int, Match] = {}

        def free(m: Match) -> bool:
            return not any(used[m.start:m.end])

        def take(m: Match) -> None:
            chosen[m.line] = m
            for p in range(m.start, m.end):
                used[p] = True

        n_lines = max(1, len(self.lines))
        n_tok = max(1, len(self.tokens))

        def key(m: Match) -> tuple[float, float]:
            # Надёжность: точность × длина (до 8 слов). При равенстве — ближе к ожидаемой позиции.
            expected = m.line / n_lines * n_tok
            return (-m.confidence * min(len(self.line_tokens[m.line]), 8), abs(m.start - expected))

        for m in sorted(self.candidates(), key=key):
            if m.line not in chosen and free(m):
                take(m)

        # Короткие и не найденные реплики — в промежутке между найденными соседями.
        changed = True
        while changed:
            changed = False
            for li in range(len(self.lines)):
                if li in chosen or not self.line_tokens[li]:
                    continue
                prev = next((chosen[k] for k in range(li - 1, -1, -1) if k in chosen), None)
                nxt = next((chosen[k] for k in range(li + 1, len(self.lines)) if k in chosen), None)
                lo = prev.end if prev else (nxt.start - self.cfg.max_gap_tokens if nxt else None)
                hi = nxt.start if nxt else (prev.end + self.cfg.max_gap_tokens if prev else None)
                if lo is None or hi is None or hi <= lo or hi - lo > self.cfg.max_gap_tokens:
                    continue
                # Внутри промежутка — только свободные токены, по самому длинному свободному отрезку.
                for a, b in _free_runs(used, max(0, lo), min(len(self.tokens), hi)):
                    m = self._refine(li, a, b, self.cfg.min_gap_confidence)
                    if m and free(m):
                        take(m)
                        changed = True
                        break
        return chosen

    # ---------- 5: реплики ----------

    def replicas(self) -> tuple[list[dict[str, Any]], dict[str, int]]:
        chosen = self.select()
        word_line: dict[int, int] = {}
        for m in chosen.values():
            for p in range(m.start, m.end):
                word_line[self.token_word[p]] = m.line
        out: list[dict[str, Any]] = []
        for li, m in chosen.items():
            ws = sorted({self.token_word[p] for p in range(m.start, m.end)})
            ws = list(range(ws[0], ws[-1] + 1))  # вставки внутри реплики тоже её часть
            ln = self.lines[li]
            out.append({
                "start_ms": self.words[ws[0]].start_ms,
                "end_ms": max(self.words[ws[-1]].end_ms, self.words[ws[0]].start_ms),
                "role": ln.role,
                "text": ln.text,
                "spoken_text": _join(self.words[w].text for w in ws),
                "script_line_id": ln.line_id,
                "confidence": m.confidence,
                "matched": True,
            })
            for w in ws:
                word_line.setdefault(w, li)

        # Несопоставленная речь: подряд идущие слова без пауз — одна реплика (FR-TA5).
        group: list[int] = []
        unmatched = 0

        def flush() -> None:
            nonlocal unmatched
            if not group:
                return
            ws = [self.words[i] for i in group]
            probs = [w.probability for w in ws if w.probability is not None]
            text = _join(w.text for w in ws)
            rep: dict[str, Any] = {"start_ms": ws[0].start_ms, "end_ms": max(ws[-1].end_ms, ws[0].start_ms),
                                   "role": None, "text": text, "spoken_text": text,
                                   "script_line_id": None, "matched": False}
            if probs:
                rep["confidence"] = round(min(1.0, max(0.0, sum(probs) / len(probs))), 3)
            out.append(rep)
            unmatched += 1
            group.clear()

        for wi, w in enumerate(self.words):
            if wi in word_line or not tokenize(w.text):
                flush()
                continue
            if group:
                last = self.words[group[-1]]
                if w.segment != last.segment or w.start_ms - last.end_ms > self.cfg.pause_ms:
                    flush()
            group.append(wi)
        flush()

        out.sort(key=lambda r: (r["start_ms"], r["end_ms"]))
        dialogue = sum(1 for t in self.line_tokens if t)
        stats = {"script_lines": dialogue, "matched_lines": len(chosen), "unmatched_speech": unmatched,
                 "words": len(self.words)}
        return out, stats


def _free_runs(used: list[bool], lo: int, hi: int) -> list[tuple[int, int]]:
    runs, start = [], None
    for p in range(lo, hi):
        if not used[p] and start is None:
            start = p
        elif used[p] and start is not None:
            runs.append((start, p))
            start = None
    if start is not None:
        runs.append((start, hi))
    return sorted(runs, key=lambda r: r[0] - r[1])


def _join(parts) -> str:
    return " ".join(" ".join(p.split()) for p in parts if p.strip())


def align(words: list[Word], lines: list[ScriptLine],
          cfg: AlignConfig | None = None) -> tuple[list[dict[str, Any]], dict[str, int]]:
    return Aligner(words, lines, cfg).replicas()
