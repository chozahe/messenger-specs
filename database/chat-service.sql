-- ============================================================
-- Chat Service — PostgreSQL Schema
-- ============================================================
-- Соглашения:
--   - все PK: UUID, gen_random_uuid()
--   - все временные метки: TIMESTAMPTZ (UTC)
--   - soft delete через deleted_at IS NULL
--   - индексы покрывают основные паттерны запросов
-- ============================================================

-- ------------------------------------------------------------
-- Extensions
-- ------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS "pgcrypto";  -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS "btree_gin"; -- GIN индексы

-- ------------------------------------------------------------
-- Типы
-- ------------------------------------------------------------
CREATE TYPE chat_type AS ENUM ('direct', 'group');

CREATE TYPE member_role AS ENUM ('owner', 'admin', 'member');

-- ------------------------------------------------------------
-- chats
-- ------------------------------------------------------------
-- Основная таблица чатов. Source of truth для метаданных чата.
-- ------------------------------------------------------------
CREATE TABLE chats (
    id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    type            chat_type       NOT NULL,
    title           TEXT,                          -- только для group, NULL для direct
    avatar_url      TEXT,                          -- только для group
    created_by      UUID            NOT NULL,      -- user_id создателя
    deleted_at      TIMESTAMPTZ,                   -- soft delete
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT now(),

    -- для direct чата: пара участников уникальна
    -- реализуется через partial unique index ниже
    CONSTRAINT chats_title_required_for_group
        CHECK (type = 'direct' OR title IS NOT NULL),
    CONSTRAINT chats_title_null_for_direct
        CHECK (type = 'group' OR title IS NULL)
);

-- активные чаты (без удалённых)
CREATE INDEX idx_chats_active ON chats (id)
    WHERE deleted_at IS NULL;

-- поиск чатов по создателю
CREATE INDEX idx_chats_created_by ON chats (created_by)
    WHERE deleted_at IS NULL;

-- ------------------------------------------------------------
-- chat_members
-- ------------------------------------------------------------
-- Участники чата. Удаление участника — soft delete (left_at).
-- ------------------------------------------------------------
CREATE TABLE chat_members (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    chat_id     UUID        NOT NULL REFERENCES chats (id) ON DELETE CASCADE,
    user_id     UUID        NOT NULL,
    role        member_role NOT NULL DEFAULT 'member',
    invited_by  UUID,                   -- user_id пригласившего, NULL для создателя
    joined_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    left_at     TIMESTAMPTZ,            -- soft delete: участник покинул чат

    CONSTRAINT chat_members_unique_active
        UNIQUE NULLS NOT DISTINCT (chat_id, user_id, left_at)
        -- PostgreSQL 15+: гарантирует уникальность пары (chat_id, user_id) среди активных участников
);

-- основной запрос: список участников чата
CREATE INDEX idx_chat_members_chat_id ON chat_members (chat_id, joined_at)
    WHERE left_at IS NULL;

-- обратный запрос: список чатов пользователя
CREATE INDEX idx_chat_members_user_id ON chat_members (user_id, joined_at DESC)
    WHERE left_at IS NULL;

-- быстрая проверка членства конкретного пользователя в чате
CREATE INDEX idx_chat_members_lookup ON chat_members (chat_id, user_id)
    WHERE left_at IS NULL;

-- только один owner на чат
CREATE UNIQUE INDEX idx_chat_members_one_owner
    ON chat_members (chat_id)
    WHERE role = 'owner' AND left_at IS NULL;

-- для direct чатов: уникальность пары пользователей
-- реализуется на уровне приложения + partial unique index через функцию
-- (chat_id хранит ordered pair user_ids для direct, проверяется в сервисе)

-- ------------------------------------------------------------
-- chat_metadata
-- ------------------------------------------------------------
-- Расширяемое хранилище произвольных метаданных чата.
-- Используется для хранения доп. настроек без ALTER TABLE.
-- ------------------------------------------------------------
CREATE TABLE chat_metadata (
    chat_id     UUID    NOT NULL REFERENCES chats (id) ON DELETE CASCADE,
    key         TEXT    NOT NULL,
    value       JSONB   NOT NULL,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),

    PRIMARY KEY (chat_id, key)
);

