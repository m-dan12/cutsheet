from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class LLMConfig:
    """Настройки из окружения (FR-LLM1). Локальная или внешняя модель — только конфигурацией (FR-LLM2)."""

    base_url: str = "http://localhost:11434/v1"   # Ollama; vLLM — http://host:8000/v1
    model: str = "qwen2.5:7b-instruct"
    api_key: str = "ollama"                       # Ollama ключ не проверяет, но заголовок нужен
    timeout_s: float = 300.0
    max_retries: int = 3                          # повторы транспорта: таймаут, 429, 5xx
    backoff_s: float = 2.0
    # Как просить JSON: json_schema (Ollama ≥ 0.5, vLLM, OpenAI), json_object или none.
    structured: str = "json_schema"
    temperature: float = 0.0
    max_concurrency: int = 2                      # локальная модель упирается в GPU

    @classmethod
    def from_env(cls, prefix: str = "LLM_") -> "LLMConfig":
        e = lambda k, d: os.environ.get(prefix + k, d)  # noqa: E731
        return cls(
            base_url=e("BASE_URL", cls.base_url).rstrip("/"),
            model=e("MODEL", cls.model),
            api_key=e("API_KEY", cls.api_key),
            timeout_s=float(e("TIMEOUT_S", str(cls.timeout_s))),
            max_retries=int(e("MAX_RETRIES", str(cls.max_retries))),
            backoff_s=float(e("BACKOFF_S", str(cls.backoff_s))),
            structured=e("STRUCTURED", cls.structured),
            temperature=float(e("TEMPERATURE", str(cls.temperature))),
            max_concurrency=int(e("MAX_CONCURRENCY", str(cls.max_concurrency))),
        )
