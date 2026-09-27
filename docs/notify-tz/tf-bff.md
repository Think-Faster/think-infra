# Задание: tf-bff отправляет уведомления на почту через RabbitMQ

Для агента и разработчиков репозитория **tf-bff**. Файл самодостаточный — отдать целиком.

## 1. Что есть и что нужно

Письма рассылает сервис **`tf-mail`** (репозиторий tf.infra, папка `mailing/`): он читает очередь RabbitMQ
и отправляет письма через SMTP. HTTP API у него нет — **единственный способ отправить письмо: опубликовать
сообщение в RabbitMQ** в формате из раздела 3.

```
tf-bff ──publish──► exchange tf.notifications ──(routing key "email")──► очередь tf.notify.email ──► tf-mail ──► SMTP
                                                                               │ ошибка / 5 повторов / 24 ч
                                                                               ▼
                                                                            tf.dlq
```

Со стороны инфраструктуры всё готово: exchange, очередь, права `tf-bff` на публикацию, `tf-mail` запущен.
Нужно: в tf-bff сформировать сообщение по контракту и опубликовать его.

Telegram устроен так же (сервис `tf-tg`, routing key `telegram`) — раздел 6.

## 2. Подключение к RabbitMQ

| Параметр | Значение |
|---|---|
| Хост / порт | `tf-rabbit:5672` (контейнер в сети `think-fast-net`) |
| vhost | **`tf`** |
| Пользователь | **`tf-bff`** |
| Пароль | из Vault: путь `rabbit/bff`, ключ `TF_RABBIT_BFF_PASSWORD` — уже приходит в `RabbitMq__Password` (ТЗ tf-bff по Vault) |
| Права | только **публикация** в `tf.model.commands` и `tf.notifications`. Прав на создание нет |

**Не объявлять** exchange и очереди (`ExchangeDeclare`, `QueueDeclare`, `QueueBind`): брокер ответит
`ACCESS_REFUSED` и закроет канал. Топологию заводит инфраструктура. Если библиотека объявляет сама —
отключить; проверить существование можно только пассивно (`ExchangeDeclarePassive`).

## 3. Контракт сообщения

### 3.1. Публикация

| Параметр | Значение |
|---|---|
| Exchange | **`tf.notifications`** |
| Routing key | **`email`** (строго, в нижнем регистре) |
| `content_type` | `application/json` |
| Кодировка тела | UTF-8, без BOM |
| `delivery_mode` | `2` (persistent) |
| `message_id` | равен `notice_id` (удобно при разборе DLQ, сервис его не читает) |
| `mandatory` | `true` — если сообщение не попало ни в одну очередь, брокер вернёт его (`basic.return`) |
| Publisher confirms | включить; публикация успешна только после `ack` от брокера |

Одно сообщение = одно уведомление по одному каналу. Нужны и письмо, и Telegram — два сообщения
(ключи `email` и `telegram`), `notice_id` у них может совпадать.

### 3.2. Тело (JSON)

```json
{
  "schema": 1,
  "notice_id": "0b6f3c1e-2f0a-4c55-9a55-3f1d6c0e8a11",
  "ticket_id": 1042,
  "kind": "fact",
  "subject": "Загазованность: объект 5122",
  "text": "Канал 196771 «Газовая охрана».\nЗаявка 1042, открыта 27.09.2026 14:05.",
  "to": { "emails": ["dispatcher@example.com", "chief@example.com"] },
  "request_id": "e81b07c4f2a9"
}
```

