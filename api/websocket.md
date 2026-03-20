# WebSocket Protocol — Notification / Realtime Gateway

## Общее

Realtime Gateway предоставляет WebSocket-соединение для доставки событий клиенту в реальном времени.
Клиент устанавливает одно постоянное соединение и получает через него все события: новые сообщения,
обновления статусов, изменения presence.

**Технология:** стандартный WebSocket (RFC 6455).  
**Формат сообщений:** JSON, UTF-8.  
**Адрес:** `wss://api.example.com/ws` (production), `ws://localhost:8082/ws` (local).

---

## Установка соединения

### URL и аутентификация

Соединение устанавливается с передачей JWT-токена в query-параметре:

```
wss://api.example.com/ws?token=<jwt>
```

Токен валидируется сервисом при handshake. Если токен невалиден или отсутствует — сервер
отклоняет соединение с HTTP 401 до апгрейда до WebSocket.

> Альтернативный вариант — передача токена в заголовке `Authorization` при handshake,
> если это поддерживается клиентской библиотекой. Query-параметр является основным способом.

### Последовательность при подключении

1. Клиент инициирует WebSocket handshake с токеном.
2. Сервер валидирует JWT, извлекает `user_id`.
3. Сервер регистрирует соединение в Redis: `gw:session:{user_id}` → `node_id:connection_id`.
4. Сервер публикует `presence.events` (online) в Kafka.
5. Сервер отправляет клиенту сообщение `connected` с деталями сессии.
6. Соединение установлено, клиент начинает получать события.

### Сообщение `connected`

Сервер отправляет сразу после успешного handshake:

```json
{
  "type": "connected",
  "id": "ws_550e8400-e29b-41d4-a716-446655440000",
  "payload": {
    "connection_id": "conn_7f3a2b1c",
    "user_id": "7b9c1d2e-3f4a-5b6c-7d8e-9f0a1b2c3d4e",
    "server_time": "2024-06-01T10:00:00Z"
  }
}
```

---

## Формат сообщений

Все сообщения (в обе стороны) имеют единую обёртку:

```json
{
  "type": "<тип события>",
  "id": "<uuid>",
  "payload": { }
}
```

| Поле | Тип | Описание |
|---|---|---|
| `type` | string | Тип события. Определяет структуру `payload`. |
| `id` | string | Уникальный идентификатор сообщения. Используется для ack и дедупликации. |
| `payload` | object | Данные события. Структура зависит от `type`. |

---

## События — сервер → клиент

### `message.new`

Новое сообщение в одном из чатов пользователя.

```json
{
  "type": "message.new",
  "id": "evt_a1b2c3d4",
  "payload": {
    "message": {
      "id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
      "chat_id": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
      "sender_id": "8c0d2e3f-4a5b-6c7d-8e9f-0a1b2c3d4e5f",
      "content_type": "text",
      "text": "Привет!",
      "attachment": null,
      "reply_to_id": null,
      "sequence_number": 42,
      "is_edited": false,
      "created_at": "2024-06-01T10:00:00Z"
    }
  }
}
```

### `message.updated`

Сообщение было отредактировано.

```json
{
  "type": "message.updated",
  "id": "evt_b2c3d4e5",
  "payload": {
    "message": {
      "id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
      "chat_id": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
      "sender_id": "8c0d2e3f-4a5b-6c7d-8e9f-0a1b2c3d4e5f",
      "content_type": "text",
      "text": "Привет, исправленный текст!",
      "sequence_number": 42,
      "is_edited": true,
      "edited_at": "2024-06-01T10:05:00Z",
      "created_at": "2024-06-01T10:00:00Z"
    }
  }
}
```

### `message.deleted`

Сообщение было удалено.

```json
{
  "type": "message.deleted",
  "id": "evt_c3d4e5f6",
  "payload": {
    "chat_id": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
    "message_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "sequence_number": 42,
    "deleted_at": "2024-06-01T10:10:00Z"
  }
}
```

### `receipt.updated`

Изменился статус доставки или прочтения сообщения.
Событие имеет две формы payload: per-message для `delivered` и aggregate для `read`.

#### `receipt.updated` for `delivered`

```json
{
  "type": "receipt.updated",
  "id": "evt_d4e5f6a7",
  "payload": {
    "chat_id": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
    "message_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "user_id": "7b9c1d2e-3f4a-5b6c-7d8e-9f0a1b2c3d4e",
    "status": "delivered",
    "updated_at": "2024-06-01T10:01:00Z"
  }
}
```

