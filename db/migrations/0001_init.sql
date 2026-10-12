-- Схема данных cutsheet, версия 1 (ТЗ 6.1).
-- Этап 0: применяется postgres при первом старте с пустым томом.
-- Владение: таблицы public пишут только Project API и Aggregator, схему auth — только Auth Service.

CREATE SCHEMA IF NOT EXISTS auth;

CREATE TABLE auth.users (
    id            uuid PRIMARY KEY,
    email         text NOT NULL UNIQUE,
    password_hash text NOT NULL,
    role          text NOT NULL DEFAULT 'user',
    created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE auth.refresh_tokens (
    id          uuid PRIMARY KEY,
    user_id     uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    token_hash  text NOT NULL UNIQUE,
    expires_at  timestamptz NOT NULL,
    revoked_at  timestamptz
);

CREATE TABLE projects (
    id          uuid PRIMARY KEY,
    owner_id    uuid NOT NULL,
    name        text NOT NULL,
    status      text NOT NULL DEFAULT 'created',
    video_uri   text,
    script_uri  text,
    fps         double precision,
    duration_ms bigint,
    language    text NOT NULL DEFAULT 'ru',
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX projects_owner_idx ON projects(owner_id);

CREATE TABLE uploads (
    id         uuid PRIMARY KEY,
    project_id uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    kind       text NOT NULL CHECK (kind IN ('video', 'script')),
    s3_key     text NOT NULL,
    status     text NOT NULL DEFAULT 'pending',
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE pipeline_state (
    project_id       uuid PRIMARY KEY REFERENCES projects(id) ON DELETE CASCADE,
    correlation_id   uuid,
    scenes_detected  boolean NOT NULL DEFAULT false,
    dialogue_aligned boolean NOT NULL DEFAULT false,
    stage            text NOT NULL DEFAULT 'upload',
    error            text,
    updated_at       timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE scenes (
    id          uuid PRIMARY KEY,
    project_id  uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    idx         integer NOT NULL,
    start_ms    bigint NOT NULL,
    end_ms      bigint NOT NULL CHECK (end_ms > start_ms),
    shot_type   text,
    description text,
    status      text NOT NULL DEFAULT 'detected',
    row_version integer NOT NULL DEFAULT 1,
    UNIQUE (project_id, idx)
);

CREATE TABLE scene_keyframes (
    scene_id uuid NOT NULL REFERENCES scenes(id) ON DELETE CASCADE,
    position integer NOT NULL,
    s3_uri   text NOT NULL,
    PRIMARY KEY (scene_id, position)
);

CREATE TABLE roles (
    id         uuid PRIMARY KEY,
    project_id uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    name       text NOT NULL,
    aliases    text[] NOT NULL DEFAULT '{}',
    UNIQUE (project_id, name)
);

CREATE TABLE replicas (
    id             uuid PRIMARY KEY,
    scene_id       uuid NOT NULL REFERENCES scenes(id) ON DELETE CASCADE,
    idx            integer NOT NULL,
    start_ms       bigint NOT NULL,
    end_ms         bigint NOT NULL,
    role_id        uuid REFERENCES roles(id),   -- NULL: неизвестный говорящий (FR-TA5)
    text           text NOT NULL,
    spoken_text    text,
    script_line_id text,
    confidence     real
);
CREATE INDEX replicas_scene_idx ON replicas(scene_id, idx);

CREATE TABLE scene_auto_values (
    scene_id       uuid NOT NULL REFERENCES scenes(id) ON DELETE CASCADE,
    field          text NOT NULL,
    value          jsonb,
    confidence     real,
    source         text NOT NULL,
    prompt_version text,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (scene_id, field)
);

CREATE TABLE user_edits (
    id         uuid PRIMARY KEY,
    scene_id   uuid REFERENCES scenes(id) ON DELETE CASCADE,
    replica_id uuid REFERENCES replicas(id) ON DELETE CASCADE,
    field      text NOT NULL,
    value      jsonb,
    user_id    uuid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CHECK ((scene_id IS NULL) <> (replica_id IS NULL))
);

CREATE TABLE exports (
    id           uuid PRIMARY KEY,
    project_id   uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    format       text NOT NULL CHECK (format IN ('xlsx', 'docx', 'pdf')),
    status       text NOT NULL DEFAULT 'requested',
    snapshot_uri text,
    s3_uri       text,
    error        text,
    created_at   timestamptz NOT NULL DEFAULT now()
);

-- Дедупликация событий для C#-сервисов (ТЗ 3.3, идемпотентность).
CREATE TABLE processed_events (
    consumer     text NOT NULL,
    event_id     uuid NOT NULL,
    processed_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (consumer, event_id)
);
