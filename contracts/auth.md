# Auth Contract

## Общее

Аутентификация реализована через JWT (JSON Web Tokens). Валидация токена происходит
**на уровне API Gateway** — сервисы не валидируют токен самостоятельно, они доверяют
заголовкам, проставленным Gateway.

---

## JWT

### Алгоритм подписи

`RS256` — асимметричная подпись. Auth Service владеет приватным ключом, все остальные
компоненты используют публичный ключ для верификации.

Публичный ключ доступен по: `https://auth.example.com/.well-known/jwks.json`

### Структура токена

**Header:**
```json
{
  "alg": "RS256",
  "typ": "JWT",
  "kid": "key-id-v1"
}
```

**Payload (claims):**
```json
{
  "sub":   "7b9c1d2e-3f4a-5b6c-7d8e-9f0a1b2c3d4e",
  "iat":   1717200000,
  "exp":   1717203600,
  "jti":   "550e8400-e29b-41d4-a716-446655440000",
  "roles": ["user"],
  "type":  "access"
}
```

| Claim | Тип | Описание |
|---|---|---|
| `sub` | uuid | UUID пользователя. Основной идентификатор. |
| `iat` | unix ts | Время выпуска токена |
| `exp` | unix ts | Время истечения токена |
| `jti` | uuid | Уникальный идентификатор токена (для revocation) |
| `roles` | string[] | Роли пользователя: `user`, `admin`, `moderator` |
| `type` | string | `access` или `refresh` |

### TTL

| Тип токена | TTL |
|---|---|
| Access token | 1 час |
| Refresh token | 30 дней |

---

## Поток аутентификации

```
Client → POST /auth/login → Auth Service
Auth Service → { access_token, refresh_token }

Client → GET /api/v1/... 
  Authorization: Bearer <access_token>

API Gateway → валидирует подпись JWT → проставляет заголовки:
  X-User-Id:    <sub>
  X-User-Roles: <roles через запятую>

Сервис получает запрос с уже проставленными заголовками.
```

### Обновление токена

```
Client → POST /auth/refresh
  { "refresh_token": "..." }

Auth Service → { access_token, refresh_token }
```

---

## Заголовки от Gateway к сервисам

API Gateway после валидации JWT проставляет следующие заголовки во все upstream-запросы:

| Заголовок | Значение | Пример |
|---|---|---|
| `X-User-Id` | UUID пользователя из `sub` | `7b9c1d2e-3f4a-5b6c-7d8e-9f0a1b2c3d4e` |
| `X-User-Roles` | Роли через запятую из `roles` | `user,admin` |
| `X-Request-Id` | UUID запроса для трейсинга | `3fa85f64-5717-4562-b3fc-2c963f66afa6` |

Сервисы **обязаны** читать `X-User-Id` из заголовка. Парсить и валидировать JWT самостоятельно не нужно.

Если `X-User-Id` отсутствует — запрос пришёл в обход Gateway. Сервис должен вернуть 401.

---

## WebSocket

JWT передаётся в query-параметре при установке соединения:

```
wss://api.example.com/ws?token=<access_token>
```

Realtime Gateway валидирует токен самостоятельно при handshake (до апгрейда соединения),
используя публичный ключ из JWKS endpoint.

При истечении токена во время активного соединения — Gateway закрывает соединение
с кодом `4000` (Token Expired). Клиент обновляет токен и переподключается.

---

## Межсервисные вызовы

Если один сервис вызывает другой напрямую (например, Message Service проверяет членство в чате
через Chat Service), запрос должен содержать служебный токен:

```
Authorization: Bearer <service_token>
X-Service-Name: message-service
```

Service token — отдельный JWT с `type: service`, выдаётся Auth Service для каждого сервиса.
Роль в таком токене: `service`.

Рекомендуемый payload service token:

```json
{
  "sub": "message-service",
  "iat": 1717200000,
  "exp": 1717203600,
  "roles": ["service"],
  "type": "service",
  "service_name": "message-service"
}
```

Сервис-получатель проверяет:
- наличие `X-Service-Name`
- роль `service` в токене
- совпадение `X-Service-Name` и `service_name` claim, если claim присутствует
