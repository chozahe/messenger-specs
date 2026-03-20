# Kafka — схемы событий и топики

## Общие принципы

Все сервисы взаимодействуют асинхронно через Kafka по принципу Event-Driven Architecture.
Сервисы не вызывают друг друга напрямую для уведомлений об изменениях — они публикуют
события и подписываются на нужные топики.

**Брокер:** Kafka 3.x  
**Schema Registry:** обязателен (Confluent Schema Registry или Apicurio).  
**Формат схем:** Protobuf (предпочтительно) или Avro.  
**Сериализация:** бинарная через schema registry; для отладки допустим JSON.

---

## Конвенции

### Структура каждого события

Каждое событие обязано содержать envelope-поля верхнего уровня:

```json
{
  "event_id":        "<uuid v4>",
  "event_type":      "<топик>.<действие>",
  "occurred_at":     "<ISO8601 UTC>",
  "source_service":  "<имя сервиса>",
  "payload_version": "<целое число>",
  "payload":         { }
}
```

| Поле | Тип | Описание |
|---|---|---|
| `event_id` | uuid | Уникальный идентификатор события. Используется для дедупликации на стороне consumer. |
| `event_type` | string | Полное имя типа события. Совпадает с именем топика + действием, например `message.created`. |
| `occurred_at` | ISO8601 UTC | Время, когда событие произошло на стороне продюсера. Не время публикации в Kafka. |
| `source_service` | string | Имя сервиса-продюсера: `chat-service`, `message-service`, `realtime-gateway`. |
| `payload_version` | integer | Версия схемы payload. Начинается с 1, инкрементируется при breaking changes. |
| `payload` | object | Данные события. Структура определена для каждого типа ниже. |

### Именование топиков

Формат: `<домен>.<действие>` или `<домен>.events` для агрегированных топиков.

Примеры: `message.created`, `chat.events`, `receipt.events`.

### Ключи (Kafka message key)

Ключ сообщения определяет партицию и гарантирует порядок внутри партиции.

| Топик | Ключ | Причина |
|---|---|---|
| `chat.events` | `chat_id` | Порядок событий чата |
| `message.created` | `chat_id` | Порядок сообщений внутри чата |
| `message.updated` | `chat_id` | Порядок изменений сообщений чата |
| `message.deleted` | `chat_id` | Порядок удалений сообщений чата |
| `receipt.events` | `chat_id` | Порядок статусов внутри чата |
| `presence.events` | `user_id` | Порядок presence-событий пользователя |
| `notification.requests` | `user_id` | Порядок уведомлений пользователя |

### Партиционирование

Все топики, связанные с чатами, партиционируются по `chat_id`. Это гарантирует:
- порядок сообщений внутри одного чата;
- параллельную обработку разных чатов разными consumer-инстансами.

Рекомендуемое количество партиций на старте: **16** для топиков сообщений,
**8** для остальных. Увеличивать по мере роста нагрузки.

### Идемпотентность consumer'ов

Каждый consumer обязан:
1. Сохранять `event_id` обработанных событий (в БД или Redis с TTL 24 ч).
2. При получении события проверять — не обрабатывалось ли оно уже.
3. При дубликате — пропускать обработку, коммитить offset.

Consumer group naming: `<сервис>.<топик>`, например `realtime-gateway.message.created`.

### Retention

| Топик | Retention |
|---|---|
| `message.created` | 7 дней |
| `message.updated` | 7 дней |
| `message.deleted` | 7 дней |
| `chat.events` | 7 дней |
| `receipt.events` | 3 дня |
| `presence.events` | 1 день |
| `notification.requests` | 3 дня |

---

## Топики и события

---

### `chat.events`

**Продюсер:** Chat Service  
**Консьюмеры:** Realtime Gateway  
**Ключ:** `chat_id`  
**Партиций:** 8

Агрегированный топик для всех событий домена чатов.

---

#### `chat.created`

Новый чат создан.

