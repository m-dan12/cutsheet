import json

import pytest

from llm_client import LLMInvalidOutput
from llm_client.testing import FakeLLMServer
from script_parser import rules
from script_parser.docx_reader import read_docx
from script_parser.labels import assemble
from script_parser.llm import PROMPT_VERSION, chunks, label_with_llm


def oracle(paragraphs):
    """«Модель», которая размечает так же, как эвристики, и видит только свой чанк."""
    truth = {p.i: lab for p, lab in zip(paragraphs, rules.classify(paragraphs))}

    def reply(body):
        user = body["messages"][-1]["content"]
        nums = [int(ln.split("]")[0].lstrip("\n[")) for ln in user.split("Абзацы:\n", 1)[1].splitlines()
                if ln.startswith("[")]
        return json.dumps({"labels": [{"p": n, "type": truth[n].type, "role": truth[n].role} for n in nums]},
                          ensure_ascii=False)
    return reply


def test_llm_labels_in_chunks_carry_roles(sample_docx):
    ps = read_docx(sample_docx)
    srv = FakeLLMServer(oracle(ps))
    labels = label_with_llm(srv.client(), ps, max_chars=250)
    assert len(srv.requests) == len(chunks(ps, 250)) > 2
    scenes, roles = assemble(ps, labels)
    expected, _ = assemble(ps, rules.classify(ps))
    assert scenes == expected and roles.names == ["МАША", "ИВАН", "ПРОВОДНИК"]
    # Роли из прошлых чанков передаются в следующие (FR-SP3).
    assert "Известные роли: МАША" in srv.requests[-1]["messages"][-1]["content"]
    assert srv.requests[0]["response_format"]["json_schema"]["name"] == "script_labels"


def test_llm_missing_paragraph_is_retried(sample_docx):
    ps = read_docx(sample_docx)[:3]
    full = {"labels": [{"p": 0, "type": "heading"}, {"p": 1, "type": "action"},
                       {"p": 2, "type": "character", "role": "МАША"}]}
    partial = {"labels": full["labels"][:2]}
    srv = FakeLLMServer([json.dumps(partial), json.dumps(full)])
    labels = label_with_llm(srv.client(), ps)
    assert [lab.type for lab in labels] == ["heading", "action", "character"]
    assert "пропущены: [2]" in srv.requests[1]["messages"][-1]["content"]


def test_llm_gives_up_after_retries(sample_docx):
    ps = read_docx(sample_docx)[:2]
    srv = FakeLLMServer(['{"labels": []}'] * 3)
    with pytest.raises(LLMInvalidOutput):
        label_with_llm(srv.client(), ps)
    assert PROMPT_VERSION == "script-labels-v1"
