# tf-rabbit

Один узел RabbitMQ 4.1 с vhost `tf` в сети `think-fast-net`.
RabbitMQ здесь — для команд и задач, которые должны дойти **ровно одному** получателю:
запросы прогноза и команды модели (`tf-bff` → `tf-model`), уведомления для почты и Telegram.
Потоки данных сюда не идут, они в `tf-kafka`. Бизнес-логики в контейнере нет.

## Состав

| Файл | Назначение |
|---|---|
| `docker-compose.yml` | `tf-rabbit` — брокер; `tf-rabbit-init` — одноразовый контейнер, загружает топологию и пользователей; `tf-rabbit-smoke` — ручная проверка (профиль `test`) |
| `definitions.json` | Топология: vhost, exchange, очереди, привязки, политики (TTL, DLX, лимиты) |
| `users.conf` | Пользователи сервисов и их права |
| `rabbitmq.conf` | Настройки брокера: пороги алармов по памяти и диску |
| `scripts/init.sh` | Применяет `definitions.json` и `users.conf` через HTTP API, идемпотентен |
| `scripts/smoke-test.py` | Проверка критериев приёмки |

## Запуск

### 1. Секреты — в Vault

Все пароли RabbitMQ лежат в Vault стенда по пути `secret/tf/rabbit`, файла `.env` с паролями нет.
Список — в [secrets.conf](../secrets.conf), общий порядок работы — в [README.md](../README.md).

| Переменная | Что это |
|---|---|
| `TF_RABBIT_ADMIN_PASSWORD` | Пароль администратора `admin`. Применяется **только при первом старте** пустого тома |
| `TF_RABBIT_BFF_PASSWORD` | Пароль `tf-bff` |
| `TF_RABBIT_MODEL_PASSWORD` | Пароль `tf-model` |
| `TF_RABBIT_EMAIL_PASSWORD` | Пароль `tf-notify-email` (контейнер почты) |
| `TF_RABBIT_TELEGRAM_PASSWORD` | Пароль `tf-notify-telegram` (Telegram-бот) |

Сгенерировать недостающие (на сервере стенда, из корня репозитория):

```bash
scripts/secrets.sh init rabbitmq
```

### 2. Выкатка

Обычно — GitHub Actions: изменения в `rabbitmq/` при пуше в `dev`/`prod` выкатываются на свой стенд
(`.github/workflows/deploy-rabbitmq.yml`). Вручную на сервере:

```bash
docker network create think-fast-net   # если сети ещё нет
TF_STAND=<dev|prod> VAULT_TOKEN=<токен> scripts/deploy.sh rabbitmq
```

Для ручных команд `docker compose` в папке `rabbitmq` сначала загрузить секреты в оболочку:

```bash
eval "$(../scripts/secrets.sh env rabbitmq)"
docker compose up tf-rabbit-init
```

`tf-rabbit-init` ждёт, пока healthcheck брокера станет `healthy`, загружает топологию, создаёт
пользователей и завершается с кодом 0 — статус `Exited (0)` это норма. Повторный запуск ничего
не дублирует: exchange, очереди и привязки уже есть, политики, пароли и права перезаписываются
значениями из файлов и Vault.

Данные (очереди, сообщения, пользователи) лежат в именованном томе `tf-rabbit-data` и переживают
пересоздание контейнера. Удаляет их только `docker compose down -v` или `docker volume rm tf-rabbit-data`.

## Топология

Черновик по ТЗ — **сверить с таблицей «RabbitMQ» на главной вкладке**.

| Exchange | Тип | Routing key | Очередь | TTL | Лимит длины |
|---|---|---|---|---|---|
| `tf.model.commands` | topic | любой (`#`) | `tf.model.commands` | 1 час | 10 000 |
| `tf.notifications` | direct | `email` | `tf.notify.email` | 24 часа | 10 000 |
| `tf.notifications` | direct | `telegram` | `tf.notify.telegram` | 24 часа | 10 000 |
| `tf.dlx` | fanout | — | `tf.dlq` | без TTL | 100 000 |

