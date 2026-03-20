-- ============================================================
-- Message Service — PostgreSQL Schema
-- ============================================================
-- Соглашения:
--   - все PK: UUID, gen_random_uuid()
--   - все временные метки: TIMESTAMPTZ (UTC)
--   - soft delete сообщений через status = 'deleted'
--   - таблица messages партиционирована по времени (monthly)
--   - sequence_number: монотонно возрастающий per-chat счётчик
-- ============================================================

-- ------------------------------------------------------------
-- Extensions
-- ------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";   -- полнотекстовый поиск через триграммы

-- ------------------------------------------------------------
-- Типы
-- ------------------------------------------------------------
CREATE TYPE message_status AS ENUM ('sent', 'delivered', 'read', 'deleted');

CREATE TYPE message_content_type AS ENUM ('text', 'attachment', 'system');

CREATE TYPE receipt_status AS ENUM ('delivered', 'read');

-- ------------------------------------------------------------
-- chat_sequence_counters
-- ------------------------------------------------------------
-- Per-chat счётчик sequence_number.
-- Инкрементируется атомарно при каждой отправке сообщения.
-- Хранится отдельно чтобы не блокировать таблицу messages.
-- ------------------------------------------------------------
CREATE TABLE chat_sequence_counters (
    chat_id         UUID    PRIMARY KEY,
    last_sequence   BIGINT  NOT NULL DEFAULT 0
);

-- Атомарный инкремент при отправке сообщения:
-- UPDATE chat_sequence_counters
--    SET last_sequence = last_sequence + 1
--  WHERE chat_id = $1
-- RETURNING last_sequence;
--
-- Если строки нет — INSERT ... ON CONFLICT DO UPDATE.

-- ------------------------------------------------------------
-- messages
-- ------------------------------------------------------------
-- Основная таблица сообщений.
-- Партиционирована по created_at (RANGE, monthly).
-- ------------------------------------------------------------
CREATE TABLE messages (
    id              UUID                PRIMARY KEY DEFAULT gen_random_uuid(),
    chat_id         UUID                NOT NULL,
    sender_id       UUID                NOT NULL,
    content_type    message_content_type NOT NULL,
    text            TEXT,               -- присутствует если content_type = 'text', NULL при удалении
    attachment      JSONB,              -- присутствует если content_type = 'attachment', NULL при удалении
    reply_to_id     UUID,               -- ссылка на другое сообщение в том же чате
    status          message_status      NOT NULL DEFAULT 'sent',
    sequence_number BIGINT              NOT NULL,   -- монотонно возрастает per chat_id
    idempotency_key TEXT,               -- для дедупликации повторных запросов
    is_edited       BOOLEAN             NOT NULL DEFAULT FALSE,
    edited_at       TIMESTAMPTZ,
    created_at      TIMESTAMPTZ         NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ         NOT NULL DEFAULT now(),

    CONSTRAINT messages_text_required
        CHECK (content_type != 'text' OR status = 'deleted' OR text IS NOT NULL),
    CONSTRAINT messages_attachment_required
        CHECK (content_type != 'attachment' OR status = 'deleted' OR attachment IS NOT NULL),
    CONSTRAINT messages_sequence_positive
        CHECK (sequence_number > 0)
) PARTITION BY RANGE (created_at);

-- Партиции по месяцам (создавать заранее или через pg_partman)
CREATE TABLE messages_2024_01 PARTITION OF messages
    FOR VALUES FROM ('2024-01-01') TO ('2024-02-01');

CREATE TABLE messages_2024_02 PARTITION OF messages
    FOR VALUES FROM ('2024-02-01') TO ('2024-03-01');

-- ... и так далее. pg_partman автоматизирует создание партиций.

-- Уникальность sequence_number внутри чата
CREATE UNIQUE INDEX idx_messages_chat_sequence
    ON messages (chat_id, sequence_number);

-- Основной запрос истории: чат + порядок
CREATE INDEX idx_messages_chat_history
    ON messages (chat_id, sequence_number ASC)
    WHERE status != 'deleted';

-- Все сообщения чата включая удалённые (для полной истории)
CREATE INDEX idx_messages_chat_all
    ON messages (chat_id, sequence_number ASC);

-- Поиск по отправителю внутри чата
CREATE INDEX idx_messages_sender
    ON messages (chat_id, sender_id, created_at DESC)
    WHERE status != 'deleted';

