# Chat Service — README для разработчика

## Что делает сервис

Chat Service — source of truth для чатов и участников.

Сервис отвечает за:
- создание direct и group чатов
- хранение метаданных чата
- управление участниками и ролями
- список чатов пользователя
- internal point lookup для других сервисов
- денормализованное поле `last_message_at`

Сервис не отвечает за:
- хранение сообщений
- receipts
- WebSocket-доставку
- upload вложений

---

## Что читать в первую очередь

Читайте файлы в таком порядке:

1. [`../architecture.md`](../architecture.md)
2. [`../api/chat-service.yaml`](../api/chat-service.yaml)
3. [`../database/chat-service.sql`](../database/chat-service.sql)
4. [`../events/kafka-schema.md`](../events/kafka-schema.md)
5. [`../contracts/auth.md`](../contracts/auth.md)
6. [`../contracts/errors.md`](../contracts/errors.md)
7. [`../infra/redis.md`](../infra/redis.md)

Ключевые разделы:
- REST API: `api/chat-service.yaml`
- internal endpoints: `api/chat-service.yaml`, раздел `Internal`
- БД: `database/chat-service.sql`
- Kafka: `events/kafka-schema.md`, секции `chat.events` и `message.created`
- auth и service token: `contracts/auth.md`

---

## Что владеет сервис

PostgreSQL:
- `chats`
- `chat_members`
- `chat_metadata`
- `direct_chat_index`
- `outbox_events`

Redis:
- `chat:dedup:{idempotency_key}`
- `chat:member_check:{chat_id}:{user_id}`

Kafka:
- публикует `chat.created`, `chat.updated`, `chat.deleted` в `chat.events`
- потребляет `message.created` для обновления `last_message_at`

---

## Какие API реализовать

Публичные endpoints:
- `GET /api/v1/chats`
- `POST /api/v1/chats`
- `GET /api/v1/chats/{chat_id}`
- `PATCH /api/v1/chats/{chat_id}`
- `DELETE /api/v1/chats/{chat_id}`
- `GET /api/v1/chats/{chat_id}/members`
- `POST /api/v1/chats/{chat_id}/members`
- `GET /api/v1/chats/{chat_id}/members/{user_id}`
- `PATCH /api/v1/chats/{chat_id}/members/{user_id}`
- `DELETE /api/v1/chats/{chat_id}/members/{user_id}`
- health endpoints

Internal endpoints:
- `GET /api/v1/internal/chats/{chat_id}/members/{user_id}`
- `GET /api/v1/internal/chats/{chat_id}/snapshot`
- `GET /api/v1/internal/users/{user_id}/chats`

---

## Главные инварианты

- Direct chat всегда между двумя пользователями.
- Для direct chat нельзя добавить третьего участника.
- Пара пользователей для direct chat должна быть уникальной.
- В group chat всегда ровно один `owner`.
- `owner` может передать владение другому участнику через `PATCH /members/{user_id}`.
- Если owner хочет выйти из чата, он сначала передаёт роль `owner`.
- `last_message_at` обновляется не из REST-операций, а асинхронно по `message.created`.
- Список чатов сортируется по `COALESCE(last_message_at, created_at)` desc.
- Soft delete используется и для чатов, и для участников.

---

## Как сервис получает аутентификацию

Публичные запросы:
- JWT валидируется на API Gateway
- сервис получает `X-User-Id`, `X-User-Roles`, `X-Request-Id`

Межсервисные запросы:
- service token в `Authorization: Bearer <service_token>`
- обязательный `X-Service-Name`
- детали в [`../contracts/auth.md`](../contracts/auth.md)

Сам сервис JWT не валидирует.

---

## Какие события смотреть

Публикуемые события:
- `chat.created`
- `chat.updated`
- `chat.deleted`

Потребляемое событие:
- `message.created`

Перед публикацией и потреблением обязательно сверяться с:
- [`../events/kafka-schema.md`](../events/kafka-schema.md)

---

## Что делать в первой очереди

Рекомендуемый порядок разработки:

1. Миграции и схема PostgreSQL.
2. Репозитории для `chats`, `chat_members`, `direct_chat_index`.
3. Создание direct/group чатов.
4. CRUD метаданных чата.
5. Управление участниками и ролями.
6. Outbox и публикация `chat.events`.
7. Internal endpoints.
8. Consumer `message.created` для `last_message_at`.
9. Кэш `chat:member_check`.
10. `health/live` и `health/ready`.

---

## Что не нужно делать в этом сервисе

Не пытайтесь реализовать тут:
- сообщения и историю переписки
- delivered/read receipts
- WebSocket
- binary upload файлов
- push-notifications

---

## Перед изменением контрактов

Если меняете:
- API
- формат Kafka-события
- схему БД
- internal endpoints

сначала меняйте spec в этом репозитории, потом код сервиса.