#### `receipt.updated` for `read`

```json
{
  "type": "receipt.updated",
  "id": "evt_e4f5a6b7",
  "payload": {
    "chat_id": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
    "message_id": null,
    "user_id": "7b9c1d2e-3f4a-5b6c-7d8e-9f0a1b2c3d4e",
    "status": "read",
    "last_read_sequence_number": 42,
    "updated_at": "2024-06-01T10:01:00Z"
  }
}
```

| Поле | `delivered` | `read` |
|---|---|---|
| `chat_id` | обязательно | обязательно |
| `message_id` | обязательно | `null` |
| `user_id` | обязательно | обязательно |
| `status` | `delivered` | `read` |
| `last_read_sequence_number` | отсутствует | обязательно |
| `updated_at` | обязательно | обязательно |

`status` — одно из: `delivered`, `read`.
Gateway формирует это событие из Kafka-топика `receipt.events`:
- `receipt.delivered` → per-message `receipt.updated`
- `receipt.read` → aggregate `receipt.updated`

### `presence.updated`

Изменился online-статус пользователя.

```json
{
  "type": "presence.updated",
  "id": "evt_e5f6a7b8",
  "payload": {
    "user_id": "8c0d2e3f-4a5b-6c7d-8e9f-0a1b2c3d4e5f",
    "status": "online",
    "last_seen_at": null
  }
}
```

| `status` | Описание |
|---|---|
| `online` | Пользователь подключён прямо сейчас |
| `offline` | Пользователь отключился |

`last_seen_at` — время последнего выхода (UTC, ISO8601). Null если статус `online`.

Сервер отправляет это событие только для пользователей, с которыми у клиента есть общие чаты.

### `chat.updated`

Изменились метаданные чата (название, аватар, состав участников).

```json
{
  "type": "chat.updated",
  "id": "evt_f6a7b8c9",
  "payload": {
    "chat_id": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
    "updated_at": "2024-06-01T10:00:00Z",
    "changes": ["title", "members"]
  }
}
```

`changes` — массив строк с именами изменившихся полей. Клиент по этому событию должен
перезапросить данные чата через REST API Chat Service.

### `typing.started` / `typing.stopped`

Пользователь начал или прекратил печатать. Отправляется только если клиент сам отправил
`typing.start` (см. ниже).

```json
{
  "type": "typing.started",
  "id": "evt_a7b8c9d0",
  "payload": {
    "chat_id": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
    "user_id": "8c0d2e3f-4a5b-6c7d-8e9f-0a1b2c3d4e5f",
    "started_at": "2024-06-01T10:00:00Z"
  }
}
```

```json
{
  "type": "typing.stopped",
  "id": "evt_b8c9d0e1",
  "payload": {
    "chat_id": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
    "user_id": "8c0d2e3f-4a5b-6c7d-8e9f-0a1b2c3d4e5f"
  }
}
```

Если клиент начал печатать, но `typing.stop` не прислал — сервер автоматически генерирует
`typing.stopped` через 5 секунд после последнего `typing.start`.

### `error`

Сервер отправляет при ошибке обработки входящего сообщения от клиента.

```json
{
  "type": "error",
  "id": "evt_c9d0e1f2",
  "payload": {
    "ref_id": "msg_123",
    "code": "invalid_payload",
    "message": "Field 'chat_id' is required"
  }
}
```

`ref_id` — `id` из сообщения клиента, которое вызвало ошибку. Null если ошибка не привязана
к конкретному сообщению.

### `pong`

Ответ на `ping` от клиента (см. раздел Heartbeat).

```json
{
  "type": "pong",
  "id": "evt_d0e1f2a3",
  "payload": {
    "server_time": "2024-06-01T10:00:30Z"
  }
}
```

---

## События — клиент → сервер

### `ack`

Подтверждение получения события от сервера. Клиент обязан отправлять `ack` для событий
`message.new`, `message.updated`, `message.deleted`.

На основе `ack` сервер публикует событие `receipt.delivered` в топик `receipt.events`.

```json
{
  "type": "ack",
  "id": "msg_client_001",
  "payload": {
    "event_id": "evt_a1b2c3d4"
  }
}
```

`event_id` — `id` из подтверждаемого события сервера.

### `typing.start`

Клиент сообщает, что пользователь начал печатать.

