-- Этап 5: экспорт монтажного листа (ТЗ 5.2 FR-G6, 5.9). Таблица exports создана на этапе 0;
-- пишет её только Project API: строка при запросе, статус — по export.completed / export.failed.

ALTER TABLE exports ADD COLUMN options jsonb NOT NULL DEFAULT '{}';
ALTER TABLE exports ADD COLUMN completed_at timestamptz;
ALTER TABLE exports ADD CONSTRAINT exports_status_check CHECK (status IN ('requested', 'completed', 'failed'));
CREATE INDEX exports_project_idx ON exports(project_id, created_at DESC);
