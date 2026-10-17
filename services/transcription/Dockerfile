# Сборка из корня репозитория: docker build -f services/transcription/Dockerfile .
# По умолчанию CPU-образ с faster-whisper (без torch). GPU с WhisperX:
#   docker build --build-arg TA_EXTRAS=whisperx -f services/transcription/Dockerfile .
# (для GPU нужен базовый образ с CUDA и запуск с --gpus all; см. README сервиса).
# GigaAM на CPU (torch без CUDA, иначе образ раздувается на гигабайты):
#   docker build --build-arg TA_EXTRAS=gigaam --build-arg TORCH_INDEX=https://download.pytorch.org/whl/cpu \
#     -f services/transcription/Dockerfile .
FROM python:3.12-slim

ARG TA_EXTRAS=whisper
ARG TORCH_INDEX=""
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1 \
    CUTSHEET_CONTRACTS_DIR=/app/contracts/schemas \
    HF_HOME=/models \
    TA_GIGAAM_DIR=/models/gigaam

RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg git \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /models && chown nobody /models

WORKDIR /app
COPY libs/python/cutsheet-common /app/libs/cutsheet-common
COPY services/transcription/pyproject.toml /app/service/pyproject.toml
COPY services/transcription/src /app/service/src
RUN pip install ${TORCH_INDEX:+--extra-index-url "$TORCH_INDEX"} /app/libs/cutsheet-common "/app/service[${TA_EXTRAS}]"
COPY contracts/schemas /app/contracts/schemas

# Модели Whisper и GigaAM скачиваются при первом распознавании в /models (том в docker-compose).
USER nobody
CMD ["python", "-m", "transcription"]
