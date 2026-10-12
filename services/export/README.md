# Export Service

Заглушка этапа 0. Реализация — этап 5 (ТЗ, раздел 5.9).

- Стек: Python, openpyxl, python-docx, reportlab
- Читает: `export.requested`
- Публикует: `export.completed` / `export.failed`, при невосстановимой ошибке — `pipeline.failed`

В PostgreSQL не ходит: читает снимок листа из S3, который собирает Project API (решение v0.2, ждёт подтверждения).

Шаблон сервиса — `services/scene-detection`: обработчик `Event -> list[Event]`,
Kafka и S3 через `libs/python/cutsheet-common`, Dockerfile со сборкой из корня репозитория.