```json
{
  "type": "typing.start",
  "id": "msg_client_002",
  "payload": {
    "chat_id": "3fa85f64-5717-4562-b3fc-2c963f66afa6"
  }
}
```

Сервер рассылает `typing.started` остальным участникам чата.  
Клиент должен повторять это сообщение каждые 3–4 секунды пока пользователь печатает.

### `typing.stop`

Клиент сообщает, что пользователь прекратил печатать.

```json
{
  "type": "typing.stop",
  "id": "msg_client_003",
  "payload": {
    "chat_id": "3fa85f64-5717-4562-b3fc-2c963f66afa6"
  }
}
```

### `ping`

Клиентский heartbeat. Клиент отправляет каждые 30 секунд для поддержания соединения.

```json
{
  "type": "ping",
  "id": "msg_client_004",
  "payload": {
    "client_time": "2024-06-01T10:00:00Z"
  }
}
```

Сервер отвечает `pong`.

---

## Heartbeat и таймауты

| Параметр | Значение | Описание |
|---|---|---|
| Ping интервал | 30 сек | Клиент отправляет `ping` каждые 30 сек |
| Ping таймаут | 10 сек | Если `pong` не пришёл за 10 сек — соединение считается мёртвым |
| Typing auto-stop | 5 сек | Сервер автоматически рассылает `typing.stopped` если не было `typing.start` 5 сек |
| Idle таймаут | 120 сек | Сервер закрывает соединение если нет ни одного сообщения 120 сек |
| Max message size | 64 KB | Максимальный размер одного WS-сообщения |

---

## Переподключение (Reconnect)

Клиент обязан реализовать автоматическое переподключение при разрыве соединения.

### Алгоритм

1. Соединение разорвано.
2. Клиент ждёт `initial_delay` перед первой попыткой.
3. При каждой неудачной попытке задержка увеличивается по формуле:
   `delay = min(initial_delay * 2^attempt, max_delay) + jitter`
4. После успешного переподключения — запросить пропущенные события.

### Рекомендуемые параметры

| Параметр | Значение |
|---|---|
| `initial_delay` | 1 сек |
| `max_delay` | 60 сек |
| `jitter` | random(0, 1000) мс |
| Максимум попыток | без ограничений |

### Восстановление пропущенных событий

После переподключения клиент должен запросить историю через REST API Message Service,
используя последний известный `sequence_number`:

```
GET /api/v1/chats/{chat_id}/history?after={last_sequence_number}
```

Это гарантирует, что ни одно сообщение не будет потеряно при разрыве.

---

## Закрытие соединения

### Коды закрытия (WebSocket Close Codes)

| Код | Константа | Описание |
|---|---|---|
| 1000 | Normal Closure | Нормальное закрытие по инициативе клиента или сервера |
| 1001 | Going Away | Сервер перезапускается / клиент уходит со страницы |
| 1008 | Policy Violation | Невалидный токен или токен истёк. Переподключение только с новым токеном. |
| 1011 | Internal Error | Внутренняя ошибка сервера. Клиент должен переподключиться. |
| 4000 | Token Expired | JWT истёк. Клиент должен обновить токен и переподключиться. |
| 4001 | Token Invalid | JWT невалиден. Клиент должен пройти re-auth. |
| 4002 | Duplicate Connection | Обнаружено второе активное соединение для того же пользователя. Предыдущее закрыто. |
| 4003 | Rate Limited | Клиент превысил лимит сообщений. Переподключение через 30 сек. |

При получении кода `4000` или `4001` клиент **не должен** переподключаться автоматически —
сначала необходимо обновить токен через Auth Service.

---

## Маршрутизация соединений (внутренняя)

Realtime Gateway может работать в нескольких репликах. Для корректной доставки событий
нужному пользователю используется Redis как routing table.

### Структура Redis

```
gw:session:{user_id}     Hash  { node_id, connection_id, connected_at }  TTL: 5 min (обновляется heartbeat)
gw:conn:{connection_id}  Hash  { user_id, node_id, connected_at }        TTL: 5 min
gw:presence:{user_id}    String  "online"                                TTL: 65 sec (обновляется ping)
```

### Алгоритм доставки события конкретному пользователю

