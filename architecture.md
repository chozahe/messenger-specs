# Architecture

## Общий подход

Система построена по принципу микросервисной архитектуры с событийным взаимодействием (Event-Driven Architecture). Доменные изменения и уведомления передаются через Kafka. Синхронные REST/gRPC вызовы между сервисами допустимы только для point lookup и authorization checks по service-to-service контракту.

Каждый сервис:
- независимо деплоится и масштабируется
- владеет своей базой данных (Database per Service)
- публикует события об изменениях своего домена
- подписывается только на те события, которые нужны ему

---

## Сервисы

### Chat Service

**Язык:** Go  
**Домен:** чаты и участники  
**БД:** PostgreSQL

Отвечает за всё, что связано с жизненным циклом чата: создание личных диалогов и групповых чатов, добавление и удаление участников, получение списка чатов пользователя, управление правами доступа внутри чата.

Операции с участниками выполняются транзакционно — это одна из причин выбора Go и PostgreSQL: хорошая поддержка ACID и низкий оверхед на конкурентность.

При любом изменении чата сервис публикует событие в Kafka. Для поддержки денормализованного поля `last_message_at` сервис также потребляет `message.created` и обновляет активность чата без изменения source of truth для сообщений.

Internal point lookup endpoints Chat Service:
- `GET /api/v1/internal/chats/{chat_id}/members/{user_id}` — проверка членства/роли
- `GET /api/v1/internal/chats/{chat_id}/snapshot` — snapshot чата с активными участниками
- `GET /api/v1/internal/users/{user_id}/chats` — paginated список активных чатов пользователя

**Таблицы:**
- `chats` — метаданные чата (id, type, last_message_at, created_at, ...)
- `chat_members` — участники (chat_id, user_id, role, joined_at, ...)
- `chat_metadata` — дополнительные атрибуты чата

---

### Message Service

**Язык:** Python / Django  
**Домен:** сообщения  
**БД:** PostgreSQL

Отвечает за отправку, хранение, редактирование и мягкое удаление сообщений, а также за выдачу истории переписки с пагинацией и фильтрацией.

При отправке сообщения сервис сначала сохраняет его в БД, затем публикует событие в Kafka. Для гарантированной доставки событий используется паттерн Outbox: событие записывается в ту же транзакцию, что и само сообщение, и отдельный worker вычитывает его и отправляет в Kafka.

Поддерживает идемпотентность: повторная отправка одного сообщения (по `idempotency_key`) не создаёт дубликат. Порядок сообщений гарантируется внутри чата через партиционирование Kafka по `chat_id`.

Таблица `messages` партиционирована по времени (monthly) для производительности при больших объёмах.

**Таблицы:**
- `messages` — основная таблица сообщений
- `message_versions` — история редактирований
- `outbox_events` — Outbox для Kafka

---

### Notification / Realtime Gateway

**Язык:** Gleam (BEAM/OTP)  
**Домен:** доставка событий в реальном времени, online presence  
**БД:** Redis (ephemeral state)

Читает события из Kafka и доставляет их клиентам через WebSocket. Управляет WebSocket-соединениями, отслеживает online/offline статус пользователей, хранит маршрутизацию соединений в Redis.

BEAM/OTP выбран намеренно: модель акторов хорошо подходит для управления большим количеством долгоживущих соединений с низкой латентностью.

При получении события о новом сообщении сервис определяет, какие пользователи подключены прямо сейчас, и отправляет им обновление через соответствующее WebSocket-соединение. Если пользователь не подключён — опционально триггерится push-уведомление (FCM/APNs).

Принимает от клиентов WebSocket-ack подтверждения доставки и публикует их в Kafka как `receipt.delivered` в топик `receipt.events`. Статусы прочтения формируются Message Service после REST-вызова `POST /api/v1/chats/{chat_id}/receipts/read`.

Realtime Gateway преобразует Kafka-события receipts в единый клиентский WS-тип `receipt.updated`:
- `receipt.delivered` → per-message payload с `message_id`
- `receipt.read` → aggregate payload с `last_read_sequence_number`

**Redis:**
- `gw:presence:{user_id}` — online статус, TTL
- `gw:session:{user_id}` — к какому узлу подключён пользователь
- `gw:conn:{connection_id}` — метаданные соединения

---

### Auth Service

**Язык:** не определён / внешняя интеграция  
**Домен:** аутентификация и авторизация

Выдаёт JWT-токены. Все остальные сервисы только валидируют токены — не ходят в Auth Service при каждом запросе. Валидация происходит на уровне API Gateway, который инжектит `user_id` в заголовки запроса.

Токен содержит минимум: `user_id`, `roles`, `exp`.

---

### Attachment Service

