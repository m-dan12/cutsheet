-- Этап 4: редактирование монтажного листа (ТЗ 5.1 FR-C5–C12, 5.2 FR-G4/G5/G7, 6.2).
-- Человек — источник истины: итоговое значение лежит в scenes/replicas, отметка «изменено
-- пользователем» и исходное авто-значение — в user_edits (одна строка на поле), свежий
-- авто-результат обогащения — в scene_auto_values.

-- Одна актуальная правка на поле: повторная правка обновляет строку, сброс к авто — удаляет.
CREATE UNIQUE INDEX user_edits_scene_field_idx ON user_edits(scene_id, field) WHERE scene_id IS NOT NULL;
CREATE UNIQUE INDEX user_edits_replica_field_idx ON user_edits(replica_id, field) WHERE replica_id IS NOT NULL;
-- Значение поля до первой правки: к нему возвращает «сбросить», если нет scene_auto_values.
ALTER TABLE user_edits ADD COLUMN auto_value jsonb;
ALTER TABLE user_edits ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now();

-- Сцена создана человеком (split, добавление вручную) или детектором.
ALTER TABLE scenes ADD COLUMN origin text NOT NULL DEFAULT 'auto' CHECK (origin IN ('auto', 'user'));
-- Границы сцены изменены человеком: авто-описание и план относятся к старым границам (ТЗ 6.2).
ALTER TABLE scenes ADD COLUMN needs_enrichment boolean NOT NULL DEFAULT false;

-- Реплика удалена человеком. Строка остаётся как метка, чтобы повторный join не вернул её.
ALTER TABLE replicas ADD COLUMN deleted boolean NOT NULL DEFAULT false;
ALTER TABLE replicas ADD COLUMN origin text NOT NULL DEFAULT 'auto' CHECK (origin IN ('auto', 'user'));

-- Человек менял границы сцен (таймкоды, split, merge, удаление, добавление): повторная детекция
-- больше не трогает структуру листа, а только обновляет авто-значения.
ALTER TABLE projects ADD COLUMN structure_edited boolean NOT NULL DEFAULT false;
-- Режим «без правок» (FR-C12): false — ревью необязательно, экспорт доступен сразу после обработки.
ALTER TABLE projects ADD COLUMN review_required boolean NOT NULL DEFAULT true;
