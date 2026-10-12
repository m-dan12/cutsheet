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
    rate_limit_rpm: float = 0.0                   # запросов в минуту из процесса; 0 — без лимита (внешний API)
    breaker_failures: int = 5                     # подряд неудачных вызовов до размыкания (circuit breaker)
    breaker_cooldown_s: float = 60.0              # сколько цепь разомкнута до пробного вызова
    # Цена за 1000 токенов (внешний API) для метрики стоимости; у локальной модели 0.
    price_prompt_per_1k: float = 0.0
    price_completion_per_1k: float = 0.0

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
            rate_limit_rpm=float(e("RATE_LIMIT_RPM", str(cls.rate_limit_rpm))),
            breaker_failures=int(e("BREAKER_FAILURES", str(cls.breaker_failures))),
            breaker_cooldown_s=float(e("BREAKER_COOLDOWN_S", str(cls.breaker_cooldown_s))),
            price_prompt_per_1k=float(e("PRICE_PROMPT_PER_1K", str(cls.price_prompt_per_1k))),
            price_completion_per_1k=float(e("PRICE_COMPLETION_PER_1K", str(cls.price_completion_per_1k))),
        )
