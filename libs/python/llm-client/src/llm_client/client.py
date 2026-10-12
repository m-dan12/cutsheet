"""Клиент OpenAI-совместимого Chat Completions API (Ollama, vLLM, внешний провайдер).

- Повторы транспорта: таймаут, 429 и 5xx, экспоненциальная задержка.
- Структурированный вывод (FR-LLM3): ответ разбирается как JSON и проверяется по
  JSON-схеме; при ошибке модель получает текст ошибки и отвечает ещё раз.
- Ограничение параллелизма: локальная модель упирается в одну GPU.
- В лог попадают модель, версия промпта, длительность и токены, но не содержимое (FR-LLM4).
"""

from __future__ import annotations

import base64
import json
import logging
import re
import threading
import time
from dataclasses import dataclass, field
from typing import Any, Callable

import httpx
from jsonschema import Draft202012Validator

from .config import LLMConfig

log = logging.getLogger("cutsheet.llm")

Message = dict[str, Any]


class LLMError(RuntimeError):
    """LLM недоступна или отвечает ошибкой после всех повторов."""


class LLMInvalidOutput(LLMError):
    """Модель так и не вернула ответ, проходящий проверку."""


@dataclass
class ChatResult:
    text: str
    duration_ms: int
    usage: dict[str, int] = field(default_factory=dict)


def image_part(data: bytes, mime: str = "image/jpeg") -> dict[str, Any]:
    """Кадр для мультимодального запроса (content part в формате OpenAI)."""
    b64 = base64.b64encode(data).decode("ascii")
    return {"type": "image_url", "image_url": {"url": f"data:{mime};base64,{b64}"}}


_FENCE = re.compile(r"^```(?:json)?\s*(.*?)\s*```$", re.S)


def parse_json(text: str) -> Any:
    """JSON из ответа модели: снимает ```-ограждение и текст вокруг объекта."""
    s = text.strip()
    m = _FENCE.match(s)
    if m:
        s = m.group(1)
    try:
        return json.loads(s)
    except json.JSONDecodeError:
        start, end = s.find("{"), s.rfind("}")
        if start == -1 or end <= start:
            raise
        return json.loads(s[start:end + 1])


class LLMClient:
    def __init__(self, config: LLMConfig | None = None, *, transport: httpx.BaseTransport | None = None,
                 sleep: Callable[[float], None] = time.sleep):
        self.config = config or LLMConfig.from_env()
        self._http = httpx.Client(base_url=self.config.base_url, transport=transport,
                                  timeout=httpx.Timeout(self.config.timeout_s, connect=10.0),
                                  headers={"Authorization": f"Bearer {self.config.api_key}"})
        self._sem = threading.BoundedSemaphore(max(1, self.config.max_concurrency))
        self._sleep = sleep
        self._structured = self.config.structured

    def close(self) -> None:
        self._http.close()

    # ---------- низкий уровень ----------

    def chat(self, messages: list[Message], *, prompt_version: str,
             response_format: dict[str, Any] | None = None, **params: Any) -> ChatResult:
        body: dict[str, Any] = {"model": self.config.model, "messages": messages,
                                "temperature": self.config.temperature, "stream": False, **params}
        if response_format:
            body["response_format"] = response_format
        cfg = self.config
        last: Exception | None = None
        for attempt in range(cfg.max_retries + 1):
            if attempt:
                self._sleep(cfg.backoff_s * 2 ** (attempt - 1))
            started = time.monotonic()
            try:
                with self._sem:
                    resp = self._http.post("/chat/completions", json=body)
            except httpx.TransportError as e:  # таймаут, обрыв, нет соединения
                last = e
                log.warning("llm transport error model=%s prompt=%s attempt=%d: %s",
                            cfg.model, prompt_version, attempt + 1, type(e).__name__)
                continue
            duration_ms = round((time.monotonic() - started) * 1000)
            if resp.status_code == 429 or resp.status_code >= 500:
                last = LLMError(f"HTTP {resp.status_code}")
                log.warning("llm http %d model=%s prompt=%s attempt=%d",
                            resp.status_code, cfg.model, prompt_version, attempt + 1)
                continue
            if resp.status_code >= 400:
                raise LLMError(f"HTTP {resp.status_code}: {resp.text[:500]}")
            data = resp.json()
            usage = {k: v for k, v in (data.get("usage") or {}).items() if isinstance(v, int)}
            log.info("llm call model=%s prompt=%s duration_ms=%d prompt_tokens=%s completion_tokens=%s",
                     cfg.model, prompt_version, duration_ms, usage.get("prompt_tokens"),
                     usage.get("completion_tokens"))
            text = data["choices"][0]["message"].get("content") or ""
            return ChatResult(text=text, duration_ms=duration_ms, usage=usage)
        raise LLMError(f"LLM unavailable after {cfg.max_retries + 1} attempts: {last}")

    # ---------- структурированный вывод ----------

    def _response_format(self, schema: dict[str, Any], name: str) -> dict[str, Any] | None:
        if self._structured == "json_schema":
            return {"type": "json_schema", "json_schema": {"name": name, "schema": schema, "strict": False}}
        if self._structured == "json_object":
            return {"type": "json_object"}
        return None

    def complete_json(self, messages: list[Message], schema: dict[str, Any], *, prompt_version: str,
                      name: str = "result", check: Callable[[Any], None] | None = None,
                      attempts: int = 3) -> Any:
        """Ответ модели как JSON, прошедший схему и проверку `check` (бросает ValueError).

        При невалидном ответе модель получает свой ответ и список ошибок и пробует ещё раз
        (FR-SP4); после `attempts` попыток — LLMInvalidOutput.
        """
        validator = Draft202012Validator(schema)
        convo = list(messages)
        error = ""
        for attempt in range(attempts):
            try:
                result = self.chat(convo, prompt_version=prompt_version,
                                   response_format=self._response_format(schema, name))
            except LLMError as e:
                # Сервер не умеет json_schema (старый Ollama, часть провайдеров) — пробуем проще.
                if self._structured == "json_schema" and "HTTP 4" in str(e):
                    log.warning("response_format json_schema rejected, falling back to json_object")
                    self._structured = "json_object"
                    result = self.chat(convo, prompt_version=prompt_version,
                                       response_format=self._response_format(schema, name))
                else:
                    raise
            try:
                value = parse_json(result.text)
                errors = sorted(validator.iter_errors(value), key=lambda e: list(e.absolute_path))
                if errors:
                    raise ValueError("; ".join(
                        f"{'/'.join(map(str, e.absolute_path)) or '<root>'}: {e.message}" for e in errors[:5]))
                if check:
                    check(value)
                return value
            except ValueError as e:  # JSONDecodeError — тоже ValueError
                error = str(e)[:1000]
                log.warning("llm invalid output prompt=%s attempt=%d/%d: %s",
                            prompt_version, attempt + 1, attempts, error[:200])
                convo = [*messages, {"role": "assistant", "content": result.text},
                         {"role": "user", "content":
                             "Ответ не прошёл проверку: " + error +
                             "\nИсправь и верни только JSON по той же схеме, без пояснений."}]
        raise LLMInvalidOutput(f"invalid LLM output after {attempts} attempts: {error}")