-- Дедупликация по idempotency_key
CREATE UNIQUE INDEX idx_messages_idempotency
    ON messages (idempotency_key)
    WHERE idempotency_key IS NOT NULL;

-- Полнотекстовый поиск через триграммы (pg_trgm)
CREATE INDEX idx_messages_text_search
    ON messages USING GIN (text gin_trgm_ops)
    WHERE status != 'deleted' AND content_type = 'text';

-- ------------------------------------------------------------
-- message_versions
-- ------------------------------------------------------------
-- История редактирований сообщения.
-- При каждом редактировании старый текст сохраняется сюда.
-- ------------------------------------------------------------
CREATE TABLE message_versions (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    message_id  UUID        NOT NULL,   -- ссылка на messages.id (без FK из-за партиционирования)
    chat_id     UUID        NOT NULL,   -- дублируем для удобства запросов
    text        TEXT        NOT NULL,   -- текст ДО редактирования
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()  -- время когда была сохранена эта версия
);

-- история версий конкретного сообщения
CREATE INDEX idx_message_versions_message_id
    ON message_versions (message_id, created_at ASC);

-- ------------------------------------------------------------
-- receipts
-- ------------------------------------------------------------
-- Статусы доставки и прочтения для каждого участника.
-- Одна строка на пару (message_id, user_id).
-- ------------------------------------------------------------
CREATE TABLE receipts (
    message_id  UUID            NOT NULL,
    user_id     UUID            NOT NULL,
    chat_id     UUID            NOT NULL,   -- дублируем для партиционирования и запросов
    status      receipt_status  NOT NULL,
    updated_at  TIMESTAMPTZ     NOT NULL DEFAULT now(),

    PRIMARY KEY (message_id, user_id)
);

-- статусы всех сообщений чата (для отображения тиков)
CREATE INDEX idx_receipts_chat_id
    ON receipts (chat_id, message_id);

-- все прочтения конкретного пользователя в чате
CREATE INDEX idx_receipts_user_chat
    ON receipts (user_id, chat_id, updated_at DESC);

-- ------------------------------------------------------------
-- outbox_events
-- ------------------------------------------------------------
-- Outbox таблица для гарантированной публикации событий в Kafka.
-- Запись события происходит в той же транзакции что и запись сообщения.
-- ------------------------------------------------------------
CREATE TABLE outbox_events (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id        UUID        NOT NULL UNIQUE DEFAULT gen_random_uuid(),
    event_type      TEXT        NOT NULL,
    -- 'message.created' | 'message.updated' | 'message.deleted' | 'receipt.read'
    topic           TEXT        NOT NULL,
    partition_key   TEXT        NOT NULL,   -- chat_id
    payload         JSONB       NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    published_at    TIMESTAMPTZ,
    failed_at       TIMESTAMPTZ,
    retry_count     INT         NOT NULL DEFAULT 0,

    CONSTRAINT outbox_max_retries CHECK (retry_count <= 10)
);

-- Outbox Worker: читает только непубликованные записи
CREATE INDEX idx_outbox_unpublished
    ON outbox_events (created_at ASC)
    WHERE published_at IS NULL AND retry_count < 5;

-- очистка старых записей
CREATE INDEX idx_outbox_published_at
    ON outbox_events (published_at)
    WHERE published_at IS NOT NULL;

-- ------------------------------------------------------------
-- Triggers
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_messages_updated_at
    BEFORE UPDATE ON messages
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ------------------------------------------------------------
-- Functions
-- ------------------------------------------------------------

-- Атомарное получение следующего sequence_number для чата.
-- Вызывается внутри транзакции отправки сообщения.
CREATE OR REPLACE FUNCTION next_sequence_number(p_chat_id UUID)
RETURNS BIGINT AS $$
DECLARE
    v_seq BIGINT;
BEGIN
    INSERT INTO chat_sequence_counters (chat_id, last_sequence)
    VALUES (p_chat_id, 1)
    ON CONFLICT (chat_id) DO UPDATE
        SET last_sequence = chat_sequence_counters.last_sequence + 1
    RETURNING last_sequence INTO v_seq;

    RETURN v_seq;
END;
$$ LANGUAGE plpgsql;

-- ------------------------------------------------------------
-- Views
-- ------------------------------------------------------------

-- Последнее сообщение каждого чата (для списка чатов)
CREATE VIEW chat_last_messages AS
    SELECT DISTINCT ON (chat_id)
        chat_id,
        id          AS message_id,
        sender_id,
        content_type,
        text,
        sequence_number,
        created_at
    FROM messages
    WHERE status != 'deleted'
    ORDER BY chat_id, sequence_number DESC;

