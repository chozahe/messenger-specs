# Errors Contract

## Общее

Все сервисы используют единый формат ошибок. Это позволяет клиенту обрабатывать
ошибки унифицированно вне зависимости от того, какой сервис их вернул.

---

## Формат

```json
{
  "error": {
    "code":    "<machine_readable_code>",
    "message": "<human readable description>",
    "details": { }
  }
}
```

| Поле | Тип | Обязательно | Описание |
|---|---|---|---|
| `error.code` | string | Да | Машиночитаемый код. Snake_case. Уникален в контексте сервиса. |
| `error.message` | string | Да | Описание на английском. Не показывается пользователю напрямую. |
| `error.details` | object | Нет | Дополнительные данные. Структура зависит от `code`. |

---

## HTTP статус коды

| Статус | Когда использовать |
|---|---|
| `400 Bad Request` | Синтаксически некорректный запрос (невалидный JSON, отсутствует body) |
| `401 Unauthorized` | Токен отсутствует, невалиден или истёк |
| `403 Forbidden` | Токен валиден, но прав недостаточно |
| `404 Not Found` | Ресурс не найден |
| `409 Conflict` | Конфликт состояния (дубликат, уже существует) |
| `422 Unprocessable Entity` | Запрос синтаксически корректен, но не проходит валидацию бизнес-логики |
| `429 Too Many Requests` | Превышен rate limit |
| `500 Internal Server Error` | Внутренняя ошибка. Клиент может повторить запрос. |
| `503 Service Unavailable` | Сервис недоступен (readiness probe упала). |

---

## Коды ошибок по сервисам

### Общие (все сервисы)

| Code | HTTP | Описание |
|---|---|---|
| `unauthorized` | 401 | Токен отсутствует или невалиден |
| `token_expired` | 401 | JWT истёк |
| `forbidden` | 403 | Недостаточно прав |
| `not_found` | 404 | Общий — ресурс не найден |
| `validation_error` | 422 | Ошибка валидации полей |
| `rate_limit_exceeded` | 429 | Превышен rate limit |
| `internal_error` | 500 | Внутренняя ошибка |

### Chat Service

| Code | HTTP | Описание |
|---|---|---|
| `chat_not_found` | 404 | Чат не найден |
| `member_not_found` | 404 | Участник не найден в этом чате |
| `direct_chat_already_exists` | 409 | Direct чат между этими пользователями уже существует |
| `cannot_modify_direct_chat` | 403 | Нельзя изменить direct чат (добавить участника, переименовать) |
| `cannot_remove_owner` | 422 | Нельзя удалить owner из чата напрямую |
| `owner_must_transfer_before_leave` | 422 | Owner должен передать роль перед выходом из чата |
| `cannot_transfer_owner_to_self` | 422 | Нельзя передать роль owner самому себе |
| `owner_transfer_target_invalid` | 422 | Роль owner можно передать только активному участнику group-чата |
| `members_limit_exceeded` | 422 | Превышен лимит участников (1000 для group) |

### Message Service

| Code | HTTP | Описание |
|---|---|---|
| `chat_not_found` | 404 | Чат не найден |
| `message_not_found` | 404 | Сообщение не найдено |
| `not_message_author` | 403 | Только автор может редактировать/удалять сообщение |
| `message_deleted` | 422 | Нельзя редактировать удалённое сообщение |
| `cannot_edit_attachment` | 422 | Нельзя редактировать сообщение с вложением |
| `reply_to_not_found` | 422 | Сообщение, на которое отвечают, не найдено |
| `reply_to_wrong_chat` | 422 | `reply_to_id` указывает на сообщение из другого чата |
| `cannot_send_system_message` | 422 | Клиент не может отправлять системные сообщения |
| `duplicate_message` | 409 | Сообщение с таким `Idempotency-Key` уже существует |
| `search_query_too_short` | 422 | Поисковый запрос слишком короткий (минимум 2 символа) |

---

## Формат `details` для `validation_error`

```json
{
  "error": {
    "code": "validation_error",
    "message": "Request validation failed",
    "details": {
      "fields": {
        "title":      "required for group chats",
        "member_ids": "must contain at least 1 element"
      }
    }
  }
}
```

Ключи в `fields` — имена полей из request body или query params.

---

## Формат `details` для `direct_chat_already_exists`

```json
{
  "error": {
    "code": "direct_chat_already_exists",
    "message": "Direct chat between these users already exists",
    "details": {
      "existing_chat_id": "3fa85f64-5717-4562-b3fc-2c963f66afa6"
    }
  }
}
```

---

## Формат `details` для `duplicate_message`

```json
{
  "error": {
    "code": "duplicate_message",
    "message": "Message with this idempotency key already exists",
    "details": {
      "existing_message_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
    }
  }
}
```

---

## Формат `details` для `rate_limit_exceeded`

```json
{
  "error": {
    "code": "rate_limit_exceeded",
    "message": "Too many requests, please slow down",
    "details": {
      "retry_after_seconds": 30
    }
  }
}
```

Дополнительно в заголовках ответа:
```
X-RateLimit-Limit:     60
X-RateLimit-Remaining: 0
X-RateLimit-Reset:     1717203600
```

---

## Правила для разработчиков

- Никогда не возвращать стектрейс или внутренние детали реализации в `message` или `details`.
- `message` — на английском, для логов и дебага, не для отображения пользователю.
- При ошибке 500 — логировать полный стектрейс на стороне сервиса, в ответе только `internal_error`.
- Если сущность не найдена — всегда 404, не 403 (не раскрывать факт существования).
  Исключение: если сущность существует, но у пользователя нет доступа — 403.