1. Gateway получает событие из Kafka (например, `message.created`).
2. Для каждого участника чата читает `gw:session:{user_id}` из Redis.
3. Если запись есть и `node_id` совпадает с текущим узлом — отправляет напрямую через WS.
4. Если `node_id` другой — публикует сообщение в Redis Pub/Sub канал `gw:node:{node_id}`,
   тот узел доставляет клиенту.
5. Если записи нет — пользователь offline, триггерится push-уведомление (опционально).

---

## Подписки

Клиент автоматически получает события для всех чатов, в которых состоит пользователь.
Явной подписки на чаты не требуется — сервер определяет релевантные чаты через локальный кэш,
поддерживаемый событиями `chat.events`, а при холодном старте может:
- вызвать `GET /api/v1/internal/users/{user_id}/chats` для первичного набора чатов пользователя
- вызвать `GET /api/v1/internal/chats/{chat_id}/snapshot` при cache miss по конкретному чату

Presence-события (`presence.updated`) приходят только для пользователей из общих чатов.

---

## Rate Limiting

| Ограничение | Значение |
|---|---|
| Максимум WS-соединений на пользователя | 1 |
| Максимум входящих сообщений от клиента | 60 сообщений / мин |
| Максимум `typing.start` | 1 раз в 3 сек на чат |

При превышении лимита сервер закрывает соединение с кодом `4003`.

---

## Пример полного сценария

### Сценарий: пользователь A отправляет сообщение пользователю B

```
A → REST POST /api/v1/chats/{chat_id}/messages
      { content_type: "text", text: "Привет!" }

Message Service → сохраняет в PostgreSQL → пишет в outbox_events
Outbox worker → публикует message.created в Kafka

Realtime Gateway ← потребляет message.created из Kafka
Gateway → читает gw:session:{user_B_id} из Redis
Gateway → отправляет B через WebSocket:

  Server → B:
  {
    "type": "message.new",
    "id": "evt_a1b2c3d4",
    "payload": {
      "message": {
        "id": "...",
        "chat_id": "...",
        "sender_id": "user_A_id",
        "text": "Привет!",
        "sequence_number": 42,
        ...
      }
    }
  }

B → Server (ack):
  {
    "type": "ack",
    "id": "msg_b_001",
    "payload": { "event_id": "evt_a1b2c3d4" }
  }

Gateway → публикует `receipt.delivered` в топик `receipt.events`
Message Service ← потребляет receipt.events → обновляет статус в БД

Gateway → отправляет A через WebSocket:
  {
    "type": "receipt.updated",
    "id": "evt_b2c3d4e5",
    "payload": {
      "chat_id": "...",
      "message_id": "...",
      "user_id": "user_B_id",
      "status": "delivered",
      "updated_at": "..."
    }
  }
```

### Сценарий: пользователь B читает сообщение

```
B → REST POST /api/v1/chats/{chat_id}/receipts/read
      { last_read_sequence_number: 42 }

Message Service → обновляет статусы → публикует `receipt.read` в топик `receipt.events`

Realtime Gateway ← потребляет событие
Gateway → отправляет A через WebSocket:
  {
    "type": "receipt.updated",
    "id": "evt_c3d4e5f6",
    "payload": {
      "chat_id": "...",
      "status": "read",
      "user_id": "user_B_id",
      "message_id": null,
      "last_read_sequence_number": 42,
      "updated_at": "..."
    }
  }
```

---

## Сводная таблица типов сообщений

| Тип | Направление | Описание | Требует ack |
|---|---|---|---|
| `connected` | S → C | Подтверждение подключения | Нет |
| `message.new` | S → C | Новое сообщение | **Да** |
| `message.updated` | S → C | Сообщение отредактировано | **Да** |
| `message.deleted` | S → C | Сообщение удалено | **Да** |
| `receipt.updated` | S → C | Статус доставки/прочтения изменился | Нет |
| `presence.updated` | S → C | Изменился online-статус пользователя | Нет |
| `chat.updated` | S → C | Изменились метаданные чата | Нет |
| `typing.started` | S → C | Пользователь начал печатать | Нет |
| `typing.stopped` | S → C | Пользователь прекратил печатать | Нет |
| `error` | S → C | Ошибка обработки входящего сообщения | Нет |
| `pong` | S → C | Ответ на ping | Нет |
| `ack` | C → S | Подтверждение получения события | — |
| `typing.start` | C → S | Пользователь начал печатать | — |
| `typing.stop` | C → S | Пользователь прекратил печатать | — |
| `ping` | C → S | Heartbeat | — |
