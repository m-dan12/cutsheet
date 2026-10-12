# Scene Description

Заглушка этапа 0. Реализация — этап 3 (ТЗ, раздел 5.8).

- Стек: Python, мультимодальная LLM через `libs/python/llm-client`
- Читает: `scene.ready-for-enrichment`
- Публикует: `scene.enriched` (`source = description`), при невосстановимой ошибке — `pipeline.failed`

Промпт и модель — в конфигурации, версия промпта пишется в результат.

Шаблон сервиса — `services/scene-detection`: обработчик `Event -> list[Event]`,
Kafka и S3 через `libs/python/cutsheet-common`, Dockerfile со сборкой из корня репозитория.
