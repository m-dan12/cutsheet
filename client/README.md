# Клиент CutSheet (Flutter Desktop)

Минимальный клиент этапа 1 (ТЗ 5.1): вход и регистрация, список проектов, создание проекта,
загрузка видео и найденные планы с ключевыми кадрами. Статус обработки приходит в реальном
времени через SignalR.

Клиент ходит только в Kong (`http://localhost:8000`: `/api/v1/...` и хаб `/hubs/projects`),
а видео грузит частями напрямую в MinIO по presigned URL от Project API. Если загрузка
оборвалась, кнопка «Продолжить загрузку» догружает только недостающие части.

## Запуск

Нужен Flutter 3.38+ и поднятое окружение (`make up` в корне репозитория).

```sh
cd client
flutter pub get
flutter run -d windows        # или macos, linux
```

Другой адрес шлюза: `flutter run -d windows --dart-define=API_BASE=http://192.168.1.10:8000`.
Тогда и MinIO должен быть доступен клиенту: `S3_PUBLIC_ENDPOINT=http://192.168.1.10:9000`
в `deploy/.env`.

Токены хранятся в защищённом хранилище ОС (Windows Credential Manager, Keychain, libsecret
на Linux); refresh-токен обновляется сам.

## Тесты

```sh
flutter analyze
flutter test                                                        # unit
flutter test test/live_backend_test.dart \
  --dart-define=LIVE_VIDEO=$PWD/../tools/sample.mp4                 # против make up
```

## Что дальше

Таблица листа с редактированием, плеер и экспорт — этапы 4–5.
