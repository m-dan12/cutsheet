# Сборка из корня репозитория: docker build -f services/scene-description/Dockerfile .
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1 \
    CUTSHEET_CONTRACTS_DIR=/app/contracts/schemas

WORKDIR /app
COPY libs/python/cutsheet-common /app/libs/cutsheet-common
COPY libs/python/llm-client /app/libs/llm-client
COPY services/scene-description/pyproject.toml /app/service/pyproject.toml
COPY services/scene-description/src /app/service/src
RUN pip install /app/libs/cutsheet-common /app/libs/llm-client /app/service
COPY contracts/schemas /app/contracts/schemas

USER nobody
CMD ["python", "-m", "scene_description"]
