-- Этап 3: сбор scene.enriched в Aggregator (ТЗ 5.6, FR-A4, FR-A6).
-- На каждую сцену после join ждём два результата: план (shot_type) и описание (description).
-- Значения пишутся в scenes.shot_type / scenes.description и в scene_auto_values (исходный
-- авто-результат); здесь — только состояние ожидания.

CREATE TABLE scene_enrichment (
    scene_id         uuid NOT NULL REFERENCES scenes(id) ON DELETE CASCADE,
    source           text NOT NULL CHECK (source IN ('shot_type', 'description')),
    status           text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'done', 'failed')),
    request_event_id uuid NOT NULL,          -- scene.ready-for-enrichment, на который ждём ответ
    requested_at     timestamptz NOT NULL DEFAULT now(),
    finished_at      timestamptz,
    error            text,
    PRIMARY KEY (scene_id, source)
);
-- pipeline.failed ссылается на запрос по source_event_id.
CREATE INDEX scene_enrichment_request_idx ON scene_enrichment(request_event_id);
CREATE INDEX scene_enrichment_pending_idx ON scene_enrichment(requested_at) WHERE status = 'pending';

-- Статусы сцены: detected → enriching (после join) → ready | enrichment_failed (FR-A4, FR-A6).

-- Какая модель дала авто-значение (для сравнения локальной и внешней, FR-SDS3).
ALTER TABLE scene_auto_values ADD COLUMN model text;