```json
{
  "event_id": "550e8400-e29b-41d4-a716-446655440000",
  "event_type": "chat.created",
  "occurred_at": "2024-06-01T10:00:00Z",
  "source_service": "chat-service",
  "payload_version": 1,
  "payload": {
    "chat_id": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
    "type": "group",
    "title": "Команда бэкенда",
    "created_by": "7b9c1d2e-3f4a-5b6c-7d8e-9f0a1b2c3d4e",
    "member_ids": [
      "7b9c1d2e-3f4a-5b6c-7d8e-9f0a1b2c3d4e",
      "8c0d2e3f-4a5b-6c7d-8e9f-0a1b2c3d4e5f"
    ]
  }
}
```

| Поле | Тип | Описание |
|---|---|---|
| `chat_id` | uuid | Идентификатор созданного чата |
| `type` | string | `direct` или `group` |
| `title` | string \| null | Название. Только для group. |
| `created_by` | uuid | UUID создателя |
| `member_ids` | uuid[] | Все участники включая создателя |

---

#### `chat.updated`

Метаданные чата или состав участников изменились.

```json
{
  "event_id": "661f9511-f3ac-52e5-c827-557766551111",
  "event_type": "chat.updated",
  "occurred_at": "2024-06-01T10:05:00Z",
  "source_service": "chat-service",
  "payload_version": 1,
  "payload": {
    "chat_id": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
    "changes": ["title", "members"],
    "updated_by": "7b9c1d2e-3f4a-5b6c-7d8e-9f0a1b2c3d4e",
    "members_added": ["9d1e3f4a-5b6c-7d8e-9f0a-1b2c3d4e5f6a"],
    "members_removed": []
  }
}
```

| Поле | Тип | Описание |
|---|---|---|
| `chat_id` | uuid | Идентификатор чата |
| `changes` | string[] | Список изменившихся полей: `title`, `avatar_url`, `members`, `roles` |
| `updated_by` | uuid | Кто инициировал изменение |
| `members_added` | uuid[] | Добавленные участники. Пустой массив если не менялось. |
| `members_removed` | uuid[] | Удалённые участники. Пустой массив если не менялось. |

---

#### `chat.deleted`

Чат удалён.

```json
{
  "event_id": "772a0622-a4bd-63f6-d938-668877662222",
  "event_type": "chat.deleted",
  "occurred_at": "2024-06-01T11:00:00Z",
  "source_service": "chat-service",
  "payload_version": 1,
  "payload": {
    "chat_id": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
    "deleted_by": "7b9c1d2e-3f4a-5b6c-7d8e-9f0a1b2c3d4e",
    "member_ids": [
      "7b9c1d2e-3f4a-5b6c-7d8e-9f0a1b2c3d4e",
      "8c0d2e3f-4a5b-6c7d-8e9f-0a1b2c3d4e5f"
    ]
  }
}
```

| Поле | Тип | Описание |
|---|---|---|
| `chat_id` | uuid | Идентификатор удалённого чата |
| `deleted_by` | uuid | UUID пользователя, который удалил чат |
| `member_ids` | uuid[] | Все участники на момент удаления (для оповещения) |

---

### `message.created`

**Продюсер:** Message Service
**Консьюмеры:** Realtime Gateway, Search Service, Chat Service
**Ключ:** `chat_id`  
**Партиций:** 16

Новое сообщение отправлено и сохранено в БД.

```json
{
  "event_id": "883b1733-b5ce-74a7-e049-779988773333",
  "event_type": "message.created",
  "occurred_at": "2024-06-01T10:00:00Z",
  "source_service": "message-service",
  "payload_version": 1,
  "payload": {
    "message_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "chat_id": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
    "sender_id": "7b9c1d2e-3f4a-5b6c-7d8e-9f0a1b2c3d4e",
    "content_type": "text",
    "text": "Привет!",
    "attachment": null,
    "reply_to_id": null,
    "sequence_number": 42,
    "idempotency_key": "550e8400-e29b-41d4-a716-446655440000"
  }
}
```

