# tf-tg

Сервис уведомлений в Telegram: читает очередь RabbitMQ `tf.notify.telegram` и отправляет сообщения
от бота (Bot API `sendMessage`, тема жирным, под ней текст). HTTP-ручек и портов нет.

```
tf-bff ──► exchange tf.notifications ──(ключ telegram)──► tf.notify.telegram ──► tf-tg ──► api.telegram.org
```

Формат сообщения — [rabbitmq/README.md](../rabbitmq/README.md#уведомления-почта-и-telegram).
Устроен так же, как [mailing/](../mailing/README.md) (`tf-mail`); `app/broker.py` — общий, копия в обеих папках.

## Секреты

| Ключ | Путь | Откуда |
|---|---|---|
| `TF_TG_BOT_TOKEN` | `app/tf-tg` | **руками**: токен от [@BotFather](https://t.me/BotFather) (`/newbot`) |
| `TF_RABBIT_TELEGRAM_PASSWORD` | `rabbit/telegram` | уже есть: учётка брокера `tf-notify-telegram` |
| `TF_REDIS_PASSWORD` | `redis` | уже есть |

Завести токен — веб-интерфейс Vault (путь `tf/app/tf-tg`, ключ `TF_TG_BOT_TOKEN`) или на сервере
`scripts/secrets.sh set TF_TG_BOT_TOKEN`; затем Actions → **deploy telegram** → Run workflow.

## Выкатка

Workflow `deploy-telegram.yml` или вручную:

```bash
TF_STAND=<dev|prod> VAULT_TOKEN=<токен> scripts/deploy.sh telegram
```

Пока токена нет в Vault, выкатка падает с `секрета TF_TG_BOT_TOKEN нет в Vault`. Токен не подошёл —
контейнер `unhealthy`, очередь не читается, в логе — что исправить.

## Кому слать

Бот не может написать первым, а человеку Bot API не шлёт по `@username` — только по `chat_id`.

**Люди — по username.** Человек указывает имя пользователя Telegram в профиле Thinkfaster, открывает
бота и нажимает «Старт». tf-tg сам читает обновления бота (`getUpdates`, [app/links.py](app/links.py)):
на `/start` запоминает `chat_id` и отвечает «Готово», на `/stop` или блокировку бота — забывает.
BFF кладёт имена в `to.usernames`, `chat_id` tf-tg подставляет при отправке. Кто не нажал «Старт» —
ему не уйдёт, остальным уйдёт.

Ключи Redis (без TTL, у `tf-redis` включён AOF); `tg:user:*` и `tg:bot` читает tf-bff для профиля:

| Ключ | Что |
|---|---|
| `tg:user:<username>` | `chat_id`; имя в нижнем регистре, без `@` |
| `tg:bot` | имя бота (из `getMe` при старте) — ссылка `t.me/<бот>` в профиле |
| `tg:chats` | hash `chat_id` → `{type, name, username}` — все, кто писал боту |
| `tg:updates:offset` | следующий `update_id` |

**Группы и каналы — по chat_id.** Группа добавляет бота и пишет в ней сообщение; канал — бот
администратор, адрес `@имя_канала`. Список чатов, писавших боту, и кто из людей подключён:

```bash
docker exec tf-tg python chats.py
```

У групп `chat_id` отрицательный — его BFF кладёт в `to.chat_ids`. Обновления бота читает только
tf-tg: второй процесс с тем же токеном (или включённый webhook) получит 409, в логе будет
`getUpdates: … Conflict`. `TG_POLL=off` — только отправка, без «Старта».

## Поведение

Как у `tf-mail`: `ack` — ушло хотя бы в один чат (заблокировавшие бота — в логе числом); `reject` —
сообщение не разобрать, длиннее 4096 символов или не ушло никуда по постоянной причине; Telegram
недоступен или ограничил частоту — повтор (до 5 попыток). Повтор не шлёт второй раз туда, куда уже ушло.

```bash
docker logs -f tf-tg
```

Тесты: `pip install -r requirements.txt -r requirements-dev.txt && python -m pytest -q tests`.
