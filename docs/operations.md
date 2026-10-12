# Эксплуатация CutSheet (этап 6)

Что сделано на этапе 6 по ТЗ v0.2 (разделы 4.3, 7, 8, 10, 11): повторы и DLQ во всех
потребителях Kafka, идемпотентность, метрики Prometheus и дашборд Grafana, трейсинг
OpenTelemetry в Jaeger, структурные логи, healthcheck, оповещения, нагрузочный тест,
резервное копирование PostgreSQL и порядок подбора порогов на реальных фильмах.

## Запуск

```sh
make up-obs        # всё окружение + Prometheus, Grafana, Jaeger, kafka-exporter
make e2e-ops OBS=1 # проверить DLQ, повторы, метрики и трейсы
make load-test N=5 # 5 проектов параллельно до ready_for_review
make dlq-list      # что лежит в DLQ
make db-backup     # резервная копия PostgreSQL с проверкой восстановления
```

| Адрес | Что |
|---|---|
| http://localhost:3000 | Grafana, дашборд «CutSheet — конвейер» открывается без входа (`admin` / `GRAFANA_ADMIN_PASSWORD` для правки) |
| http://localhost:9090 | Prometheus: запросы, цели (Status → Targets), оповещения (Alerts) |
| http://localhost:16686 | Jaeger: трейсы по сервисам |
| `<сервис>:9100/metrics`, `/health` | метрики и состояние Python-сервисов (внутри сети compose) |
| `<сервис>:8080/metrics`, `/health` | то же у Auth, Project API, Aggregator |

Стек наблюдаемости — профиль compose `observability`: обычный `make up` его не поднимает, а
трейсы без `OTEL_EXPORTER_OTLP_ENDPOINT` не отправляются (метрики и логи есть всегда).

## Повторы и DLQ

Общие правила (ТЗ 4.3) одинаковы в Python (`libs/python/cutsheet-common/.../bus.py`) и C#
(`libs/dotnet/Cutsheet.Messaging/EventConsumer.cs`):

| Ситуация | Что происходит |
|---|---|
| Сообщение не JSON / не проходит контракт | сразу в `<topic>.dlq` (`reason=invalid`), без повторов |
| Ошибка данных: Python — `ValueError`, `ContractError`, `PermanentError`; C# — `JsonException`, нет поля, не тот тип | сразу в DLQ (`reason=failed`, `attempts=1`) и `pipeline.failed` с `retryable=false` |
| Прочий сбой (S3, LLM, ошибка в коде) | до `KAFKA_MAX_ATTEMPTS` попыток (по умолчанию 3) с задержкой `KAFKA_RETRY_BACKOFF_S`·2ⁿ (2, 4, 8 … с, не больше 5 мин), затем DLQ и `pipeline.failed` |
| C#: PostgreSQL или Kafka недоступны | повтор без лимита с задержкой до минуты: событие корректно, терять его нельзя |

`pipeline.failed` после DLQ публикуют Python-сервисы и Aggregator (кроме сбоя на самом
`pipeline.failed`, чтобы не зациклиться); Aggregator переводит проект в `failed`, клиент видит
причину. Project API в DLQ только пишет: его статусы восстанавливаются следующим событием.
Смещение фиксируется после DLQ, поэтому одно битое сообщение не останавливает партицию.

В DLQ лежит исходное сообщение как есть, причина — в заголовках:

| Заголовок | Значение |
|---|---|
| `x-dlq-source-topic`, `x-dlq-partition`, `x-dlq-offset` | откуда сообщение |
| `x-dlq-service` | какой сервис не смог его обработать |
| `x-dlq-reason` | `invalid` или `failed` |
| `x-dlq-error` | тип и текст ошибки (до 2000 символов) |
| `x-dlq-attempts` | сколько было попыток |
| `x-dlq-failed-at` | время (UTC) |

DLQ-топики описаны в `contracts/topics.txt` (по одному на каждый топик, 1 партиция,
retention 30 суток, ТЗ 8) и создаются вместе с остальными.

### Разбор DLQ

