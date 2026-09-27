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

## Кому слать: chat_id

Бот не может написать первым. Человек открывает бота и нажимает «Старт», группа — добавляет бота
и пишет в ней сообщение. Затем на сервере:

```bash
docker exec tf-tg python chats.py
```

— чаты, писавшие боту за сутки, с `chat_id` (у групп он отрицательный). Эти `chat_id` BFF кладёт
в `to.chat_ids` уведомления. Канал — `@имя_канала`, бот должен быть в нём администратором.

## Поведение

Как у `tf-mail`: `ack` — ушло хотя бы в один чат (заблокировавшие бота — в логе числом); `reject` —
сообщение не разобрать, длиннее 4096 символов или не ушло никуда по постоянной причине; Telegram
недоступен или ограничил частоту — повтор (до 5 попыток). Повтор не шлёт второй раз туда, куда уже ушло.

```bash
docker logs -f tf-tg
```

Тесты: `pip install -r requirements.txt -r requirements-dev.txt && python -m pytest -q tests`.
