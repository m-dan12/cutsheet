COMPOSE = docker compose -f deploy/docker-compose.yml
PY ?= python3

.PHONY: up down logs ps dev-install test test-contracts test-python sample e2e e2e-kafka

up:            ## поднять всё окружение
	$(COMPOSE) up -d --build

down:          ## остановить (данные в томах сохраняются; down -v — удалить)
	$(COMPOSE) down

logs:
	$(COMPOSE) logs -f --tail=100

ps:
	$(COMPOSE) ps

dev-install:   ## зависимости для тестов и tools/ на хосте
	$(PY) -m pip install -e libs/python/cutsheet-common -e "services/scene-detection[test]" pytest websockets
	$(PY) -m pip install --no-deps scenedetect==0.7.2

test: test-contracts test-python

test-contracts:
	$(PY) -m pytest -q contracts/tests

test-python:
	$(PY) -m pytest -q libs/python/cutsheet-common/tests services/scene-detection/tests

sample:        ## тестовый ролик 9 с с тремя склейками
	sh tools/make_sample_video.sh tools/sample.mp4

e2e: sample    ## через Kong, как клиент: вход → проект → загрузка в MinIO → SignalR → сцены
	$(PY) tools/e2e_api.py tools/sample.mp4

e2e-kafka: sample  ## без API: видео → video.uploaded → scenes.detected → project.status-changed
	$(PY) tools/dev_pipeline.py tools/sample.mp4