**Домен:** вложения и медиафайлы  
**Хранилище:** S3-compatible object storage

Принимает файлы от клиента, сохраняет в объектное хранилище, возвращает URL. Message Service ссылается на вложения по URL — не хранит бинарные данные сам.

---

### Search Service

**Домен:** полнотекстовый поиск по истории сообщений  
**Хранилище:** Elasticsearch

Подписывается на `message.created`, `message.updated`, `message.deleted` и поддерживает индекс актуальным. Message Service при поисковых запросах ходит в Search Service.

---

## Поток данных — отправка сообщения

1. Клиент отправляет `POST /api/v1/chats/{chat_id}/messages` в Message Service через API Gateway.
2. API Gateway валидирует JWT, инжектит `user_id`.
3. Message Service сохраняет сообщение в PostgreSQL + пишет запись в `outbox_events` — в одной транзакции.
4. Outbox worker вычитывает запись и публикует `message.created` в Kafka (топик партиционирован по `chat_id`).
5. Realtime Gateway потребляет `message.created`, находит активные WebSocket-соединения участников чата, пушит им событие.
6. Клиент-получатель получает сообщение через WebSocket, отправляет подтверждение доставки.
7. Realtime Gateway публикует `receipt.delivered` в топик `receipt.events`.
8. Message Service потребляет `receipt.events`, обновляет статус доставки в БД.

---

## Поток данных — подключение клиента

1. Клиент устанавливает WebSocket-соединение к Realtime Gateway, передаёт JWT.
2. Gateway валидирует токен, регистрирует соединение в Redis (`gw:session:{user_id}`, `gw:conn:{connection_id}`).
3. Gateway публикует `presence.events` (online) в Kafka.
4. При разрыве соединения или истечении heartbeat — удаляет запись из Redis, публикует presence offline.

---

## Хранение данных

### Горячее хранилище

- **PostgreSQL** — чаты, сообщения, участники. Основное хранилище. Партиционирование таблицы `messages` по времени (monthly).
- **Redis** — presence, сессии, маршрутизация соединений, кэш последних сообщений чата (LRU), rate-limit counters.

### Холодное хранилище

Сообщения и вложения старше 30 дней архивируются в S3-compatible object storage. Сведения об архивированных партициях фиксируются в таблице `archived_partitions`. При запросе архивной истории Message Service проксирует запрос в холодное хранилище.

---

## API Gateway

Envoy или Traefik перед всеми сервисами. Отвечает за:

- Терминацию TLS
- Валидацию JWT и инжект `user_id` / `roles` в заголовки
- Rate limiting (Token Bucket через Redis)
- Маршрутизацию запросов к нужному сервису
- Circuit breaking (опционально)

Сервисы не занимаются TLS-терминацией сами — доверяют заголовкам от Gateway внутри кластера.

---

## Масштабирование

Все сервисы горизонтально масштабируемы и stateless (кроме Realtime Gateway, у которого есть ephemeral state соединений в Redis).

- **Chat Service, Message Service** — несколько реплик за балансировщиком, stateless.
- **Realtime Gateway** — несколько узлов; маршрутизация соединений через Redis: любой узел знает, на каком узле сидит нужный пользователь, и может проксировать сообщение.
- **Kafka** — партиционирование по `chat_id` обеспечивает порядок и параллелизм одновременно.
- **PostgreSQL** — read replicas для тяжёлых read-запросов (история).

---

## Observability

Каждый сервис обязан:

- Экспортировать метрики в формате Prometheus (`/metrics`)
- Писать структурированные JSON-логи (stdout)
- Инструментировать трейсы через OpenTelemetry SDK

Инфраструктура сбора:

| Что | Чем |
|---|---|
| Метрики | Prometheus → Grafana |
| Трейсы | OpenTelemetry → Jaeger / Tempo |
| Логи | Filebeat / Promtail → ELK / Loki → Grafana |
| Алерты | Prometheus Alertmanager → Slack / PagerDuty |

Обязательные дашборды: latency (p50/p95/p99), error rate, throughput, Kafka consumer lag по каждому топику.

---

## Безопасность

- TLS everywhere — снаружи терминируется на Gateway, внутри кластера — mTLS (опционально через service mesh).
- JWT/OAuth2 — все внешние запросы аутентифицированы.
- RBAC — сервисные API закрыты по ролям.
- Шифрование at-rest — для PII и вложений в объектном хранилище.
- Rate limiting — на уровне Gateway, per-user и per-API-key.

---

## Деплой

Kubernetes. Каждый сервис — отдельный Deployment с независимым скейлингом. CI/CD pipeline: сборка → тесты → деплой. Health checks: liveness и readiness пробы для каждого сервиса.