| Поле | Тип | Описание |
|---|---|---|
| `message_id` | uuid | Идентификатор сообщения |
| `chat_id` | uuid | Идентификатор чата |
| `sender_id` | uuid | UUID отправителя |
| `content_type` | string | `text`, `attachment`, `system` |
| `text` | string \| null | Текст сообщения. Присутствует если `content_type = text`. |
| `attachment` | object \| null | Данные вложения (см. ниже). Присутствует если `content_type = attachment`. |
| `reply_to_id` | uuid \| null | UUID сообщения, на которое отвечают |
| `sequence_number` | int64 | Порядковый номер сообщения внутри чата |
| `idempotency_key` | string \| null | Ключ идемпотентности от клиента |

**Структура `attachment`:**

```json
{
  "id": "b2c3d4e5-f6a7-8901-bcde-f12345678901",
  "url": "https://storage.example.com/attachments/abc.jpg",
  "content_type": "image/jpeg",
  "size_bytes": 204800,
  "filename": "photo.jpg",
  "thumbnail_url": "https://storage.example.com/thumbnails/abc_thumb.jpg"
}
```

---

### `message.updated`

**Продюсер:** Message Service  
**Консьюмеры:** Realtime Gateway, Search Service  
**Ключ:** `chat_id`  
**Партиций:** 16

Сообщение отредактировано.

```json
{
  "event_id": "994c2844-c6df-85b8-f150-880099884444",
  "event_type": "message.updated",
  "occurred_at": "2024-06-01T10:05:00Z",
  "source_service": "message-service",
  "payload_version": 1,
  "payload": {
    "message_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "chat_id": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
    "sender_id": "7b9c1d2e-3f4a-5b6c-7d8e-9f0a1b2c3d4e",
    "text": "Привет, исправленный текст!",
    "previous_text": "Привет!",
    "sequence_number": 42,
    "edited_at": "2024-06-01T10:05:00Z"
  }
}
```

| Поле | Тип | Описание |
|---|---|---|
| `message_id` | uuid | Идентификатор сообщения |
| `chat_id` | uuid | Идентификатор чата |
| `sender_id` | uuid | UUID автора сообщения |
| `text` | string | Новый текст |
| `previous_text` | string | Старый текст (для отображения истории в клиенте) |
| `sequence_number` | int64 | Порядковый номер сообщения в чате |
| `edited_at` | ISO8601 UTC | Время редактирования |

---

### `message.deleted`

**Продюсер:** Message Service  
**Консьюмеры:** Realtime Gateway, Search Service  
**Ключ:** `chat_id`  
**Партиций:** 16

Сообщение удалено (soft delete).

```json
{
  "event_id": "aa5d3955-d7e0-96c9-a261-991100995555",
  "event_type": "message.deleted",
  "occurred_at": "2024-06-01T10:10:00Z",
  "source_service": "message-service",
  "payload_version": 1,
  "payload": {
    "message_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "chat_id": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
    "deleted_by": "7b9c1d2e-3f4a-5b6c-7d8e-9f0a1b2c3d4e",
    "sequence_number": 42,
    "deleted_at": "2024-06-01T10:10:00Z"
  }
}
```

| Поле | Тип | Описание |
|---|---|---|
| `message_id` | uuid | Идентификатор удалённого сообщения |
| `chat_id` | uuid | Идентификатор чата |
| `deleted_by` | uuid | UUID того, кто удалил сообщение |
| `sequence_number` | int64 | Порядковый номер (для навигации в клиенте) |
| `deleted_at` | ISO8601 UTC | Время удаления |

---

### `receipt.events`

**Продюсеры:** Realtime Gateway (`receipt.delivered`), Message Service (`receipt.read`)
**Консьюмеры:** Message Service, Realtime Gateway
**Ключ:** `chat_id`  
**Партиций:** 16

Агрегированный топик для событий доставки и прочтения.

---

#### `receipt.delivered`

Realtime Gateway доставил сообщение клиенту (получен `ack` по WebSocket).

