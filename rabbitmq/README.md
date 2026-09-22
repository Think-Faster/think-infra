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
| `.env.template` | Шаблон `.env` с паролями |
| `scripts/init.sh` | Применяет `definitions.json` и `users.conf` через HTTP API, идемпотентен |
| `scripts/smoke-test.py` | Проверка критериев приёмки |

## Запуск

### 1. Заполнить `.env`

```bash
cd rabbitmq
cp .env.template .env
```

| Переменная | Что это |
|---|---|
| `TF_RABBIT_ADMIN_PASSWORD` | Пароль администратора `admin`. Задаётся **при первом старте** пустого тома |
| `TF_RABBIT_BFF_PASSWORD` | Пароль `tf-bff` |
| `TF_RABBIT_MODEL_PASSWORD` | Пароль `tf-model` |
| `TF_RABBIT_EMAIL_PASSWORD` | Пароль `tf-notify-email` (контейнер почты) |
| `TF_RABBIT_TELEGRAM_PASSWORD` | Пароль `tf-notify-telegram` (Telegram-бот) |

Пароли — только латиница и цифры, сгенерировать: `openssl rand -hex 24`.

### 2. Сохранить копию `.env` в Vault

Как для Kafka: копия лежит в Vault по пути `secret/tf/rabbit`, ключи совпадают с именами переменных.
Через веб-интерфейс Vault (`secret/` → **Create secret** → `tf/rabbit`) или из консоли:

```bash
docker exec -e VAULT_TOKEN=<токен> -e VAULT_ADDR=http://127.0.0.1:8200 vault \
  vault kv put secret/tf/rabbit $(grep -E '^[A-Z_]+=' .env | tr -d '\r')
```

Восстановить `.env` из Vault:

```bash
for key in TF_RABBIT_ADMIN_PASSWORD TF_RABBIT_BFF_PASSWORD TF_RABBIT_MODEL_PASSWORD TF_RABBIT_EMAIL_PASSWORD TF_RABBIT_TELEGRAM_PASSWORD; do
  echo "$key=$(docker exec -e VAULT_TOKEN=<токен> -e VAULT_ADDR=http://127.0.0.1:8200 vault vault kv get -field=$key secret/tf/rabbit)"
done > .env
```

### 3. Поднять RabbitMQ

```bash
docker network create think-fast-net   # если сети ещё нет
docker compose up -d
docker compose logs -f tf-rabbit-init  # итог: список очередей с политиками
```

`tf-rabbit-init` ждёт, пока healthcheck брокера станет `healthy`, загружает топологию, создаёт
пользователей и завершается с кодом 0 — статус `Exited (0)` это норма. Повторный запуск ничего
не дублирует: exchange, очереди и привязки уже есть, политики, пароли и права перезаписываются
значениями из файлов.

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
| Пользователь / пароль | из таблицы выше / переменная из `.env` |

Рекомендации:

- Публикующим: `delivery_mode=2`, `publisher confirms`, флаг `mandatory` — чтобы узнать, что сообщение никуда не попало.
- Потребителям: ручное подтверждение (`auto_ack=false`), `prefetch` 1–10. Успех — `ack`.
  Временная ошибка — `nack` с `requeue=true` (после 5 попыток сообщение уйдёт в DLQ).
  Сообщение, которое никогда не обработается, — сразу `reject` с `requeue=false`.

### Для владельцев почты и Telegram-бота

Передать владельцу (пароль — из `.env` / Vault, по защищённому каналу):

```
Хост:          tf-rabbit:5672 (контейнер должен быть в сети think-fast-net)
vhost:         tf
Почта:         пользователь tf-notify-email,    очередь tf.notify.email
Telegram:      пользователь tf-notify-telegram, очередь tf.notify.telegram
Права:         только чтение своей очереди; очереди не объявлять (или passive=true)
Подтверждение: ack — отправлено; nack requeue=true — повторить (не более 5 раз);
               reject requeue=false — не отправлять, сообщение уйдёт в tf.dlq
TTL:           24 часа, после этого неотправленное уведомление уходит в tf.dlq
```

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
5. Применить: `docker compose up tf-rabbit-init`.

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

# сменить пароль admin (пароль из .env действует только при первом старте):
docker exec tf-rabbit rabbitmqctl change_password admin <новый пароль>
# затем обновить TF_RABBIT_ADMIN_PASSWORD в .env и Vault и выполнить docker compose up -d

# удалить пользователя, убранного из users.conf
docker exec tf-rabbit rabbitmqctl delete_user <имя>

# очистить DLQ после разбора
docker exec tf-rabbit rabbitmqctl purge_queue -p tf tf.dlq
```

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

Запускать до подключения потребителя почты — тестовое сообщение идёт в `tf.notify.email`.
Контейнер `tf-rabbit-smoke` при первом запуске ставит библиотеку `pika` из интернета.

```bash
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
