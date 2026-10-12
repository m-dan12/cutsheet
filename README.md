# cutsheet

Автоматическое составление монтажных листов игрового кино: по видео и сценарию `.docx`
система собирает черновик листа (сцены, таймкоды, план, описание, реплики по ролям),
человек проверяет его в клиенте и выгружает в Excel / Word / PDF.

Техническое задание: ТЗ v0.2 (в материалах проекта). Сейчас репозиторий на **этапе 0**:
окружение поднимается одной командой, события ходят по Kafka, первый сервис
(Scene Detection) работает от загрузки видео до события `scenes.detected`.

## Структура

| Путь | Что там |
|---|---|
| `contracts/` | JSON Schema событий Kafka, реестр топиков, примеры, контрактные тесты |
| `deploy/` | `docker-compose.yml` (Kafka KRaft, PostgreSQL, MinIO, Kong, сервисы), `kong/kong.yml` |
| `db/migrations/` | SQL-миграции PostgreSQL (схема из ТЗ 6.1) |
| `libs/python/cutsheet-common` | общий код Python-сервисов: конверт, проверка контрактов, адаптер Kafka, S3, логи |
| `libs/python/llm-client` | общий слой LLM (заглушка, этап 2) |
| `services/scene-detection` | **работает**: PySceneDetect, ключевые кадры в S3 |
| `services/auth`, `project-api`, `aggregator` | C# (.NET 10): каркасы с healthcheck; Aggregator уже читает `scenes.detected` |
| `services/transcription`, `script-parser`, `shot-type`, `scene-description`, `export` | Python, заглушки (README с контрактом) |
| `client/` | Flutter Desktop (заглушка, этап 1) |
| `tools/` | тестовый ролик и сквозная проверка без клиента |

## Быстрый старт

Нужны Docker с Compose v2, Python 3.12 и ffmpeg (для тестового ролика).

```sh
cp deploy/.env.example deploy/.env   # по желанию: свои пароли
make up                              # всё окружение
make dev-install                     # зависимости для тестов и tools/ (лучше в venv)
make e2e                             # ролик → video.uploaded → scenes.detected → project.status-changed
make test                            # контрактные и unit-тесты
```

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
