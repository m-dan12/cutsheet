# Scene Detection

Читает `video.uploaded`, находит склейки PySceneDetect, сохраняет ключевые кадры в S3
и публикует `scenes.detected` (ТЗ 5.3).

- Сцены идут без дыр от 0 до конца видео; сцены короче `SD_MIN_SCENE_MS` приклеиваются
  к предыдущей (FR-SD2, FR-SD5).
- Ключевые кадры: `SD_KEYFRAMES` штук (по умолчанию 3) в центрах равных отрезков сцены,
  чтобы не попадать на кадр перехода. Ключи: `projects/{project_id}/frames/scene_{idx:05d}_{n}.jpg`.
- Повтор того же события перезаписывает те же объекты и даёт тот же `event_id` результата.

| Переменная | По умолчанию | |
|---|---|---|
| `SD_DETECTOR` | `content` | `content` или `adaptive` |
| `SD_THRESHOLD` | 27.0 (content) / 3.0 (adaptive) | порог детектора |
| `SD_MIN_SCENE_MS` | 1000 | минимальная длительность сцены |
| `SD_KEYFRAMES` | 3 | кадров на сцену |
| `KAFKA_MAX_POLL_INTERVAL_MS` | 7200000 | долгие видео: брокер не отберёт партицию |
| `KAFKA_BOOTSTRAP`, `S3_*` | | см. `deploy/docker-compose.yml` |

Локально: `make dev-install && make test-python`. `scenedetect` ставится с `--no-deps`,
потому что тянет `opencv-python` с GUI, а нужен `opencv-python-headless`.

Известные ограничения этапа 0: видео скачивается во временную папку целиком (для
фильмов на десятки ГБ лучше читать по presigned URL); у фильма с очень частым монтажом
список сцен может приблизиться к лимиту 1 МБ на сообщение.