-- ------------------------------------------------------------
-- Retention / архивирование
-- ------------------------------------------------------------
-- Сообщения старше 30 дней могут быть перемещены в холодное хранилище (S3).
-- Реализуется через:
--   1. Экспорт партиции в S3 (pg_dump partition или COPY TO)
--   2. Фиксацию факта архивации в archived_partitions (или DROP PARTITION после экспорта)
--
-- Для отслеживания архивированных данных:

CREATE TABLE archived_partitions (
    partition_name  TEXT        PRIMARY KEY,  -- 'messages_2024_01'
    chat_ids        UUID[],                   -- чаты в этой партиции (для поиска)
    archived_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    s3_path         TEXT        NOT NULL,     -- s3://bucket/messages/2024_01/
    row_count       BIGINT
);

-- ------------------------------------------------------------
-- Примеры основных запросов
-- ------------------------------------------------------------

-- 1. Отправка сообщения (внутри одной транзакции)
--    BEGIN;
--      SELECT next_sequence_number($chat_id) INTO v_seq;
--      INSERT INTO messages (chat_id, sender_id, content_type, text,
--                            sequence_number, idempotency_key)
--           VALUES ($chat_id, $sender_id, 'text', $text, v_seq, $idem_key);
--      INSERT INTO outbox_events (event_type, topic, partition_key, payload)
--           VALUES ('message.created', 'message.created', $chat_id, $payload);
--    COMMIT;

-- 2. История сообщений чата (курсорная пагинация — более старые)
--    SELECT * FROM messages
--    WHERE chat_id = $1
--      AND sequence_number < $cursor
--    ORDER BY sequence_number DESC
--    LIMIT $limit;

-- 3. История сообщений чата (cursor — более новые)
--    SELECT * FROM messages
--    WHERE chat_id = $1
--      AND sequence_number > $cursor
--    ORDER BY sequence_number ASC
--    LIMIT $limit;

-- 4. Вокруг конкретного сообщения (around)
--    (SELECT * FROM messages WHERE chat_id = $1 AND sequence_number <= $seq
--     ORDER BY sequence_number DESC LIMIT $half)
--    UNION ALL
--    (SELECT * FROM messages WHERE chat_id = $1 AND sequence_number > $seq
--     ORDER BY sequence_number ASC LIMIT $half)
--    ORDER BY sequence_number ASC;

-- 5. Полнотекстовый поиск по чату
--    SELECT * FROM messages
--    WHERE chat_id = $1
--      AND status != 'deleted'
--      AND content_type = 'text'
--      AND text ILIKE '%' || $query || '%'
--    ORDER BY sequence_number DESC
--    LIMIT $limit;
--    -- или через триграммы для лучшей производительности:
--    -- AND text % $query

-- 6. Редактирование сообщения (в одной транзакции)
--    BEGIN;
--      INSERT INTO message_versions (message_id, chat_id, text)
--           SELECT id, chat_id, text FROM messages WHERE id = $1;
--      UPDATE messages
--         SET text = $new_text, is_edited = TRUE, edited_at = now()
--       WHERE id = $1 AND sender_id = $sender_id AND status != 'deleted';
--      INSERT INTO outbox_events (event_type, topic, partition_key, payload)
--           VALUES ('message.updated', 'message.updated', $chat_id, $payload);
--    COMMIT;

-- 7. Отметить сообщения прочитанными
--    BEGIN;
--      INSERT INTO receipts (message_id, user_id, chat_id, status)
--           SELECT id, $user_id, chat_id, 'read'
--             FROM messages
--            WHERE chat_id = $chat_id
--              AND sequence_number <= $last_seq
--              AND sender_id != $user_id
--      ON CONFLICT (message_id, user_id) DO UPDATE
--          SET status = 'read', updated_at = now()
--        WHERE receipts.status != 'read';
--      INSERT INTO outbox_events (event_type, topic, partition_key, payload)
--           VALUES ('receipt.read', 'receipt.events', $chat_id, $payload);
--    COMMIT;

-- 8. Статусы доставки для сообщений чата
--    SELECT r.message_id, r.user_id, r.status, r.updated_at
--      FROM receipts r
--     WHERE r.chat_id = $1
--       AND r.message_id = ANY($message_ids::UUID[]);