```json
{
  "event_id": "bb6e4a66-e8f1-07da-b372-aa2211006666",
  "event_type": "receipt.delivered",
  "occurred_at": "2024-06-01T10:00:01Z",
  "source_service": "realtime-gateway",
  "payload_version": 1,
  "payload": {
    "message_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "chat_id": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
    "user_id": "8c0d2e3f-4a5b-6c7d-8e9f-0a1b2c3d4e5f",
    "delivered_at": "2024-06-01T10:00:01Z"
  }
}
```

---

#### `receipt.read`

Клиент вызвал `POST /api/v1/chats/{chat_id}/receipts/read`, Message Service публикует это событие для
уведомления отправителя через Realtime Gateway.

```json
{
  "event_id": "cc7f5b77-f902-18eb-c483-bb3322117777",
  "event_type": "receipt.read",
  "occurred_at": "2024-06-01T10:01:00Z",
  "source_service": "message-service",
  "payload_version": 1,
  "payload": {
    "chat_id": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
    "user_id": "8c0d2e3f-4a5b-6c7d-8e9f-0a1b2c3d4e5f",
    "last_read_sequence_number": 42,
    "read_at": "2024-06-01T10:01:00Z"
  }
}
```

| Поле | Тип | Описание |
|---|---|---|
| `chat_id` | uuid | Идентификатор чата |
| `user_id` | uuid | Кто прочитал |
| `last_read_sequence_number` | int64 | Все сообщения с sequence_number ≤ этого значения считаются прочитанными |
| `read_at` | ISO8601 UTC | Время прочтения |

Realtime Gateway транслирует это Kafka-событие в WebSocket `receipt.updated`
со `status = "read"` и полем `last_read_sequence_number`.

---

### `presence.events`

**Продюсер:** Realtime Gateway  
**Консьюмеры:** (зарезервировано; опционально — Chat Service для агрегации статусов)  
**Ключ:** `user_id`  
**Партиций:** 8

---

#### `presence.online`

Пользователь подключился через WebSocket.

```json
{
  "event_id": "dd806c88-a013-29fc-d594-cc4433228888",
  "event_type": "presence.online",
  "occurred_at": "2024-06-01T10:00:00Z",
  "source_service": "realtime-gateway",
  "payload_version": 1,
  "payload": {
    "user_id": "7b9c1d2e-3f4a-5b6c-7d8e-9f0a1b2c3d4e",
    "connection_id": "conn_7f3a2b1c",
    "node_id": "node-01"
  }
}
```

---

#### `presence.offline`

Пользователь отключился (WS закрыт или истёк heartbeat).

```json
{
  "event_id": "ee917d99-b124-3aad-e605-dd5544339999",
  "event_type": "presence.offline",
  "occurred_at": "2024-06-01T11:00:00Z",
  "source_service": "realtime-gateway",
  "payload_version": 1,
  "payload": {
    "user_id": "7b9c1d2e-3f4a-5b6c-7d8e-9f0a1b2c3d4e",
    "connection_id": "conn_7f3a2b1c",
    "last_seen_at": "2024-06-01T11:00:00Z"
  }
}
```

---

### `notification.requests`

**Продюсер:** Realtime Gateway  
**Консьюмеры:** Notification Service (внешний push) — опционально  
**Ключ:** `user_id`  
**Партиций:** 8

Запрос на отправку push-уведомления пользователю, который offline.

```json
{
  "event_id": "ff028eaa-c235-4bbe-f716-ee6655440000",
  "event_type": "notification.push_requested",
  "occurred_at": "2024-06-01T10:00:02Z",
  "source_service": "realtime-gateway",
  "payload_version": 1,
  "payload": {
    "user_id": "8c0d2e3f-4a5b-6c7d-8e9f-0a1b2c3d4e5f",
    "notification_type": "new_message",
    "title": "Новое сообщение",
    "body": "У вас новое сообщение в чате",
    "data": {
      "chat_id": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
      "message_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
      "sender_id": "7b9c1d2e-3f4a-5b6c-7d8e-9f0a1b2c3d4e"
    }
  }
}
```

| Поле | Тип | Описание |
|---|---|---|
| `user_id` | uuid | Получатель push-уведомления |
| `notification_type` | string | `new_message`, `chat_updated` |
| `title` | string | Заголовок уведомления |
| `body` | string | Текст уведомления |
| `data` | object | Deep link данные для клиента |

