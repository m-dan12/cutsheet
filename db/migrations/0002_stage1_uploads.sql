-- Этап 1: загрузка видео по presigned URL (multipart) и статус пайплайна в карточке проекта.

ALTER TABLE projects
    ADD COLUMN stage text NOT NULL DEFAULT 'upload',
    ADD COLUMN error text,
    ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now();

ALTER TABLE uploads
    ADD COLUMN filename     text,
    ADD COLUMN content_type text,
    ADD COLUMN size_bytes   bigint,
    ADD COLUMN part_size    bigint,
    ADD COLUMN part_count   integer,
    ADD COLUMN s3_upload_id text,           -- UploadId multipart-загрузки S3
    ADD COLUMN completed_at timestamptz;
CREATE INDEX uploads_project_idx ON uploads(project_id);
