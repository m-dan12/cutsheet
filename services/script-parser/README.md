# Script Parser

Заглушка этапа 0. Реализация — этап 2 (ТЗ, раздел 5.4).

- Стек: Python, python-docx + LLM через `libs/python/llm-client`
- Читает: `script.uploaded`
- Публикует: `script.parsed`, при невосстановимой ошибке — `pipeline.failed`

Ответ LLM валидируется по JSON-схеме, при ошибке — повтор с уточнением.

Шаблон сервиса — `services/scene-detection`: обработчик `Event -> list[Event]`,
Kafka и S3 через `libs/python/cutsheet-common`, Dockerfile со сборкой из корня репозитория.
