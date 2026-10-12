-- Этап 2: join диалогов и сцен в Aggregator (ТЗ 5.6, FR-A1–A3).
-- Входы join хранятся в PostgreSQL, а не в памяти: порядок событий произвольный,
-- Aggregator может перезапуститься между ними.

CREATE TABLE join_inputs (
    project_id     uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    kind           text NOT NULL CHECK (kind IN ('scenes', 'dialogue')),
    event_id       uuid NOT NULL,
    correlation_id uuid NOT NULL,
    payload        jsonb NOT NULL,
    received_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (project_id, kind)
);

-- Какие входы уже нарезаны: повторная доставка не запускает нарезку заново.
ALTER TABLE pipeline_state ADD COLUMN joined_scenes_event_id   uuid;
ALTER TABLE pipeline_state ADD COLUMN joined_dialogue_event_id uuid;

-- Реплика найдена в сценарии (FR-TA4); несопоставленная речь — matched = false, role_id = NULL.
ALTER TABLE replicas ADD COLUMN matched boolean NOT NULL DEFAULT false;
