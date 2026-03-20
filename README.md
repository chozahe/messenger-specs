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
│   ├── errors.md              # Единый формат ошибок по всем сервисам
│   └── redis.md               # Redis: ключи, структуры данных, TTL
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
- **Спека:** [`api/chat-service.yaml`](api/chat-service.yaml)

### Message Service (Python / Django)

Отвечает за отправку, хранение, редактирование и удаление сообщений, историю с пагинацией.

- **API:** REST + JWT
- **БД:** PostgreSQL (`messages`, `message_versions`), партиционирование по времени / `chat_id`
- **Kafka:** публикует `message.created`, `message.updated`, `message.deleted`, `receipt.updated`
- **Паттерн:** Outbox для гарантированной доставки событий
- **Спека:** [`api/message-service.yaml`](api/message-service.yaml)

### Notification / Realtime Gateway (Gleam)

Читает события из Kafka, доставляет клиентам через WebSocket, управляет online presence.

- **Состояние:** Redis (sessions, presence, connection routing)
- **Kafka:** подписывается на `message.created`, `message.updated`, `receipt.updated`, `presence.events`
- **Kafka:** публикует `receipt.events` (delivered/read)
- **Спека:** [`api/websocket.md`](api/websocket.md)

---

## Kafka — топики

| Топик | Продюсер | Консьюмер |
|---|---|---|
| `chat.events` | Chat Service | Realtime Gateway |
| `message.created` | Message Service | Realtime Gateway |
| `message.updated` | Message Service | Realtime Gateway |
| `message.deleted` | Message Service | Realtime Gateway |
| `receipt.events` | Realtime Gateway | Message Service |
| `presence.events` | Realtime Gateway | — |
| `notification.requests` | Message Service | Realtime Gateway |

Партиционирование — по `chat_id`. Подробнее: [`events/kafka-schema.md`](events/kafka-schema.md).

---

## Требования к событиям

Каждое событие обязано содержать:

```json
{
  "event_id": "uuid",
  "occurred_at": "ISO8601",
  "source_service": "message-service",
  "payload_version": "1",
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
