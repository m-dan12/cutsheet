# cutsheet

Автоматическое составление монтажных листов игрового кино: по видео и сценарию `.docx`
система собирает черновик листа (сцены, таймкоды, план, описание, реплики по ролям),
человек проверяет его в клиенте и выгружает в Excel / Word / PDF.

Техническое задание: ТЗ v0.2 (в материалах проекта). Готово: **этап 0** (окружение одной
командой, события по Kafka, Scene Detection) и **этап 2** (диалоги): Script Parser размечает
сценарий через LLM, Transcription & Alignment распознаёт речь и сопоставляет её со сценарием,
Aggregator режет реплики по сценам и публикует `scene.ready-for-enrichment`.

## Структура

| Путь | Что там |
|---|---|
| `contracts/` | JSON Schema событий Kafka, реестр топиков, примеры, контрактные тесты |
| `deploy/` | `docker-compose.yml` (Kafka KRaft, PostgreSQL, MinIO, Kong, сервисы), `kong/kong.yml` |
| `db/migrations/` | SQL-миграции PostgreSQL (схема из ТЗ 6.1) |
| `libs/python/cutsheet-common` | общий код Python-сервисов: конверт, проверка контрактов, адаптер Kafka, S3, логи |
| `libs/python/llm-client` | общий слой LLM: OpenAI-совместимый API (Ollama / vLLM / внешний), JSON по схеме с повтором |
| `services/scene-detection` | **работает**: PySceneDetect, ключевые кадры в S3 |
| `services/script-parser` | **работает**: `.docx` → сцены, роли, реплики (LLM или эвристики) |
| `services/transcription` | **работает**: faster-whisper / WhisperX, нечёткое сопоставление со сценарием |
| `services/aggregator` | C#: join сцен и диалогов в PostgreSQL, нарезка реплик по сценам; тесты — `services/aggregator-tests` |
| `services/auth`, `project-api` | C# (.NET 10): каркасы с healthcheck |
| `services/shot-type`, `scene-description`, `export` | Python, заглушки (README с контрактом) |
| `client/` | Flutter Desktop (заглушка, этап 1) |
| `tools/` | тестовый ролик и сквозная проверка без клиента |

## Быстрый старт

Нужны Docker с Compose v2, Python 3.12 и ffmpeg (для тестового ролика).

```sh
cp deploy/.env.example deploy/.env   # по желанию: свои пароли
make up                              # всё окружение
make dev-install                     # зависимости для тестов и tools/ (лучше в venv)
make e2e                             # ролик → video.uploaded → scenes.detected → project.status-changed
make e2e-dialogues                   # + сценарий → script.parsed → dialogue.aligned → scene.ready-for-enrichment
make test                            # контрактные и unit-тесты
```

**LLM для Script Parser.** По умолчанию сервис ходит в Ollama на хосте
(`http://host.docker.internal:11434/v1`, модель `qwen2.5:7b-instruct`): установите Ollama и
выполните `ollama pull qwen2.5:7b-instruct`. Либо поднимите Ollama в compose:
`docker compose -f deploy/docker-compose.yml --profile llm up -d` с `LLM_BASE_URL=http://ollama:11434/v1`
в `deploy/.env`. Без LLM — `SP_MODE=rules` (эвристики). Внешний API — тот же `LLM_BASE_URL`,
`LLM_MODEL`, `LLM_API_KEY`.

**Распознавание речи.** По умолчанию CPU-образ с faster-whisper, модель `small` скачивается
при первом ролике в том `whisper-models`. С GPU: `TA_EXTRAS=whisperx TA_BACKEND=whisperx TA_MODEL=large-v3`.

**Миграции** применяются только к пустому тому PostgreSQL. Если окружение уже поднималось
на этапе 0: `make down && docker volume rm cutsheet_pg-data && make up` (данные БД удалятся)
или примените `db/migrations/0002_*.sql` вручную через `psql`.

| Адрес | Что |
|---|---|
| http://localhost:8000/api/v1/health | Project API через Kong |
| http://localhost:8000/api/v1/auth/.well-known/jwks.json | Auth Service через Kong |
| http://localhost:9001 | консоль MinIO (`cutsheet` / `cutsheet-secret`) |
| `localhost:9094` | Kafka для хоста; внутри сети compose — `kafka:9092` |
| `localhost:5432` | PostgreSQL (`cutsheet` / `cutsheet`) |

## Как устроен сервис

Бизнес-логика Python-сервиса — функция `Event -> list[Event]`. Адаптер
`cutsheet_common.bus.KafkaBus` читает топик, проверяет событие по контракту, вызывает
обработчик, публикует результат (тоже с проверкой) и только после этого фиксирует
смещение. Если обработчик упал, публикуется `pipeline.failed`. Python-сервисы в БД
не ходят: идемпотентность за счёт детерминированных ключей S3 и `event_id`,
выведенного из входного события.

## Решения v0.2, которые ждут подтверждения

1. **Export без доступа к БД** — Project API кладёт снимок листа в S3, Export Service
   отвечает `export.completed` / `export.failed`. Затрагивает только
   `contracts/schemas/events/export.*.v1.json` и `services/export`.
2. **Топик `project.status-changed`** (Aggregator → Project API → SignalR). Затрагивает
   `contracts/schemas/events/project.status-changed.v1.json` и обработчик в `services/aggregator`.
