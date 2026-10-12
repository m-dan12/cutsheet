# llm-client

Общий слой доступа к LLM (ТЗ 5.10) для Script Parser и Scene Description.

- Клиент OpenAI-совместимого Chat Completions API на `httpx`: Ollama, vLLM или внешний
  провайдер переключаются только переменными окружения (FR-LLM1, FR-LLM2).
- `complete_json(messages, schema, prompt_version=..., check=...)` — структурированный вывод
  (FR-LLM3): `response_format` с JSON-схемой (если сервер не умеет — `json_object`), разбор JSON
  из ответа, проверка схемой и функцией `check`; при ошибке модель получает текст ошибки
  и отвечает ещё раз, после `attempts` попыток — `LLMInvalidOutput`.
- Повторы транспорта (таймаут, 429, 5xx) с экспоненциальной задержкой; ограничение
  параллелизма запросов (локальная модель упирается в GPU).
- Мультимодальные запросы: `image_part(jpeg_bytes)` — кадр как content part.
- В лог пишутся модель, версия промпта, длительность и токены; содержимое — нет (FR-LLM4).
- `llm_client.testing.FakeLLMServer` — сервер в памяти для тестов сервисов, без сети и модели.

| Переменная | По умолчанию | |
|---|---|---|
| `LLM_BASE_URL` | `http://localhost:11434/v1` | Ollama; vLLM — `http://host:8000/v1` |
| `LLM_MODEL` | `qwen2.5:7b-instruct` | |
| `LLM_API_KEY` | `ollama` | для внешнего API — ключ провайдера |
| `LLM_TIMEOUT_S` | 300 | таймаут запроса |
| `LLM_MAX_RETRIES`, `LLM_BACKOFF_S` | 3, 2.0 | повторы транспорта |
| `LLM_STRUCTURED` | `json_schema` | `json_schema`, `json_object` или `none` |
| `LLM_TEMPERATURE` | 0 | |
| `LLM_MAX_CONCURRENCY` | 2 | одновременных запросов из процесса |
| `LLM_RATE_LIMIT_RPM` | 0 | запросов в минуту из процесса (внешний API); 0 — без лимита |
| `LLM_BREAKER_FAILURES` | 5 | неудачных вызовов подряд, после которых цепь размыкается |
| `LLM_BREAKER_COOLDOWN_S` | 60 | пауза разомкнутой цепи до пробного вызова |

Circuit breaker (FR-SDS4): вызов, который не удался после всех повторов транспорта, считается
неудачным; после `LLM_BREAKER_FAILURES` таких подряд следующие вызовы сразу получают
`LLMCircuitOpen`, пока не пройдёт `LLM_BREAKER_COOLDOWN_S`. Ошибки запроса (4xx кроме 429)
цепь не размыкают.
