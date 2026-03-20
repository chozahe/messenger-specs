# Message Service — README для разработчика

## Что делает сервис

Message Service — source of truth для сообщений.

Сервис отвечает за:
- отправку сообщений
- хранение сообщений
- редактирование и soft delete
- историю сообщений
- read receipts
- outbox и публикацию событий в Kafka

Сервис не отвечает за:
- хранение чатов и членства как source of truth
- WebSocket-доставку
- upload бинарных вложений
- push-notifications

Архив и холодное хранилище пока не являются приоритетом текущего scope.

---

## Что читать в первую очередь

Читайте файлы в таком порядке:

1. [`../architecture.md`](../architecture.md)
2. [`../api/message-service.yaml`](../api/message-service.yaml)
3. [`../database/message-service.sql`](../database/message-service.sql)
4. [`../events/kafka-schema.md`](../events/kafka-schema.md)
5. [`../contracts/auth.md`](../contracts/auth.md)
6. [`../contracts/errors.md`](../contracts/errors.md)
7. [`../api/chat-service.yaml`](../api/chat-service.yaml), раздел `Internal`
8. [`../infra/redis.md`](../infra/redis.md)

Ключевые места:
- REST API: `api/message-service.yaml`
- история и пагинация: `GET /chats/{chat_id}/history`
- receipts: `GET /receipts`, `POST /receipts/read`
- БД и sequence counters: `database/message-service.sql`
- Kafka: `message.*` и `receipt.events`

---

## Что владеет сервис

PostgreSQL:
- `chat_sequence_counters`
- `messages`
- `message_versions`
- `receipts`
- `outbox_events`

Redis:
- `msg:cache:chat_messages:{chat_id}`
- `msg:ratelimit:{user_id}`
- `msg:dedup:{idempotency_key}`

Kafka:
- публикует `message.created`
- публикует `message.updated`
- публикует `message.deleted`
- публикует `receipt.read` в `receipt.events`
- потребляет `receipt.delivered` из `receipt.events`

---

## Внешние зависимости

Chat Service:
- membership/role checks через internal endpoints
- Message Service не должен сам хранить source of truth по членству

Attachment Service:
- Message Service принимает `attachment_id`
- бинарные данные и upload не хранятся здесь

Search Service:
- для расширенного поиска в будущем
- для базового этапа достаточно PostgreSQL поиска

Realtime Gateway:
- доставляет `message.*` события клиентам
- подтверждает доставку через `receipt.delivered`

---

## Какие API реализовать

Основные endpoints:
- `POST /api/v1/chats/{chat_id}/messages`
- `GET /api/v1/chats/{chat_id}/messages/{message_id}`
- `PATCH /api/v1/chats/{chat_id}/messages/{message_id}`
- `DELETE /api/v1/chats/{chat_id}/messages/{message_id}`
- `GET /api/v1/chats/{chat_id}/messages/{message_id}/versions`
- `GET /api/v1/chats/{chat_id}/history`
- `GET /api/v1/chats/{chat_id}/search`
- `GET /api/v1/chats/{chat_id}/receipts`
- `POST /api/v1/chats/{chat_id}/receipts/read`
- health endpoints

---

## Главные инварианты

- `sequence_number` монотонно растёт внутри каждого чата.
- sequence выдаётся атомарно через `chat_sequence_counters`.
- `Idempotency-Key` не должен создавать дубликаты сообщений.
- Клиент не может отправлять `content_type = system`.
- `reply_to_id` должен ссылаться на сообщение того же чата.
- Нельзя reply на удалённое сообщение.
- Удалённые сообщения остаются в истории, но без контента.
- Edit сохраняет старую версию в `message_versions`.
- `receipt.read` публикуется агрегированно по `last_read_sequence_number`.

---

## Пагинация истории

Это один из самых важных контрактов сервиса.

Поддерживаемые режимы:
- initial load
- `before`
- `after`
- `around`
- `cursor`

Правила:
- одновременно разрешён только один из `cursor`, `before`, `after`, `around`
- `cursor` — opaque, клиент сам его не собирает
- ответ всегда отсортирован по `sequence_number asc`
- `next_cursor` означает более новые сообщения
- `prev_cursor` означает более старые сообщения

Смотрите:
- [`../api/message-service.yaml`](../api/message-service.yaml), endpoint `GET /chats/{chat_id}/history`

---

## Receipts

Есть два разных потока:

Delivered:
- Gateway получает `ack` по WS
- Gateway публикует `receipt.delivered`
- Message Service обновляет per-message delivery status

Read:
- клиент вызывает `POST /receipts/read`
- Message Service обновляет receipts до `last_read_sequence_number`
- Message Service публикует `receipt.read`
- Gateway превращает его в aggregate WS `receipt.updated`

Смотрите:
- [`../events/kafka-schema.md`](../events/kafka-schema.md)
- [`../api/websocket.md`](../api/websocket.md)

---

## Что делать в первой очереди

Рекомендуемый порядок разработки:

1. Миграции и схема PostgreSQL.
2. `next_sequence_number()` и запись сообщений.
3. Outbox worker.
4. `POST /messages`.
5. `GET /messages/{id}`, `PATCH`, `DELETE`.
6. `GET /history` с корректной пагинацией.
7. `GET /versions`.
8. `GET /receipts` и `POST /receipts/read`.
9. Кэш последних сообщений и rate limit.
10. Поиск через PostgreSQL.

---

## Что пока можно не форсить

В текущем этапе можно не считать обязательным:
- архив / cold storage path
- интеграцию с Notification Service
- продвинутый Elasticsearch search

Но не ломайте контракты под эти будущие сценарии.

---

## Спорные места, которые надо держать в голове

В спеке всё ещё есть два бизнес-вопроса:
- лимит по времени на редактирование пока не зафиксирован
- право админа чата удалять чужие сообщения пока не финализировано

Если будете реализовывать это в коде, сначала синхронизируйтесь с командой.

---

## Перед изменением контрактов

Если меняете:
- REST API
- историю / пагинацию
- receipts
- Kafka payload
- схему БД

сначала меняйте spec в этом репозитории, потом код сервиса.
