# Redis Contract

## Общее

Redis используется Realtime Gateway как основное in-memory хранилище для ephemeral-данных.
Другие сервисы могут использовать Redis для кэширования — их ключи описаны отдельными секциями.

**Версия:** Redis 7.x  
**Режим:** Redis Cluster (минимум 3 мастера + 3 реплики) или managed service.  
**Сериализация значений:** JSON-строка если не указано иное.

---

## Конвенции именования ключей

Формат: `<сервис>:<домен>:<идентификатор>`

Примеры:
- `gw:session:7b9c1d2e` — ключ Realtime Gateway
- `msg:cache:chat:3fa85f64` — ключ Message Service

Разделитель — двоеточие `:`.  
Нельзя использовать пробелы, слэши, кавычки в именах ключей.

---

## Realtime Gateway

### `gw:session:{user_id}`

**Тип:** Hash  
**TTL:** 5 минут (обновляется при каждом `ping` от клиента)  
**Назначение:** маршрутизация событий к нужному узлу Gateway

```
HSET gw:session:{user_id}
  connection_id  "conn_7f3a2b1c"
  node_id        "node-01"
  connected_at   "2024-06-01T10:00:00Z"
```

| Поле | Описание |
|---|---|
| `connection_id` | Идентификатор WS-соединения |
| `node_id` | Идентификатор узла Gateway, на котором открыто соединение |
| `connected_at` | Время подключения (ISO8601 UTC) |

При переподключении запись перезаписывается целиком.  
При отключении — удаляется явно. TTL — страховка на случай краша узла.

---

### `gw:conn:{connection_id}`

**Тип:** Hash  
**TTL:** 5 минут (обновляется при каждом `ping`)  
**Назначение:** обратный lookup — по connection_id найти user_id

```
HSET gw:conn:{connection_id}
  user_id       "7b9c1d2e-3f4a-5b6c-7d8e-9f0a1b2c3d4e"
  node_id       "node-01"
  connected_at  "2024-06-01T10:00:00Z"
```

---

### `gw:presence:{user_id}`

**Тип:** String  
**TTL:** 65 секунд (обновляется при каждом `ping`, интервал ping — 30 сек, запас — 2x+5)  
**Назначение:** быстрая проверка online-статуса без чтения `gw:session`

```
SET gw:presence:{user_id} "online" EX 65
```

Значение всегда `"online"`. Отсутствие ключа = пользователь offline.

---

### `gw:node:{node_id}` (Pub/Sub)

**Тип:** Redis Pub/Sub канал  
**Назначение:** доставка событий между узлами Gateway (когда соединение на другом узле)

Каждый узел Gateway подписывается на канал `gw:node:{собственный_node_id}`.

Формат сообщения в канале:

```json
{
  "connection_id": "conn_7f3a2b1c",
  "event": {
    "type": "message.new",
    "id": "evt_a1b2c3d4",
    "payload": { }
  }
}
```

---

### `gw:dedup:{event_id}`

