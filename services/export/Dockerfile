# Сборка из корня репозитория: docker build -f services/export/Dockerfile .
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1 \
    CUTSHEET_CONTRACTS_DIR=/app/contracts/schemas \
    EXPORT_TEMPLATES_DIR=/templates

# DejaVu: TTF с кириллицей для PDF (встроенные шрифты PDF её не знают).
RUN apt-get update && apt-get install -y --no-install-recommends fonts-dejavu-core \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY libs/python/cutsheet-common /app/libs/cutsheet-common
COPY services/export/pyproject.toml /app/service/pyproject.toml
COPY services/export/src /app/service/src
RUN pip install /app/libs/cutsheet-common /app/service && mkdir -p /templates
COPY contracts/schemas /app/contracts/schemas

USER nobody
CMD ["python", "-m", "export_service"]
