# Shot Type

Заглушка этапа 0. Реализация — этап 3 (ТЗ, раздел 5.7).

- Стек: Python, MediaPipe / YOLO
- Читает: `scene.ready-for-enrichment`
- Публикует: `scene.enriched` (`source = shot_type`), при невосстановимой ошибке — `pipeline.failed`

Значения плана: `wide`, `medium`, `close`, `detail`, `unknown` (см. `contracts/schemas/defs.v1.json`).

Шаблон сервиса — `services/scene-detection`: обработчик `Event -> list[Event]`,
Kafka и S3 через `libs/python/cutsheet-common`, Dockerfile со сборкой из корня репозитория.
