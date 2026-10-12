COMPOSE = docker compose -f deploy/docker-compose.yml
PY ?= python3

.PHONY: up up-obs down logs ps dev-install test test-contracts test-python test-dotnet sample sample-script e2e e2e-kafka e2e-dialogues e2e-enrichment e2e-editing e2e-ops dlq-list load-test db-backup e2e-export

up:            ## поднять всё окружение
	$(COMPOSE) up -d --build

up-obs:        ## то же + Prometheus :9090, Grafana :3000, Jaeger :16686, kafka-exporter (этап 6)
	OTEL_EXPORTER_OTLP_ENDPOINT=$${OTEL_EXPORTER_OTLP_ENDPOINT:-http://jaeger:4318} \
		$(COMPOSE) --profile observability up -d --build

down:          ## остановить (данные в томах сохраняются; down -v — удалить)
	$(COMPOSE) --profile observability --profile llm down

logs:
	$(COMPOSE) logs -f --tail=100

ps:
	$(COMPOSE) ps

dev-install:   ## зависимости для тестов и tools/ на хосте
	$(PY) -m pip install -e libs/python/cutsheet-common -e "libs/python/llm-client[test]" \
		-e "services/scene-detection[test]" -e "services/script-parser[test]" -e "services/transcription[test]" \
		-e "services/shot-type[test]" -e "services/scene-description[test]" \
		-e "services/export[test]" pytest websockets
	$(PY) -m pip install --no-deps scenedetect==0.7.2 mediapipe==1.1.0

test: test-contracts test-python

test-contracts:
	$(PY) -m pytest -q contracts/tests

test-python:
	$(PY) -m pytest -q libs/python/cutsheet-common/tests libs/python/llm-client/tests services/scene-detection/tests
	$(PY) -m pytest -q services/script-parser/tests
	$(PY) -m pytest -q services/transcription/tests
	$(PY) -m pytest -q services/shot-type/tests
	$(PY) -m pytest -q services/scene-description/tests
	$(PY) -m pytest -q services/export/tests

test-dotnet:   ## unit-тесты C#; с CUTSHEET_TEST_PG — и тесты на PostgreSQL (join, правки листа)
	dotnet test services/aggregator-tests
	dotnet test services/project-api-tests

sample:        ## тестовый ролик 9 с с тремя склейками
	sh tools/make_sample_video.sh tools/sample.mp4

sample-script: ## тестовый сценарий .docx
	$(PY) tools/make_sample_script.py tools/sample_script.docx

e2e: sample    ## через Kong, как клиент: вход → проект → загрузка в MinIO → SignalR → сцены
	$(PY) tools/e2e_api.py tools/sample.mp4

e2e-kafka: sample  ## без API: видео → video.uploaded → scenes.detected → project.status-changed
	$(PY) tools/dev_pipeline.py tools/sample.mp4

e2e-dialogues: sample sample-script  ## видео + сценарий → script.parsed, dialogue.aligned, scene.ready-for-enrichment
	$(PY) tools/dev_dialogues.py tools/sample.mp4 tools/sample_script.docx

e2e-enrichment: sample sample-script  ## то же и дальше: scene.enriched (план, описание) → ready_for_review
	$(PY) tools/dev_dialogues.py --enrichment tools/sample.mp4 tools/sample_script.docx

e2e-editing: sample  ## правки листа через Kong: row_version, split/merge, перезапуск без потери правок
	$(PY) tools/e2e_editing.py tools/sample.mp4

e2e-export: sample  ## экспорт через Kong: xlsx / docx / pdf с правками пользователя, шаблоны, export.failed
	$(PY) tools/e2e_export.py tools/sample.mp4

e2e-ops:       ## DLQ, повторы, pipeline.failed; с make up-obs ещё метрики и трейсы (этап 6)
	$(PY) tools/e2e_ops.py $(if $(OBS),--observability)

dlq-list:      ## что лежит в DLQ; повтор: python tools/dlq.py replay <topic>
	$(PY) tools/dlq.py list

N ?= 5
load-test: sample sample-script  ## N проектов параллельно до ready_for_review (ТЗ 11.1)
	$(PY) tools/load_test.py -n $(N) tools/sample.mp4 tools/sample_script.docx

db-backup:     ## pg_dump в backups/ и проверка восстановления во временную базу (ТЗ 8)
	sh tools/pg_backup.sh backups
