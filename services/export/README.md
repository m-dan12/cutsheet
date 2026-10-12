# Export Service

Монтажный лист в `.xlsx`, `.docx` и `.pdf` (ТЗ 5.9, этап 5). Python: openpyxl, python-docx, reportlab.

- Читает: `export.requested` (`export_id`, `format`, `snapshot_uri`, `options`)
- Публикует: `export.completed` (`result_uri`) или `export.failed` (`error`)

В PostgreSQL не ходит (решение v0.2). Project API собирает снимок листа с итоговыми значениями
(правки пользователя уже применены) и кладёт его в S3; контракт снимка —
`contracts/schemas/documents/sheet-snapshot.v1.json`. Результат пишется по детерминированному ключу
`projects/{project_id}/exports/{export_id}/sheet.{format}`, поэтому повтор события перезаписывает
тот же файл и даёт тот же `event_id`.

Любой сбой (нет снимка, снимок не по контракту, неизвестный шаблон, ошибка S3) превращается в
`export.failed` с текстом ошибки: клиент видит его в статусе экспорта.

## Содержимое

- Шапка (FR-E5): название проекта, дата снимка, количество сцен, длительность.
- Колонки (FR-E2): №, начало, конец, план, описание, диалоги. Реплики — «РОЛЬ: текст», каждая с новой
  строки; у реплики без роли — только текст.
- Таймкод (FR-E3): `ЧЧ:ММ:СС:КК` по fps видео (как в клиенте); `options.timecode = "ms"` даёт
  `ЧЧ:ММ:СС.ммм`.
- Таблица повторяет шапку на каждой странице, внизу страницы — колонтитул с номером.

## Шаблоны (FR-E7)

Встроенный шаблон — `src/export_service/templates/default.json`: заголовок, строки шапки, колонтитул,
колонки и их ширина, подписи планов, шрифт и размер, TTF для PDF, формат листа и поля, цвет шапки.

Свои шаблоны меняются без пересборки: файл `<имя>.json` в каталоге `EXPORT_TEMPLATES_DIR`
(в compose — том `deploy/export-templates`, в образе `/templates`). Файл накладывается поверх
`default`, поэтому достаточно указать отличающиеся ключи. Шаблон выбирается в запросе:
`POST /projects/{id}/exports {"format": "pdf", "options": {"template": "<имя>"}}`.
Файл `default.json` в каталоге переопределяет встроенный шаблон для всех экспортов.

Пример `deploy/export-templates/compact.json`: только №, таймкоды и диалоги, книжная ориентация.

Колонки: `number`, `start`, `end`, `duration`, `shot`, `description`, `dialogue`.

## Переменные окружения

| Переменная | По умолчанию | |
|---|---|---|
| `S3_BUCKET` | `cutsheet` | куда писать результат |
| `EXPORT_TEMPLATES_DIR` | — | каталог своих шаблонов |
| `EXPORT_FONTS_DIR` | — | дополнительные каталоги с TTF (через `:`); по умолчанию ищет DejaVu в системных |

## Тесты

    pip install -e libs/python/cutsheet-common -e "services/export[test]"
    pytest services/export/tests

PDF-тесты читают текст обратно через pypdf и проверяют кириллицу; нужен DejaVu Sans
(`apt install fonts-dejavu-core`).