1. Оповещение `CutsheetDeadLetters` или панель «Сообщения в DLQ» в Grafana.
2. `python tools/dlq.py list video.uploaded` — событие, проект, сервис, ошибка.
3. Логи сервиса по проекту:
   `docker compose -f deploy/docker-compose.yml logs scene-detection | grep '"project_id": "<id>"'`.
4. Исправить причину (файл в S3, модель, код) и вернуть сообщения:
   `python tools/dlq.py replay video.uploaded` (все, каждое один раз) или
   `--event-id <uuid>` (одно), `--dry-run` — посмотреть без отправки.

Возвращённое событие получат все группы исходного топика. Это безопасно: потребители
идемпотентны (ниже), а сервис, у которого событие упало, обработает его заново. Невалидные
сообщения не возвращаются — они упадут снова.

## Идемпотентность

| Где | Как |
|---|---|
| Python-сервисы | `event_id` результата выводится из `event_id` входа (`derive_event_id`), поэтому повтор даёт те же события; адаптер помнит последние 1000 обработанных `event_id` и не запускает долгий этап повторно на дубль (упавшие не запоминаются, чтобы replay сработал) |
| Aggregator | таблица `processed_events (consumer, event_id)` в той же транзакции, что и изменения; join и обогащение — со своей дедупликацией |
| Project API | обновление статуса проекта идемпотентно (последнее значение) |
| Продюсеры | `enable.idempotence` в Kafka: повтор отправки не создаёт дубль в топике |

## Метрики

Имена одинаковые у Python- и C#-сервисов, метка `service` — имя сервиса.

| Метрика | Что |
|---|---|
| `cutsheet_events_consumed_total{service,topic,outcome}` | прочитанные события: `ok`, `duplicate`, `failed`, `invalid` |
| `cutsheet_events_published_total{service,topic}` | опубликованные события |
| `cutsheet_handler_duration_seconds{service,event_type}` | длительность этапа (гистограмма, до 2 ч) |
| `cutsheet_handler_retries_total{service,topic}` | повторы обработки |
| `cutsheet_dlq_messages_total{service,topic,reason}` | отправлено в DLQ |
| `cutsheet_llm_requests_total{model,prompt,outcome}` | вызовы LLM: `ok`, `error`, `circuit_open` |
| `cutsheet_llm_tokens_total{model,kind}` | токены `prompt` / `completion` |
| `cutsheet_llm_cost_total{model}` | стоимость по ценам `LLM_PRICE_PROMPT_PER_1K` / `LLM_PRICE_COMPLETION_PER_1K` (локальная модель — 0) |
| `cutsheet_llm_request_duration_seconds{model}` | длительность HTTP-вызова LLM |
| `kafka_consumergroup_lag{consumergroup,topic}` | lag консьюмеров (kafka-exporter) |
| `kafka_topic_partition_current_offset{topic=~".*\\.dlq"}` | сколько всего сообщений в DLQ |
| `http_requests_received_total`, `http_request_duration_seconds` | HTTP у C#-сервисов (prometheus-net) |

Оповещения — `deploy/observability/alerts.yml`: сервис не отвечает, сообщения в DLQ, частые
повторы, растущий lag (30 мин подряд больше 20 сообщений: долгие этапы — норма), ошибки LLM.
Alertmanager не подключён: оповещения видны в Prometheus и Grafana.

## Логи

Все сервисы пишут JSON в stdout, по строке на запись. Python: `ts`, `level`, `service`,
`logger`, `msg`, `project_id`, `correlation_id`, `event_id`, при ошибке `exc`. C#: формат
`JsonConsole`, поля проекта — в `Scopes` (`project_id`, `correlation_id`, `event_id`).
Содержимое сценария и запросов к LLM в лог не попадает (FR-LLM4), только модель, версия
промпта, длительность и токены.

```sh
docker compose -f deploy/docker-compose.yml logs --no-log-prefix aggregator | jq 'select(.LogLevel == "Error")'
docker compose -f deploy/docker-compose.yml logs --no-log-prefix transcription | jq 'select(.project_id == "<id>")'
```

## Трейсинг

