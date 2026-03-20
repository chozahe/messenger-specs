# Realtime Gateway — README для разработчика

## Что делает сервис

Realtime Gateway отвечает за realtime слой системы.

Сервис делает:
- WebSocket handshake
- валидацию JWT для WS
- хранение ephemeral routing state в Redis
- доставку событий клиентам
- online presence
- typing indicators
- преобразование Kafka-событий в клиентские WS-события
- публикацию `receipt.delivered`

Сервис не делает:
- хранение сообщений
- хранение чатов как source of truth
- upload файлов

Push notifications упомянуты в спеках как будущий опциональный путь и сейчас не должны блокировать разработку базового realtime слоя.

---

## Что читать в первую очередь

Читайте файлы в таком порядке:

1. [`../architecture.md`](../architecture.md)
2. [`../api/websocket.md`](../api/websocket.md)
3. [`../infra/redis.md`](../infra/redis.md)
4. [`../events/kafka-schema.md`](../events/kafka-schema.md)
5. [`../contracts/auth.md`](../contracts/auth.md)
6. [`../api/chat-service.yaml`](../api/chat-service.yaml), раздел `Internal`

Ключевые места:
- WS handshake / heartbeat / reconnect: `api/websocket.md`
- Redis keys: `infra/redis.md`
- Kafka topics and payloads: `events/kafka-schema.md`
- internal cold start lookup: `api/chat-service.yaml`

---

## Что владеет сервис

Redis:
- `gw:session:{user_id}`
- `gw:conn:{connection_id}`
- `gw:presence:{user_id}`
- `gw:node:{node_id}`
- `gw:dedup:{event_id}`
- `gw:typing:{chat_id}:{user_id}`

Kafka:
- потребляет `chat.events`
- потребляет `message.created`
- потребляет `message.updated`
- потребляет `message.deleted`
- потребляет `receipt.events`
- публикует `receipt.delivered` в `receipt.events`
- публикует `presence.events`

`notification.requests` есть в схемах, но в текущем этапе можно ограничиться базовым realtime без отдельного notification flow.

---

## Какие зависимости есть у сервиса

Auth:
- Gateway сам валидирует JWT при WS handshake
- использует JWKS endpoint

Chat Service:
- локальный кэш чатов поддерживается событиями `chat.events`
- при cold start можно вызвать `GET /api/v1/internal/users/{user_id}/chats`
- при cache miss можно вызвать `GET /api/v1/internal/chats/{chat_id}/snapshot`

Redis:
- routing table
- presence
- межузловая доставка

Message Service:
- получает `message.*`
- отправляет обратно `receipt.delivered`

---

## Главные инварианты

- Сейчас модель зафиксирована как `1` активное WS-соединение на пользователя.
- Пользователь считается online по `gw:presence`.
- Любое Kafka-событие должно проходить dedup по `event_id`.
- `receipt.updated` на клиенте имеет две формы:
  delivered — per-message
  read — aggregate с `last_read_sequence_number`
- `typing.start` ограничен rate limit и auto-stop через TTL.
- Клиент обязан слать `ping`, сервер отвечает `pong`.

---

## Что именно отдаёт клиенту

Основные WS-события:
- `connected`
- `message.new`
- `message.updated`
- `message.deleted`
- `receipt.updated`
- `presence.updated`
- `chat.updated`
- `typing.started`
- `typing.stopped`
- `error`
- `pong`

Смотрите:
- [`../api/websocket.md`](../api/websocket.md)

---

## Receipts

Два отдельных входных источника:

1. Delivered:
- клиент прислал `ack`
- Gateway публикует `receipt.delivered`
- клиентам потом уходит WS `receipt.updated` со `status = delivered`

2. Read:
- Message Service публикует `receipt.read`
- Gateway отправляет WS `receipt.updated` со `status = read`
- payload агрегированный, с `last_read_sequence_number`

Это важная часть контракта. Не смешивайте delivered и read как один и тот же payload.

---

## Что делать в первой очереди

Рекомендуемый порядок разработки:

1. WS handshake.
2. JWT validation через JWKS.
3. Регистрация соединения в Redis.
4. Heartbeat / ping / pong / idle timeout.
5. Kafka consumers для `message.*` и `chat.events`.
6. Routing на локальный узел и через `gw:node:{node_id}`.
7. `ack` -> `receipt.delivered`.
8. Presence online/offline.
9. Typing flow.
10. Internal cold start / cache miss lookup через Chat Service.

---

## На что не тратить время в начале

Пока не делайте это главным фокусом:
- push notifications
- multi-device routing
- сложную offline-доставку
- архив / cold storage

Сначала нужен стабильный core:
- handshake
- routing
- kafka -> ws
- ack -> delivered
- presence

---

## Что особенно важно проверить тестами

- reconnect после разрыва
- dedup Kafka-событий
- cache miss и cold start
- delivered/read receipts
- cleanup Redis при disconnect
- heartbeat timeout
- close codes `4000`, `4001`, `4003`

---

## Перед изменением контрактов

Если меняете:
- WS payload
- Redis key model
- Kafka mapping
- handshake/auth flow

сначала меняйте spec в этом репозитории, потом код сервиса.
