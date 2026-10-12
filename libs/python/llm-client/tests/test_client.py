import logging

import pytest

from llm_client import LLMCircuitOpen, LLMError, LLMInvalidOutput, image_part
from llm_client.client import parse_json
from llm_client.config import LLMConfig
from llm_client.testing import FakeLLMServer

SCHEMA = {"type": "object", "required": ["n"], "properties": {"n": {"type": "integer"}}}


def test_parse_json_strips_fences_and_chatter():
    assert parse_json('```json\n{"n": 1}\n```') == {"n": 1}
    assert parse_json('Вот ответ: {"n": 2} Надеюсь, помог.') == {"n": 2}
    with pytest.raises(ValueError):
        parse_json("нет json")


def test_complete_json_sends_schema_and_returns_value():
    srv = FakeLLMServer(['{"n": 5}'])
    assert srv.client().complete_json([{"role": "user", "content": "x"}], SCHEMA, prompt_version="t-1") == {"n": 5}
    req = srv.requests[0]
    assert req["model"] == "fake" and req["temperature"] == 0
    assert req["response_format"]["type"] == "json_schema"
    assert req["response_format"]["json_schema"]["schema"] == SCHEMA


def test_invalid_output_is_retried_with_error_text():
    srv = FakeLLMServer(['{"n": "пять"}', "мусор", '{"n": 5}'])
    assert srv.client().complete_json([{"role": "user", "content": "x"}], SCHEMA, prompt_version="t") == {"n": 5}
    retry = srv.requests[1]["messages"]
    assert retry[-2] == {"role": "assistant", "content": '{"n": "пять"}'}
    assert "не прошёл проверку" in retry[-1]["content"] and "n" in retry[-1]["content"]


def test_semantic_check_failure_is_retried_then_gives_up():
    def check(v):
        if v["n"] < 10:
            raise ValueError("n должно быть ≥ 10")

    srv = FakeLLMServer(['{"n": 1}'] * 3)
    with pytest.raises(LLMInvalidOutput, match="≥ 10"):
        srv.client().complete_json([{"role": "user", "content": "x"}], SCHEMA, prompt_version="t", check=check)
    assert len(srv.requests) == 3


def test_transport_errors_are_retried():
    srv = FakeLLMServer([503, 429, '{"n": 1}'])
    assert srv.client().complete_json([{"role": "user", "content": "x"}], SCHEMA, prompt_version="t") == {"n": 1}
    srv = FakeLLMServer([500] * 4)
    with pytest.raises(LLMError, match="unavailable"):
        srv.client(max_retries=3).chat([], prompt_version="t")


def test_falls_back_to_json_object_when_schema_unsupported():
    srv = FakeLLMServer([400, '{"n": 1}', '{"n": 2}'])
    c = srv.client()
    assert c.complete_json([], SCHEMA, prompt_version="t") == {"n": 1}
    assert srv.requests[1]["response_format"] == {"type": "json_object"}
    c.complete_json([], SCHEMA, prompt_version="t")
    assert srv.requests[2]["response_format"] == {"type": "json_object"}


def test_logs_metadata_but_not_content(caplog):
    srv = FakeLLMServer(['{"n": 1}'])
    with caplog.at_level(logging.INFO, logger="cutsheet.llm"):
        srv.client().complete_json([{"role": "user", "content": "СЕКРЕТНЫЙ СЦЕНАРИЙ"}], SCHEMA,
                                   prompt_version="script-v7")
    text = caplog.text
    assert "script-v7" in text and "prompt_tokens=10" in text and "model=fake" in text
    assert "СЕКРЕТНЫЙ" not in text


def test_image_part_is_data_url():
    part = image_part(b"\xff\xd8jpeg")
    assert part["type"] == "image_url" and part["image_url"]["url"].startswith("data:image/jpeg;base64,")


def test_config_from_env(monkeypatch):
    monkeypatch.setenv("LLM_BASE_URL", "http://vllm:8000/v1/")
    monkeypatch.setenv("LLM_MODEL", "Qwen2.5-VL-7B")
    monkeypatch.setenv("LLM_MAX_CONCURRENCY", "4")
    cfg = LLMConfig.from_env()
    assert (cfg.base_url, cfg.model, cfg.max_concurrency) == ("http://vllm:8000/v1", "Qwen2.5-VL-7B", 4)


class FakeClock:
    def __init__(self):
        self.now = 1000.0
        self.slept: list[float] = []

    def __call__(self) -> float:
        return self.now

    def sleep(self, s: float) -> None:
        self.slept.append(s)
        self.now += s


def test_circuit_opens_after_failed_calls_and_recovers_after_cooldown():
    clock = FakeClock()
    srv = FakeLLMServer([500, 500, 500, 500, '{"n": 1}', '{"n": 2}'])
    c = srv.client(clock=clock, sleep=clock.sleep, max_retries=1, breaker_failures=2, breaker_cooldown_s=30)
    for _ in range(2):
        with pytest.raises(LLMError, match="unavailable"):
            c.chat([], prompt_version="t")
    with pytest.raises(LLMCircuitOpen):
        c.chat([], prompt_version="t")
    assert len(srv.requests) == 4  # разомкнутая цепь не ходит в сеть
    clock.now += 31
    assert c.chat([], prompt_version="t").text == '{"n": 1}'  # пробный вызов удался — цепь замкнута
    assert c.chat([], prompt_version="t").text == '{"n": 2}'


def test_client_errors_do_not_open_circuit():
    srv = FakeLLMServer([400, 400, '{"n": 1}'])
    c = srv.client(breaker_failures=1)
    for _ in range(2):
        with pytest.raises(LLMError, match="HTTP 400"):
            c.chat([], prompt_version="t")
    assert c.chat([], prompt_version="t").text == '{"n": 1}'


def test_rate_limit_spaces_requests():
    clock = FakeClock()
    srv = FakeLLMServer(['{"n": 1}'] * 3)
    c = srv.client(clock=clock, sleep=clock.sleep, rate_limit_rpm=30)
    for _ in range(3):
        c.chat([], prompt_version="t")
    assert clock.slept == [2.0, 2.0]