| Поле | Обяз. | Тип | Правила | Зачем |
|---|---|---|---|---|
| `schema` | да* | число | всегда `1` | версия формата. *Сервис пока не проверяет, но слать обязательно |
| `notice_id` | **да** | строка | UUID (любой версии, рекомендуется v4), **новый на каждое уведомление** | защита от дублей, см. 3.3 |
| `subject` | **да** | строка | 1–255 символов, не из одних пробелов | тема письма. Переводы строк и повторные пробелы заменяются одним пробелом |
| `text` | **да** | строка | 1–20 000 символов, не из одних пробелов | тело письма. **Только простой текст**: HTML не поддерживается и уйдёт как есть, тегами. Перевод строки — `\n` |
| `to.emails` | **да** | массив строк | непустой; каждый элемент — корректный e-mail | адресаты. Регистр и дубли нормализуются сервисом |
| `ticket_id` | нет | число или строка | — | номер заявки — в лог `tf-mail` для поиска |
| `kind` | нет | строка | например, `fact`, `forecast` | тип уведомления — в лог |
| `request_id` | нет | строка | id входящего запроса BFF (`X-Request-ID`) | сквозная трассировка — в лог |

Любые другие поля игнорируются (можно добавлять свои для отладки — сервис их не читает).
`to.chat_ids` для почты не используется.

JSON Schema — для валидации в тестах tf-bff:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "tf.notifications / email, schema 1",
  "type": "object",
  "required": ["schema", "notice_id", "subject", "text", "to"],
  "properties": {
    "schema": { "const": 1 },
    "notice_id": { "type": "string", "format": "uuid" },
    "subject": { "type": "string", "minLength": 1, "maxLength": 255, "pattern": "\\S" },
    "text": { "type": "string", "minLength": 1, "maxLength": 20000, "pattern": "\\S" },
    "to": {
      "type": "object",
      "required": ["emails"],
      "properties": {
        "emails": { "type": "array", "minItems": 1, "items": { "type": "string", "format": "email" } }
      }
    },
    "ticket_id": { "type": ["integer", "string"] },
    "kind": { "type": "string" },
    "request_id": { "type": "string" }
  }
}
```

### 3.3. `notice_id` и повторы

- `tf-mail` помнит сутки, кому уже ушло письмо с данным `notice_id`. Повторная доставка того же сообщения
  (сбой, повтор публикации после таймаута confirm) **не отправит письмо второй раз** тем, кому оно ушло.
- Поэтому **при повторе публикации того же уведомления — тот же `notice_id`**, а **для нового уведомления —
  всегда новый**. Новое письмо с уже использованным `notice_id` тем же адресатам в течение суток молча
  не отправится.

### 3.4. Как сервис обработает сообщение

| Ситуация | Что будет |
|---|---|
| Всё корректно, SMTP принял | письмо отправлено; адреса, которые почтовый сервер отверг, — в логе `tf-mail` числом |
| Не JSON, нет/неверный `notice_id`, пустые `subject`/`text`, нет `to.emails`, **хотя бы один адрес с ошибкой** | сообщение сразу уходит в `tf.dlq`, **письмо не отправляется никому** |
| SMTP временно недоступен | повторы через 5, 15, 30, 60 с; после 5-й попытки — `tf.dlq` |
| Сообщение не обработано за 24 ч | `tf.dlq` |

Ответа в BFF нет: доставка асинхронная. Успешная публикация (confirm) значит «сообщение в очереди»,
а не «письмо доставлено».

## 4. Требования к tf-bff

1. **Проверять адреса до публикации.** Один некорректный адрес бракует всё сообщение. Некорректные —
   отбросить (и записать в свой лог) или не публиковать уведомление.
2. **Все адресаты одного сообщения видят друг друга** — это одно письмо, все в поле «Кому» (по 50 на письмо).
   Если получатели не должны видеть друг друга (внешние контакты) — отдельное сообщение на каждого адресата,
   у каждого свой `notice_id`.
3. Длины `subject` ≤ 255 и `text` ≤ 20 000 — обрезать на стороне BFF, иначе сообщение уйдёт в DLQ.
4. Публикация — с publisher confirms и `mandatory=true`. Нет `ack` / пришёл `basic.return` — ошибка
   публикации: повторить с **тем же** `notice_id` или сообщить об ошибке вызывающему.
5. Соединение с брокером держать долгоживущим (одно на приложение), каналы — не шарить между потоками
   одновременно. При разрыве — переподключение (у брокера один узел, при его перезапуске публикация
   на секунды недоступна).
6. Отправитель письма (адрес и имя «Think Faster — оповещения») задаёт `tf-mail`, из сообщения не меняется.

## 5. Пример на .NET (RabbitMQ.Client 7.x)

```csharp
using System.Text.Json;
using RabbitMQ.Client;