- Все очереди — **quorum**, durable. Quorum-очереди всегда пишут сообщения на диск; публикующие
  сервисы всё равно ставят `delivery_mode=2` (persistent).
- У рабочих очередей dead-letter exchange — `tf.dlx`. Сообщение уходит в `tf.dlq`, если:
  - потребитель отклонил его без повторной постановки (`reject`/`nack` с `requeue=false`);
  - потребитель 5 раз вернул его в очередь (`requeue=true`) — `delivery-limit: 5`;
  - истёк TTL;
  - очередь переполнена: самое старое сообщение вытесняется в `tf.dlq` (`overflow: drop-head`).
- Причина попадания в DLQ видна в заголовке `x-death` сообщения.
- TTL, DLX и лимиты заданы **политиками**, а не аргументами очередей: их можно менять без пересоздания очереди.

## Пользователи и права

| Пользователь | Публикует в | Читает из |
|---|---|---|
| `tf-bff` | `tf.model.commands`, `tf.notifications` | — |
| `tf-model` | — | `tf.model.commands` |
| `tf-notify-email` | — | `tf.notify.email` |
| `tf-notify-telegram` | — | `tf.notify.telegram` |
| `admin` | всё (администратор, только для обслуживания) | всё |

Пользователь `guest` не создаётся (вместо него при первом старте создаётся `admin`), а если
появится — `tf-rabbit-init` его удалит.

Права `configure` ни у одного сервиса нет: **сервисы не создают очереди и exchange сами**.
В клиентских библиотеках отключите автоматическое объявление топологии или объявляйте очереди
пассивно (`passive=true`). Иначе при попытке объявить очередь брокер ответит `ACCESS_REFUSED`,
а при объявлении с другими аргументами — `PRECONDITION_FAILED`.

## Подключение сервисов

| Параметр | Значение |
|---|---|
| Хост | `tf-rabbit` (только из `think-fast-net`) |
| Порт | `5672` (AMQP 0-9-1) |
| vhost | `tf` |
| Пользователь / пароль | из таблицы выше / переменная из Vault (`scripts/secrets.sh get <ПЕРЕМЕННАЯ>`) |

Рекомендации:

- Публикующим: `delivery_mode=2`, `publisher confirms`, флаг `mandatory` — чтобы узнать, что сообщение никуда не попало.
- Потребителям: ручное подтверждение (`auto_ack=false`), `prefetch` 1–10. Успех — `ack`.
  Временная ошибка — `nack` с `requeue=true` (после 5 попыток сообщение уйдёт в DLQ).
  Сообщение, которое никогда не обработается, — сразу `reject` с `requeue=false`.

## Уведомления: почта и Telegram

Потребители живут в этом репозитории: [mailing/](../mailing/README.md) — контейнер `tf-mail`,
[telegram/](../telegram/README.md) — `tf-tg`. Публикует `tf-bff`; ТЗ для него с примером на .NET —
[docs/notify-tz/tf-bff.md](../docs/notify-tz/tf-bff.md).

| Кто | Учётка брокера | Пароль в Vault | Что делает |
|---|---|---|---|
| `tf-bff` | `tf-bff` | `rabbit/bff` → `TF_RABBIT_BFF_PASSWORD` | публикует в `tf.notifications` |
| `tf-mail` | `tf-notify-email` | `rabbit/email` → `TF_RABBIT_EMAIL_PASSWORD` | читает `tf.notify.email` |
| `tf-tg` | `tf-notify-telegram` | `rabbit/telegram` → `TF_RABBIT_TELEGRAM_PASSWORD` | читает `tf.notify.telegram` |

### Как публиковать (tf-bff)

- exchange **`tf.notifications`**, routing key **`email`** или **`telegram`** — по сообщению на канал;
  нужно письмо и Telegram — два сообщения с одним `notice_id`;
- `content_type=application/json`, UTF-8, `delivery_mode=2`, publisher confirms, `mandatory=true`;
- exchange и очереди **не объявлять** (прав `configure` нет).

