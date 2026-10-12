# Shot Type

Крупность плана по ключевым кадрам сцены (ТЗ 5.7).

- Читает: `scene.ready-for-enrichment`
- Публикует: `scene.enriched` (`source = shot_type`, `confidence`, `model`, `prompt_version` = версия
  правил, `request_event_id`), при невосстановимой ошибке — `pipeline.failed`
- Значения: `wide` (общий), `medium` (средний), `close` (крупный), `detail` (деталь), `unknown`
  (справочник в `contracts/schemas/defs.v1.json`)

## Как определяется план

На каждом ключевом кадре (не больше `ST_MAX_FRAMES`) работают три модели MediaPipe Tasks:
поза (PoseLandmarker lite), лица (FaceDetector BlazeFace) и объекты (ObjectDetector
EfficientDet-Lite0, классы COCO). Правила (`src/shot_type/classify.py`, версия `shot-rules-v1`):

| Что видно у главного персонажа | План |
|---|---|
| стопы | общий |
| колени или бёдра, но не стопы | средний |
| только плечи и голова | крупный |
| лицо выше 75 % кадра | деталь |

Если поза не найдена — по высоте лица, затем по рамке человека. Без людей: крупный предмет
(больше 30 % площади) — деталь, мелкие предметы — общий; без предметов — эвристика резкости
(резкий центр при размытых краях — деталь, равномерно резкий кадр — общий, однотонный — `unknown`).
Итог сцены — взвешенное по уверенности большинство кадров; `confidence` — доля веса победителя.

## Модели

Модели не входят в образ: при первой сцене они скачиваются с `ST_MODEL_BASE_URL`
(по умолчанию `storage.googleapis.com/mediapipe-models`, Hugging Face не нужен) в `ST_MODEL_DIR`
(в compose — том `mediapipe-models`). Для офлайн-установки положите файлы в этот каталог заранее.

`mediapipe` ставится с `--no-deps`: его зависимость `opencv-contrib-python` конфликтует с
`opencv-python-headless`, а `sounddevice` не нужен. Нужные ему пакеты перечислены в `pyproject.toml`;
в системе нужны `libegl1` и `libgles2`.

| Переменная | По умолчанию | |
|---|---|---|
| `ST_MODEL_DIR` | `~/.cache/cutsheet/mediapipe` | куда скачиваются модели |
| `ST_MODEL_BASE_URL` | `https://storage.googleapis.com/mediapipe-models` | зеркало моделей |
| `ST_POSE_MODEL`, `ST_FACE_MODEL`, `ST_OBJECT_MODEL` | lite-модели | путь модели относительно базового URL |
| `ST_MAX_FRAMES` | 5 | кадров сцены на классификацию |
| `ST_MAX_SIDE` | 960 | кадр уменьшается до этой стороны |

## Тесты

`pytest services/shot-type/tests` — правила и сервис на подставном детекторе. С `ST_TEST_MODELS=1`
ещё и настоящие модели на тестовых снимках MediaPipe (нужна сеть; в CI включено).