public sealed record EmailNotice(
    int Schema, Guid NoticeId, string Subject, string Text, NoticeTo To,
    object? TicketId = null, string? Kind = null, string? RequestId = null);

public sealed record NoticeTo(IReadOnlyList<string> Emails);

var json = new JsonSerializerOptions
{
    PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,     // notice_id, ticket_id, request_id
    DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
};

// Один раз при старте приложения
var factory = new ConnectionFactory
{
    HostName = "tf-rabbit", Port = 5672, VirtualHost = "tf",
    UserName = "tf-bff", Password = config["RabbitMq:Password"],
    AutomaticRecoveryEnabled = true,
};
var connection = await factory.CreateConnectionAsync("tf-bff");
var channel = await connection.CreateChannelAsync(new CreateChannelOptions(
    publisherConfirmationsEnabled: true, publisherConfirmationTrackingEnabled: true));

// Отправка
var notice = new EmailNotice(
    Schema: 1, NoticeId: Guid.NewGuid(),
    Subject: "Загазованность: объект 5122",
    Text: "Канал 196771 «Газовая охрана».\nЗаявка 1042.",
    To: new NoticeTo(["dispatcher@example.com"]),
    TicketId: 1042, Kind: "fact", RequestId: requestId);

var props = new BasicProperties
{
    ContentType = "application/json",
    ContentEncoding = "utf-8",
    DeliveryMode = DeliveryModes.Persistent,
    MessageId = notice.NoticeId.ToString(),
};

// С отслеживанием подтверждений ждёт ack брокера; nack или basic.return — исключение PublishException
await channel.BasicPublishAsync(
    exchange: "tf.notifications", routingKey: "email", mandatory: true,
    basicProperties: props, body: JsonSerializer.SerializeToUtf8Bytes(notice, json));
```

`SnakeCaseLower` превращает `To.Emails` в `"to": {"emails": [...]}`, `NoticeId` — в `"notice_id"`.
Проверить сериализацию тестом против JSON Schema из 3.2.

## 6. Telegram (тот же exchange)

Routing key **`telegram`**, сервис `tf-tg`. Тело то же, вместо `to.emails` — `to.chat_ids`:

```json
{ "schema": 1, "notice_id": "…", "subject": "…", "text": "…", "to": { "chat_ids": [123456789, -1001234567890] } }
```

- `chat_ids` — числа (`chat_id` человека или группы; у групп отрицательные) или строки `"@канал"`.
- `subject` + `text` вместе ≤ ~4 000 символов (предел Telegram 4096), иначе — `tf.dlq`.
- Человек должен сначала открыть бота и нажать «Старт»; `chat_id` дают администраторы инфраструктуры.

## 7. Как проверить

1. На dev опубликовать тестовое уведомление на свой адрес. Письмо приходит в течение минуты.
2. У администратора инфраструктуры: `docker logs tf-mail` — строка `notify.sent` с вашим `notice_id`
   и `request_id`. Если письма нет — строка `notify.failed` с причиной (`адрес почты с ошибкой`,
   `нет адресов почты`, `notice_id не uuid`, …).
3. Опубликовать то же сообщение ещё раз с тем же `notice_id` — второе письмо **не** приходит
   (в логе `уже отправлено`).
4. Опубликовать с адресом `не адрес` — письмо не приходит, сообщение в `tf.dlq`, в логе `notify.failed`.

## 8. Критерии приёмки

- [ ] tf-bff публикует в `tf.notifications` с ключом `email`, не объявляя exchange и очереди.
- [ ] Тело проходит JSON Schema из 3.2; `notice_id` новый на каждое уведомление и прежний при повторе.
- [ ] Publisher confirms и `mandatory=true` включены, ошибка публикации обрабатывается.
- [ ] Некорректные адреса отсекаются до публикации; длины обрезаются.
- [ ] Проверки из раздела 7 проходят на dev.