```json
{
  "schema": 1,
  "notice_id": "0b6f3c1e-2f0a-4c55-9a55-3f1d6c0e8a11",
  "ticket_id": 1042,
  "kind": "fact",
  "subject": "Загазованность: объект 5122",
  "text": "Канал 196771 «Газовая охрана». Заявка 1042.",
  "to": { "emails": ["dispatcher@example.com"], "usernames": ["ivan_petrov"], "chat_ids": [-1001234567890] },
  "request_id": "e81b07c4f2a9"
}
```

| Поле | Обязательно | Что это |
|---|---|---|
| `notice_id` | да | UUID уведомления. Повтор с тем же `notice_id` не отправится второй раз тем, кому уже ушло (сутки) |
| `subject` | да | тема письма / жирная строка в Telegram, до 255 символов; переводы строк заменяются пробелом |
| `text` | да | текст, до 20 000 символов; для Telegram тема + текст — не длиннее 4096 |
| `to.emails` | для `email` | адреса; отправляются пачками по 50 |
| `to.usernames` | для `telegram` (или `chat_ids`) | имя пользователя Telegram; `chat_id` tf-tg берёт из «Старта» у бота |
| `to.chat_ids` | для `telegram` (или `usernames`) | `chat_id` группы (число) или `@канал` |
| `ticket_id`, `kind`, `request_id` | нет | попадают в лог потребителя для поиска (`notify.sent` / `notify.failed`) |
| `schema` | нет | версия формата, сейчас `1` |

Потребитель отвечает брокеру так: `ack` — отправлено; `reject` (сразу в `tf.dlq`) — сообщение не
разобрать (не JSON, нет `notice_id`, нет адресатов, адрес с ошибкой) или не ушло никому по постоянной
причине; `nack` с повтором — SMTP или Telegram недоступны, до 5 попыток, потом `tf.dlq`.
Неотправленное за 24 часа (TTL) тоже уходит в `tf.dlq`.

## Management UI

**Решение: доступ только по SSH-туннелю.** Порты на хост не публикуются, через веб-сервер
UI не выставляется — меньше поверхность атаки, не нужны отдельная авторизация и сертификат.

На сервере временно открыть порт UI только на `127.0.0.1` (контейнер-прокси живёт, пока открыт терминал):

```bash
docker run --rm -it --network think-fast-net -p 127.0.0.1:15672:15672 \
  alpine/socat tcp-listen:15672,fork,reuseaddr tcp:tf-rabbit:15672
```

На своей машине:

```bash
ssh -L 15672:127.0.0.1:15672 <пользователь>@<сервер>
```

Открыть `http://localhost:15672`, войти как `admin`. После работы — `Ctrl+C` в обоих терминалах.
Локально (Docker Desktop) достаточно первой команды.

## Как добавить очередь

1. Согласовать в таблице «RabbitMQ».
2. В `definitions.json` добавить очередь (с `"x-queue-type": "quorum"`), привязку и, если нужно, exchange.
3. Если у очереди свои TTL/лимиты — добавить политику; для `tf.notify.*` существующая политика подхватит её сама.
4. Выдать права в `users.conf`.
5. Применить: выкатка (пуш в ветку стенда) или `docker compose up tf-rabbit-init` с загруженными секретами.

Удаление очереди или exchange из `definitions.json` **не удаляет** их из брокера — это делается
вручную в UI или командой `rabbitmqctl` (см. ниже). Аналогично с пользователями из `users.conf`.

## Как изменить TTL и лимиты

Поменять значения в разделе `policies` файла `definitions.json` и выполнить
`docker compose up tf-rabbit-init`. Политика применяется к существующим очередям сразу,
без пересоздания и без потери сообщений.

| Что | Поле политики |
|---|---|
| Время жизни сообщения | `message-ttl` (мс): 1 час = 3600000, 24 часа = 86400000 |
| Максимум сообщений в очереди | `max-length` |
| Число повторов до DLQ | `delivery-limit` |

## Обслуживание

