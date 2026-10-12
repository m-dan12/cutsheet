# Scene Description

Описание плана для графы «Описание» по ключевым кадрам (ТЗ 5.8).

- Читает: `script.parsed` (сохраняет индекс сценария в S3 для контекста) и `scene.ready-for-enrichment`
- Публикует: `scene.enriched` (`source = description`, `prompt_version`, `model`, `request_event_id`),
  при невосстановимой ошибке — `pipeline.failed`
- LLM — через общий слой `libs/python/llm-client` (OpenAI-совместимый API: Ollama, vLLM, внешний провайдер)

## Как строится описание

В мультимодальную модель идут до `SDS_MAX_FRAMES` ключевых кадров (уменьшенных до
`SDS_FRAME_MAX_SIDE`), реплики плана и фрагмент сценария: заголовок и ремарки сцен сценария,
к которым относятся реплики по `script_line_id` (FR-SDS1). Ответ — JSON `{"description": "..."}`;
он проверяется (FR-SDS2): 1–3 предложения, не длиннее 400 символов, по-русски, без цитат реплик
(5 слов реплики подряд). Если проверка не прошла, модель получает текст ошибки и отвечает ещё
раз; после трёх попыток сцена получает `pipeline.failed`, и Aggregator помечает её
`enrichment_failed` — проект остаётся пригодным к ручному ревью.

Промпт лежит в `src/scene_description/prompts/<версия>.txt`; версия (имя файла) пишется в
результат (FR-SDS3). Новый промпт — новый файл и `SDS_PROMPT`, без правки кода; свой файл — `SDS_PROMPT_FILE`.

Таймауты, повторы с backoff, circuit breaker, rate limit и ограничение параллелизма (FR-SDS4) —
в `llm-client`, переменные `LLM_*` (см. его README).

## Модель

По умолчанию — локальная мультимодальная модель в Ollama: `qwen2.5vl:7b`
(`ollama pull qwen2.5vl:7b`, около 6 ГБ; на 8 ГБ VRAM работает, на CPU — медленно).
Внешняя модель — только переменными: `SDS_LLM_BASE_URL`, `SDS_LLM_MODEL`, `SDS_LLM_API_KEY`
в `deploy/.env` (compose передаёт их сервису как `LLM_*`). Сравнение локальной и внешней модели
на эталонных кадрах — `tools/compare_descriptions.py`.

| Переменная | По умолчанию | |
|---|---|---|
| `SDS_MODE` | `llm` | `stub` — без LLM, описание-заглушка (CI, офлайн) |
| `SDS_PROMPT` | `scene-description-v1` | промпт из `prompts/` |
| `SDS_PROMPT_FILE` | — | свой промпт; версия — имя файла |
| `SDS_MAX_FRAMES` | 3 | кадров в запросе |
| `SDS_FRAME_MAX_SIDE` | 768 | размер кадра, пикселей по большей стороне |
| `SDS_MAX_CONTEXT_CHARS` | 1500 | реплики и сценарий в запросе |