Контекст трейса идёт между сервисами в заголовке Kafka `traceparent` (W3C). Запрос клиента
к Project API → `video.uploaded` → Scene Detection и Transcription → `scenes.detected` /
`dialogue.aligned` → Aggregator → обогащение видно в Jaeger одной цепочкой. Спаны `… process`
(обработка события) и `… publish` (публикация) несут атрибуты `cutsheet.project_id` и
`cutsheet.event_id`: в Jaeger поиск по тегу `cutsheet.project_id=<id>`. Упавшая обработка
помечена ошибкой.

## Healthcheck

- Python: `GET :9100/health` — 200, пока жив цикл чтения Kafka; в ответе — чем занят сервис
  и как долго (`busy_with`, `busy_s`): транскрибация фильма на час — не зависание. В compose
  это `healthcheck` контейнера, `docker compose up --wait` ждёт его.
- C#: `GET :8080/health` (в образе aspnet нет curl, поэтому их состояние видно по цели
  Prometheus и `CutsheetServiceDown`).

## Нагрузочный тест

`tools/load_test.py` запускает N проектов одновременно (видео + сценарий прямо в Kafka и
MinIO, как `make e2e-enrichment`) и по `project.status-changed` замеряет время каждого этапа
до `ready_for_review`. В конце — таблица, медиана, максимум и отношение к длительности ролика.

```sh
python tools/load_test.py -n 5 film.mp4 film.docx --timeout 14400 --json load.json
```

Цель ТЗ: 5 параллельных проектов, фильм 90 мин обрабатывается не дольше 1,5× его
длительности (≤ 135 мин) на целевом железе с GPU для Whisper. CI гоняет 3 проекта на
9-секундном ролике — это проверка, что параллельные проекты не мешают друг другу, а не
замер производительности. Во время теста смотрите в Grafana lag, p95 длительности этапов и
вызовы LLM: узкое место обычно Transcription (GPU) или LLM (`LLM_MAX_CONCURRENCY`).
Масштабирование Python-сервисов — `docker compose up --scale shot-type=3` (партиций по 3).

## Резервное копирование

`make db-backup` (`tools/pg_backup.sh`): `pg_dump` в `backups/`, восстановление во временную
базу и сравнение числа строк основных таблиц; хранит 14 последних копий (`KEEP`). Ежедневно —
через cron в WSL (`0 3 * * * cd ~/cutsheet && make db-backup >> backups/backup.log 2>&1`).
Запускать лучше без активной обработки, иначе сравнение строк может расходиться из-за новых
записей. Данные S3 (видео, кадры) — том `minio-data`, их копия — `mc mirror`.

## Подбор порогов на реальных фильмах

Пороги выставлены на синтетике; их нужно уточнить на 3–5 фильмах с ручной разметкой (ТЗ 11.2).
Порядок: прогнать фильм, выгрузить лист, сравнить с эталоном по метрике из таблицы, менять
один параметр за раз.

| Метрика (цель) | Параметры |
|---|---|
| Границы сцен ±0,5 с (≥ 90 %) | `SD_DETECTOR` (`content` / `adaptive`), `SD_THRESHOLD` (27), `SD_MIN_SCENE_MS` (1000) |
| Реплика с верной ролью (≥ 85 %), таймкод ≤ 1 с (90 %) | `TA_MODEL` (`small` → `large-v3` на GPU), `AlignConfig` в `services/transcription/src/transcription/align.py`: `min_confidence` 0,5, `min_gap_confidence` 0,75, `word_similarity` 0,7 |
| Верный план (≥ 80 %) | пороги `FACE_*`, `PERSON_SMALL`, `OBJECT_DETAIL` в `services/shot-type/src/shot_type/classify.py` (правила `shot-rules-v1`; при смене — новая версия правил) |
| Описания без правки по сути (≥ 70 %) | модель `SDS_LLM_MODEL`, сравнение моделей — `tools/compare_descriptions.py` |
| Обработка 90 мин ≤ 135 мин | `make load-test` на фильме, GPU для Whisper, `LLM_MAX_CONCURRENCY` |

Реальные фильмы для этого этапа пока не получены, поэтому подобранные значения остаются
значениями по умолчанию.
