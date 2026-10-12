# Transcription & Alignment

Заглушка этапа 0. Реализация — этап 2 (ТЗ, раздел 5.5).

- Стек: Python, Whisper / WhisperX, нечёткое сопоставление со сценарием
- Читает: `video.uploaded`, `script.parsed`
- Публикует: `dialogue.aligned`, при невосстановимой ошибке — `pipeline.failed`

Нужен GPU-образ (ТЗ 8). Транскрипт кэшируется в S3: `projects/{id}/transcript/`.

Шаблон сервиса — `services/scene-detection`: обработчик `Event -> list[Event]`,
Kafka и S3 через `libs/python/cutsheet-common`, Dockerfile со сборкой из корня репозитория.
