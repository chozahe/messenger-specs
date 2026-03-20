# Messenger — Specs

Спецификации распределённой системы мессенджера на микросервисной архитектуре.

> Этот репозиторий содержит только спецификации, схемы и контракты.
> Исходный код каждого сервиса живёт в отдельном репозитории.

---

## Обзор системы

Мессенджер состоит из трёх основных микросервисов, связанных через Kafka (Event-Driven Architecture):

| Сервис | Язык | Ответственность |
|---|---|---|
| **Chat Service** | Go | Управление чатами и участниками |
| **Message Service** | Python / Django | Хранение и обработка сообщений |
| **Notification / Realtime Gateway** | Gleam | WebSocket-доставка, online presence |

Вспомогательные сервисы: Auth (JWT/OAuth2), Attachment (S3), Search (Elasticsearch), Admin/Moderation.

---

## Структура репозитория

```
specs/
├── README.md                  # этот файл
├── architecture.md            # C4-диаграммы, схема связей
│
├── api/
│   ├── chat-service.yaml      # OpenAPI: Chat Service
│   ├── message-service.yaml   # OpenAPI: Message Service
│   └── websocket.md           # WS-протокол: события, форматы, reconnect
│
├── events/
│   └── kafka-schema.md        # Топики, форматы событий, partitioning, конвенции
│
├── database/
│   ├── chat-service.sql       # Схема БД Chat Service (PostgreSQL)
│   └── message-service.sql    # Схема БД Message Service (PostgreSQL)
│
├── contracts/
│   ├── auth.md                # JWT: claims, валидация, межсервисная аутентификация
│   └── errors.md              # Единый формат ошибок по всем сервисам
│
├── infra/
│   └── redis.md               # Redis: ключи, структуры данных, TTL
│
├── onboarding/
│   ├── chat-service.md        # README для разработчика Chat Service
│   ├── message-service.md     # README для разработчика Message Service
│   └── realtime-gateway.md    # README для разработчика Realtime Gateway
│
└── adr/
    └── 0001-template.md       # Шаблон Architecture Decision Record
```

---

## Сервисы

### Chat Service (Go)

Отвечает за создание/удаление чатов, управление участниками, список чатов пользователя.

- **API:** REST (gRPC — опционально)
- **БД:** PostgreSQL (`chats`, `chat_members`, `chat_metadata`)
- **Kafka:** публикует `chat.created`, `chat.updated`, `chat.deleted`
- **Kafka:** потребляет `message.created` для денормализованного `last_message_at`
- **Спека:** [`api/chat-service.yaml`](api/chat-service.yaml)
- **README для разработчика:** [`onboarding/chat-service.md`](onboarding/chat-service.md)

### Message Service (Python / Django)

Отвечает за отправку, хранение, редактирование и удаление сообщений, историю с пагинацией.

- **API:** REST + JWT
- **БД:** PostgreSQL (`messages`, `message_versions`), monthly partitioning по времени
- **Kafka:** публикует `message.created`, `message.updated`, `message.deleted`, `receipt.read` в `receipt.events`
- **Kafka:** потребляет `receipt.delivered` из `receipt.events`
- **Паттерн:** Outbox для гарантированной доставки событий
- **Спека:** [`api/message-service.yaml`](api/message-service.yaml)
- **README для разработчика:** [`onboarding/message-service.md`](onboarding/message-service.md)

### Notification / Realtime Gateway (Gleam)

Читает события из Kafka, доставляет клиентам через WebSocket, управляет online presence.

- **Состояние:** Redis (sessions, presence, connection routing)
- **Kafka:** подписывается на `chat.events`, `message.created`, `message.updated`, `message.deleted`, `receipt.events`
- **Kafka:** публикует `receipt.delivered` в `receipt.events`, а также `presence.events` и `notification.requests`
- **Спека:** [`api/websocket.md`](api/websocket.md)
- **README для разработчика:** [`onboarding/realtime-gateway.md`](onboarding/realtime-gateway.md)

---

## README для разработчиков

Если у вас по одному разработчику на сервис, начинайте с соответствующего файла:

- Chat Service: [`onboarding/chat-service.md`](onboarding/chat-service.md)
- Message Service: [`onboarding/message-service.md`](onboarding/message-service.md)
- Realtime Gateway: [`onboarding/realtime-gateway.md`](onboarding/realtime-gateway.md)

---

## Kafka — топики

| Топик | Продюсер | Консьюмер |
|---|---|---|
| `chat.events` | Chat Service | Realtime Gateway |
| `message.created` | Message Service | Realtime Gateway, Chat Service |
| `message.updated` | Message Service | Realtime Gateway |
| `message.deleted` | Message Service | Realtime Gateway |
| `receipt.events` | Realtime Gateway, Message Service | Message Service, Realtime Gateway |
| `presence.events` | Realtime Gateway | — |
| `notification.requests` | Realtime Gateway | Notification Service |

Партиционирование chat-oriented топиков — по `chat_id`, presence/notification топиков — по `user_id`.
Подробнее: [`events/kafka-schema.md`](events/kafka-schema.md).

---

## Требования к событиям

Каждое событие обязано содержать:

```json
{
  "event_id": "uuid",
  "event_type": "message.created",
  "occurred_at": "ISO8601",
  "source_service": "message-service",
  "payload_version": 1,
  "payload": {}
}
```

Schema registry (Avro / Protobuf) — обязателен для эволюции схем.
Consumer'ы — идемпотентны, дедупликация по `event_id`.

---

## Стек

| Слой | Технология |
|---|---|
| API Gateway | Envoy / Traefik |
| Очередь | Kafka |
| Основная БД | PostgreSQL |
| Кэш / Presence | Redis |
| Поиск | Elasticsearch |
| Объектное хранилище | S3-compatible |
| Метрики | Prometheus + Grafana |
| Трейсинг | OpenTelemetry → Jaeger / Tempo |
| Логи | ELK / Grafana Loki |
| Оркестрация | Kubernetes |

---

## NFR (ключевые)

| Параметр | Таргет |
|---|---|
| SLA | 99.95% |
| p95 latency realtime доставка | < 200 ms |
| p95 latency API | < 300 ms |
| Пропускная способность | 2 000 msg/s (масштабируемо до 100k+) |
| Хранение сообщений (горячее) | ≥ 30 дней |
| Безопасность | TLS everywhere, JWT/OAuth2, RBAC |

---

## Как пользоваться спеками

1. Перед реализацией любого эндпоинта — сверяйся с OpenAPI спекой своего сервиса.
2. Перед публикацией или потреблением события — сверяйся с [`events/kafka-schema.md`](events/kafka-schema.md).
3. Любое изменение контракта (API, события, схема БД) — только через PR в этот репозиторий.
4. Архитектурные решения, которые меняют подход — фиксируй в `adr/`.

---

## Контакты

| Сервис | Ответственный |
|---|---|
| Chat Service | — |
| Message Service | — |
| Realtime Gateway | — |