**Тип:** String
**TTL:** 24 часа
**Назначение:** дедупликация событий из Kafka (идемпотентность consumer'а)

```
SET gw:dedup:{event_id} "1" EX 86400 NX
```

Если `SET NX` вернул `nil` — событие уже обрабатывалось, пропустить.

---

### `gw:typing:{chat_id}:{user_id}`

**Тип:** String  
**TTL:** 5 секунд (auto-expire = typing.stopped)  
**Назначение:** отслеживание состояния "печатает"

```
SET gw:typing:{chat_id}:{user_id} "1" EX 5
```

Ключ создаётся при получении `typing.start` от клиента.  
Истечение TTL = пользователь перестал печатать (сервер рассылает `typing.stopped`).  
При `typing.stop` от клиента — удаляется явно.

---

## Message Service

### `msg:cache:chat_messages:{chat_id}`

**Тип:** List  
**TTL:** 10 минут  
**Назначение:** кэш последних сообщений чата для быстрой первоначальной загрузки

```
LPUSH msg:cache:chat_messages:{chat_id} <json_message>
LTRIM msg:cache:chat_messages:{chat_id} 0 49   # хранить последние 50
EXPIRE msg:cache:chat_messages:{chat_id} 600
```

Инвалидируется при любом изменении сообщений в чате (новое сообщение, редактирование, удаление).

---

### `msg:ratelimit:{user_id}`

**Тип:** String (counter)  
**TTL:** 60 секунд (скользящее окно)  
**Назначение:** rate limiting отправки сообщений

```
INCR msg:ratelimit:{user_id}
EXPIRE msg:ratelimit:{user_id} 60   # только если ключ новый
```

Лимит: 60 сообщений в 60 секунд на пользователя.

---

### `msg:dedup:{idempotency_key}`

**Тип:** String
**TTL:** 24 часа
**Назначение:** дедупликация отправки сообщений по `Idempotency-Key`

```
SET msg:dedup:{idempotency_key} {message_id} EX 86400 NX
```

Значение — UUID созданного сообщения. При повторном запросе возвращается это сообщение.

---

## Chat Service

### `chat:dedup:{idempotency_key}`

**Тип:** String
**TTL:** 24 часа
**Назначение:** дедупликация create/add-member операций по `Idempotency-Key`

```
SET chat:dedup:{idempotency_key} <result_ref> EX 86400 NX
```

`result_ref` — идентификатор результата операции (`chat_id` или иной opaque reference,
по которому сервис может вернуть исходный ответ без повторного выполнения).

---

### `chat:member_check:{chat_id}:{user_id}`

**Тип:** String  
**TTL:** 5 минут  
**Назначение:** кэш проверки членства пользователя в чате (для Message Service)

```
SET chat:member_check:{chat_id}:{user_id} "1" EX 300
```

Инвалидируется при изменении состава участников чата (через событие `chat.updated` из Kafka).

---

## API Gateway

### `gw:ratelimit:{user_id}:{endpoint}`

**Тип:** String (counter)  
**TTL:** 60 секунд  
**Назначение:** глобальный rate limiting на уровне Gateway (Token Bucket через Lua)

Реализуется через Lua-скрипт в Redis для атомарности:

```lua
local key = KEYS[1]
local limit = tonumber(ARGV[1])
local window = tonumber(ARGV[2])
local current = redis.call('INCR', key)
if current == 1 then
  redis.call('EXPIRE', key, window)
end
return current
```

---

## Сводная таблица ключей

| Ключ | Тип | TTL | Сервис | Назначение |
|---|---|---|---|---|
| `gw:session:{user_id}` | Hash | 5 мин | Realtime Gateway | Маршрутизация соединений |
| `gw:conn:{connection_id}` | Hash | 5 мин | Realtime Gateway | Обратный lookup |
| `gw:presence:{user_id}` | String | 65 сек | Realtime Gateway | Online-статус |
| `gw:node:{node_id}` | Pub/Sub | — | Realtime Gateway | Межузловая доставка |
| `gw:dedup:{event_id}` | String | 24 ч | Realtime Gateway | Дедупликация Kafka-событий |
| `gw:typing:{chat_id}:{user_id}` | String | 5 сек | Realtime Gateway | Статус "печатает" |
| `msg:cache:chat_messages:{chat_id}` | List | 10 мин | Message Service | Кэш последних сообщений |
| `msg:ratelimit:{user_id}` | String | 60 сек | Message Service | Rate limit отправки |
| `msg:dedup:{idempotency_key}` | String | 24 ч | Message Service | Дедупликация сообщений |
| `chat:dedup:{idempotency_key}` | String | 24 ч | Chat Service | Дедупликация create/add-member операций |
| `chat:member_check:{chat_id}:{user_id}` | String | 5 мин | Chat Service | Кэш членства |
| `gw:ratelimit:{user_id}:{endpoint}` | String | 60 сек | API Gateway | Глобальный rate limit |

---

## Правила для разработчиков

- Никогда не читать ключи чужого сервиса напрямую — только через API этого сервиса.
- Всегда выставлять TTL. Ключи без TTL запрещены.
- При инвалидации кэша — удалять ключ явно (`DEL`), не ждать истечения TTL.
- Не хранить в Redis данные, потеря которых недопустима — Redis не является источником правды.
- При старте сервиса не полагаться на наличие данных в Redis — уметь работать при холодном кэше.
