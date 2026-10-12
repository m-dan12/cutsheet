# Сборка из корня репозитория: docker build -f services/shot-type/Dockerfile .
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1 \
    CUTSHEET_CONTRACTS_DIR=/app/contracts/schemas \
    ST_MODEL_DIR=/models MPLCONFIGDIR=/tmp/matplotlib

# libEGL/libGLESv2 нужны библиотеке mediapipe при загрузке, даже на CPU.
RUN apt-get update && apt-get install -y --no-install-recommends libegl1 libgles2 \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY libs/python/cutsheet-common /app/libs/cutsheet-common
COPY services/shot-type/pyproject.toml /app/service/pyproject.toml
COPY services/shot-type/src /app/service/src
RUN pip install /app/libs/cutsheet-common /app/service \
 && pip install --no-deps "mediapipe==1.1.0"
COPY contracts/schemas /app/contracts/schemas

# Модели MediaPipe скачиваются при первой сцене в том /models (см. docker-compose.yml).
RUN mkdir -p /models && chown nobody /models
USER nobody
CMD ["python", "-m", "shot_type"]
