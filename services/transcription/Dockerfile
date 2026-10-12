# Сборка из корня репозитория: docker build -f services/transcription/Dockerfile .
# По умолчанию CPU-образ с faster-whisper (без torch). GPU с WhisperX:
#   docker build --build-arg TA_EXTRAS=whisperx -f services/transcription/Dockerfile .
# (для GPU нужен базовый образ с CUDA и запуск с --gpus all; см. README сервиса).
FROM python:3.12-slim

ARG TA_EXTRAS=whisper
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1 \
    CUTSHEET_CONTRACTS_DIR=/app/contracts/schemas \
    HF_HOME=/models

RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /models && chown nobody /models

WORKDIR /app
COPY libs/python/cutsheet-common /app/libs/cutsheet-common
COPY services/transcription/pyproject.toml /app/service/pyproject.toml
COPY services/transcription/src /app/service/src
RUN pip install /app/libs/cutsheet-common "/app/service[${TA_EXTRAS}]"
COPY contracts/schemas /app/contracts/schemas

# Модели Whisper скачиваются при первом распознавании в /models (том в docker-compose).
USER nobody
CMD ["python", "-m", "transcription"]