```bash
docker exec tf-rabbit rabbitmqctl list_queues -p tf name type messages messages_unacknowledged policy
docker exec tf-rabbit rabbitmqctl list_users
docker exec tf-rabbit rabbitmqctl list_permissions -p tf
docker exec tf-rabbit rabbitmq-diagnostics status

# сменить пароль admin (пароль из Vault применяется только при первом старте):
# 1) scripts/secrets.sh rotate TF_RABBIT_ADMIN_PASSWORD
# 2) docker exec -i tf-rabbit rabbitmqctl change_password admin "$(scripts/secrets.sh get TF_RABBIT_ADMIN_PASSWORD)"
# 3) выкатить rabbitmq

# удалить пользователя, убранного из users.conf
docker exec tf-rabbit rabbitmqctl delete_user <имя>

# очистить DLQ после разбора
docker exec tf-rabbit rabbitmqctl purge_queue -p tf tf.dlq
```

## Как посмотреть сообщения в очереди

### Сколько сообщений лежит

```bash
docker exec tf-rabbit rabbitmqctl list_queues -p tf name messages_ready messages_unacknowledged
```

| Колонка | Что значит |
|---|---|
| `messages_ready` | ждут потребителя |
| `messages_unacknowledged` | выданы потребителю, но ещё не подтверждены (`ack`) |

Пример: после `smoke-test publish` у `tf.notify.email` должно быть `messages_ready = 1`,
после `smoke-test check` — `0`, а у `tf.dlq` на время проверки — `1`.

### Что внутри сообщения

Через management UI (как открыть — раздел «Management UI»):
**Queues and Streams** → нужная очередь → блок **Get messages**.

- **Ack mode: Nack message requeue true** — посмотреть и вернуть сообщение в очередь.
  У quorum-очереди это засчитывается как попытка доставки: после 5 таких просмотров
  (`delivery-limit`) сообщение уйдёт в `tf.dlq`. Для рабочих очередей смотрите осторожно.
- **Ack mode: Automatic ack** — забрать сообщение из очереди насовсем (удобно для разбора `tf.dlq`).

У сообщения из `tf.dlq` в заголовке `x-death` видно, откуда оно пришло (`queue`) и почему
(`reason`: `rejected` — отклонено потребителем, `delivery_limit` — исчерпаны повторы,
`expired` — истёк TTL, `maxlen` — очередь переполнена).

## Ограничения одного узла

- Quorum-очереди на одном узле не дают отказоустойчивости: пока узел перезапускается, публикация
  и чтение недоступны (клиенты должны переподключаться). Тип quorum выбран, чтобы при переходе на
  три узла не пересоздавать очереди.
- Сообщения в DLQ без TTL; очередь ограничена 100 000 сообщений, дальше вытесняются самые старые.
- Трафик AMQP внутри `think-fast-net` не шифруется.

## Healthcheck

Один HTTP-запрос `wget` к `/api/health/checks/local-alarms` внутри контейнера: отвечает, только
если узел работает и нет алармов по памяти (60% от `mem_limit` = ~600 МБ) и диску (свободно < 1 ГБ).
Erlang CLI (`rabbitmq-diagnostics`) не запускается, поэтому проверка почти ничего не стоит.
Раз в 30 секунд, в первую минуту после старта — раз в 5 секунд.

## Проверка критериев приёмки

Запускать при остановленном `tf-mail` (`docker stop tf-mail`, после — `docker start tf-mail`):
tестовое сообщение идёт в `tf.notify.email`, и потребитель забрал бы его раньше проверки.
Контейнер `tf-rabbit-smoke` при первом запуске ставит библиотеку `pika` из интернета.

```bash
# 0. Секреты в оболочку (compose требует все переменные даже для logs)
eval "$(../scripts/secrets.sh env rabbitmq)"

# 1. Топология: список очередей и политик
docker compose logs tf-rabbit-init

# 2. Сообщение переживает перезапуск, отклонённое уходит в tf.dlq
docker compose run --rm tf-rabbit-smoke publish          # печатает marker
docker restart tf-rabbit
docker compose run --rm tf-rabbit-smoke check <marker>

# 3. Отказ в доступе: tf-model не публикует в tf.notifications, чужие очереди не читаются, guest не входит
docker compose run --rm tf-rabbit-smoke deny

# 4. Порты не опубликованы
docker port tf-rabbit          # пустой вывод
```