-- ------------------------------------------------------------
-- direct_chat_index
-- ------------------------------------------------------------
-- Вспомогательная таблица для быстрого поиска direct чата
-- между двумя пользователями.
-- user_id_a < user_id_b (alphabetical order) — инвариант.
-- ------------------------------------------------------------
CREATE TABLE direct_chat_index (
    user_id_a   UUID    NOT NULL,   -- меньший UUID лексикографически
    user_id_b   UUID    NOT NULL,   -- больший UUID лексикографически
    chat_id     UUID    NOT NULL REFERENCES chats (id) ON DELETE CASCADE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),

    PRIMARY KEY (user_id_a, user_id_b),
    CONSTRAINT direct_chat_index_order CHECK (user_id_a < user_id_b)
);

CREATE INDEX idx_direct_chat_index_chat_id ON direct_chat_index (chat_id);

-- ------------------------------------------------------------
-- outbox_events
-- ------------------------------------------------------------
-- Outbox таблица для гарантированной публикации событий в Kafka.
-- Worker читает непубликованные записи и отправляет в Kafka.
-- ------------------------------------------------------------
CREATE TABLE outbox_events (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id        UUID        NOT NULL UNIQUE DEFAULT gen_random_uuid(),
    event_type      TEXT        NOT NULL,   -- 'chat.created', 'chat.updated', 'chat.deleted'
    topic           TEXT        NOT NULL,   -- 'chat.events'
    partition_key   TEXT        NOT NULL,   -- chat_id (для партиционирования Kafka)
    payload         JSONB       NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    published_at    TIMESTAMPTZ,            -- NULL = ещё не опубликовано
    failed_at       TIMESTAMPTZ,
    retry_count     INT         NOT NULL DEFAULT 0,

    CONSTRAINT outbox_max_retries CHECK (retry_count <= 10)
);

-- индекс для Outbox Worker: читает только непубликованные
CREATE INDEX idx_outbox_unpublished ON outbox_events (created_at ASC)
    WHERE published_at IS NULL AND retry_count < 5;

-- очистка старых опубликованных записей (для pg_partman или ручного DELETE)
CREATE INDEX idx_outbox_published_at ON outbox_events (published_at)
    WHERE published_at IS NOT NULL;

-- ------------------------------------------------------------
-- Triggers: updated_at auto-update
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_chats_updated_at
    BEFORE UPDATE ON chats
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ------------------------------------------------------------
-- Views
-- ------------------------------------------------------------

-- Активные чаты (без soft-deleted)
CREATE VIEW active_chats AS
    SELECT * FROM chats WHERE deleted_at IS NULL;

-- Активные участники (без покинувших)
CREATE VIEW active_chat_members AS
    SELECT * FROM chat_members WHERE left_at IS NULL;

-- ------------------------------------------------------------
-- Примеры основных запросов
-- ------------------------------------------------------------

-- 1. Список чатов пользователя (отсортировано по активности)
--    SELECT c.*
--    FROM chats c
--    JOIN chat_members cm ON cm.chat_id = c.id
--    WHERE cm.user_id = $1
--      AND cm.left_at IS NULL
--      AND c.deleted_at IS NULL
--    ORDER BY c.updated_at DESC
--    LIMIT 20;

-- 2. Проверка членства пользователя в чате
--    SELECT role FROM chat_members
--    WHERE chat_id = $1 AND user_id = $2 AND left_at IS NULL;

-- 3. Поиск существующего direct чата между двумя пользователями
--    SELECT chat_id FROM direct_chat_index
--    WHERE user_id_a = LEAST($1, $2)::UUID
--      AND user_id_b = GREATEST($1, $2)::UUID;

-- 4. Список участников чата с ролями
--    SELECT user_id, role, joined_at, invited_by
--    FROM chat_members
--    WHERE chat_id = $1 AND left_at IS NULL
--    ORDER BY
--        CASE role WHEN 'owner' THEN 0 WHEN 'admin' THEN 1 ELSE 2 END,
--        joined_at ASC;