---

## Сводная таблица топиков

| Топик | Продюсер | Консьюмеры | Ключ | Партиций | Retention |
|---|---|---|---|---|---|
| `chat.events` | Chat Service | Realtime Gateway | `chat_id` | 8 | 7 дней |
| `message.created` | Message Service | Realtime Gateway, Search, Chat Service | `chat_id` | 16 | 7 дней |
| `message.updated` | Message Service | Realtime Gateway, Search | `chat_id` | 16 | 7 дней |
| `message.deleted` | Message Service | Realtime Gateway, Search | `chat_id` | 16 | 7 дней |
| `receipt.events` | Realtime Gateway, Message Service | Message Service, Realtime Gateway | `chat_id` | 16 | 3 дня |
| `presence.events` | Realtime Gateway | (зарезервировано) | `user_id` | 8 | 1 день |
| `notification.requests` | Realtime Gateway | Notification Service | `user_id` | 8 | 3 дня |

---

## Эволюция схем

### Правила совместимости

Используется **BACKWARD** совместимость в schema registry: новые consumer'ы могут читать
старые сообщения.

**Разрешено без изменения `payload_version`:**
- добавление нового опционального поля с default-значением

**Требует инкремента `payload_version`:**
- переименование поля
- удаление поля
- изменение типа поля
- добавление обязательного поля без default

**При инкременте версии:**
1. Задеплоить consumer'ов с поддержкой новой версии.
2. Задеплоить продюсера с новой версией.
3. Убедиться, что старые сообщения в топике обработаны.
4. Убрать поддержку старой версии из consumer'ов (опционально, после retention).

### Обработка неизвестных версий

Consumer при получении события с незнакомым `payload_version`:
- логирует предупреждение
- пропускает обработку
- коммитит offset (не блокирует партицию)

---

## Dead Letter Queue

Для каждого основного топика существует DLQ-топик:
`<топик>.dlq`, например `message.created.dlq`.

Consumer перемещает сообщение в DLQ если:
- не смог десериализовать после 3 попыток
- бизнес-логика вернула неисправимую ошибку
- `payload_version` неизвестен

Сообщение в DLQ дополняется:

```json
{
  "original_topic": "message.created",
  "original_partition": 3,
  "original_offset": 12345,
  "failed_at": "2024-06-01T10:00:05Z",
  "error": "unknown payload_version: 99",
  "consumer_group": "realtime-gateway.message.created",
  "original_message": { }
}
```

DLQ мониторится через Grafana. Алерт при появлении любого сообщения в DLQ.

---

## Outbox pattern (Message Service)

Message Service использует Outbox для гарантированной публикации событий в Kafka.

### Таблица `outbox_events`

```sql
CREATE TABLE outbox_events (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id      UUID NOT NULL UNIQUE,
    event_type    TEXT NOT NULL,
    topic         TEXT NOT NULL,
    partition_key TEXT NOT NULL,
    payload       JSONB NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    published_at  TIMESTAMPTZ,
    failed_at     TIMESTAMPTZ,
    retry_count   INT NOT NULL DEFAULT 0
);

CREATE INDEX idx_outbox_unpublished ON outbox_events (created_at)
    WHERE published_at IS NULL AND retry_count < 5;
```

### Алгоритм Outbox Worker

1. Каждые 100 мс читает до 100 неопубликованных записей (`published_at IS NULL`).
2. Для каждой записи публикует сообщение в Kafka с ключом `partition_key`.
3. При успехе — устанавливает `published_at = now()`.
4. При ошибке — инкрементирует `retry_count`, устанавливает `failed_at`.
5. Записи с `retry_count >= 5` — перемещаются в DLQ вручную или алертом.

Транзакция при отправке сообщения:
```
BEGIN;
  INSERT INTO messages (...) VALUES (...);
  INSERT INTO outbox_events (event_type, topic, partition_key, payload)
    VALUES ('message.created', 'message.created', <chat_id>, <payload>);
COMMIT;
```
