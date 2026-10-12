# Сборка из корня репозитория: docker build -f services/scene-detection/Dockerfile .
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1 \
    CUTSHEET_CONTRACTS_DIR=/app/contracts/schemas

WORKDIR /app
COPY libs/python/cutsheet-common /app/libs/cutsheet-common
COPY services/scene-detection/pyproject.toml /app/service/pyproject.toml
COPY services/scene-detection/src /app/service/src
RUN pip install /app/libs/cutsheet-common /app/service \
 && pip install --no-deps "scenedetect==0.7.2"
COPY contracts/schemas /app/contracts/schemas

USER nobody
CMD ["python", "-m", "scene_detection"]
