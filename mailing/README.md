# tf-mail

Сервис почтовых уведомлений: читает очередь RabbitMQ `tf.notify.email` и отправляет письма через SMTP
(по умолчанию — Gmail с паролем приложения). HTTP-ручек и портов нет.

```
tf-bff ──► exchange tf.notifications ──(ключ email)──► tf.notify.email ──► tf-mail ──► SMTP
                                                          │ reject / 5 повторов / TTL 24 ч
                                                          ▼
                                                       tf.dlq
```

Формат сообщения и правила публикации — [rabbitmq/README.md](../rabbitmq/README.md#уведомления-почта-и-telegram).
Telegram — отдельный сервис [telegram/](../telegram/README.md) (`tf-tg`), устроен так же.

## Состав

| Файл | Назначение |
|---|---|
| `docker-compose.yml` | контейнер `tf-mail` в сети `think-fast-net`, образ собирается из этой папки |
| `app/main.py` | запуск: проверка входа на SMTP, чтение очереди |
| `app/broker.py` | чтение очереди: ack / reject / повтор, защита от второй отправки (Redis). **Копия** `telegram/app/broker.py` — менять оба |
| `app/notice.py` | разбор сообщения (`to.emails`) и отправка пачками по 50 адресатов |
| `app/mailer.py` | SMTP: STARTTLS (587) или SSL (465), вход, отправка |
| `app/settings.py` | настройки из переменных окружения |
| `tests/` | тесты без сети: `pip install -r requirements.txt -r requirements-dev.txt && python -m pytest -q tests` |

## Секреты

Все — в Vault стенда, в контейнер их подставляет `scripts/deploy.sh mailing` (как у остальных сервисов
этого репозитория). Список — [secrets.conf](../secrets.conf).

| Ключ | Путь | Откуда |
|---|---|---|
| `TF_MAIL_SMTP_HOST` | `app/tf-mail` | **руками**: `smtp.gmail.com` |
| `TF_MAIL_SMTP_PORT` | `app/tf-mail` | **руками**: `587` (STARTTLS); `465` — SSL |
| `TF_MAIL_SMTP_USER` | `app/tf-mail` | **руками**: адрес ящика, от которого уходят письма |
| `TF_MAIL_SMTP_PASSWORD` | `app/tf-mail` | **руками**: пароль приложения Google (16 букв; пробелы можно оставить) |
| `MAIL_FROM` | `stands/<стенд>.env` (не секрет) | адрес отправителя; пусто — `TF_MAIL_SMTP_USER` |
| `TF_RABBIT_EMAIL_PASSWORD` | `rabbit/email` | уже есть: учётка брокера `tf-notify-email` |
| `TF_REDIS_PASSWORD` | `redis` | уже есть |

Пароль приложения Gmail: аккаунт Google → Безопасность → двухэтапная аутентификация включена →
«Пароли приложений» → создать. Обычный пароль от почты SMTP Gmail не примет.

### Prod: почтовые порты закрыты — Resend на 2587

Хостинг prod (45.87.41.186) молча отбрасывает исходящие 25, 465 и 587 — и с хоста, и из docker; фаервол
самой машины их не режет (проверено 28.09). До Gmail письма не дойдут. Открыт порт Resend 2587 (STARTTLS
выбирается сам), код менять не нужно — только значения в `app/tf-mail`:

| Ключ | Значение |
|---|---|
| `TF_MAIL_SMTP_HOST` | `smtp.resend.com` |
| `TF_MAIL_SMTP_PORT` | `2587` |
| `TF_MAIL_SMTP_USER` | `resend` |
| `TF_MAIL_SMTP_PASSWORD` | ключ API Resend (`re_…`, права Sending access) |

Адрес отправителя — `MAIL_FROM=noreply@thinkfaster.ru` в `stands/prod.env`. Перед этим в Resend:
Domains → Add domain `thinkfaster.ru` → записи DKIM (TXT `resend._domainkey`) и SPF (MX и TXT на `send`)
добавить в DNS reg.ru → Verify. С неподтверждённого домена Resend отправителя отвергает.

### Как завести SMTP-секреты

**Через веб-интерфейс Vault** (`https://<VAULT_DOMAIN>`, см. [hashicorp/README.md](../hashicorp/README.md#веб-интерфейс)):
Method **Token** → личный токен → `secret/` → `tf/` → `app/` → **Create secret**, путь `tf/app/tf-mail`
(если его ещё нет) → четыре ключа из таблицы → **Save**. Если путь уже есть — **Create new version**,
старые ключи сохранятся в форме.

**Или на сервере**, из корня репозитория:

```bash
export VAULT_TOKEN=<личный токен tf-admin>
scripts/secrets.sh set TF_MAIL_SMTP_HOST          # спросит значение, на экран не выводит
scripts/secrets.sh set TF_MAIL_SMTP_PORT
scripts/secrets.sh set TF_MAIL_SMTP_USER
scripts/secrets.sh set TF_MAIL_SMTP_PASSWORD
scripts/secrets.sh status mailing                 # все ok
```

Затем выкатить: Actions → **deploy mailing** → Run workflow → ветка стенда.

## Выкатка

Пуш в `dev` / `prod` с изменениями в `mailing/` (или `scripts/`, `stands/`, `secrets.conf`) —
workflow `deploy-mailing.yml`. Вручную на сервере:

```bash
TF_STAND=<dev|prod> VAULT_TOKEN=<токен> scripts/deploy.sh mailing
```

Выкатка собирает образ и ждёт, пока контейнер станет `healthy` (соединение с брокером есть, очередь
читается). Пока SMTP-секреты не заведены, выкатка падает с `секрета TF_MAIL_SMTP_… нет в Vault` —
это ожидаемо, остальные сервисы не затрагиваются. В `bootstrap-stand.sh` сервис не входит по той же причине.

## Поведение

- **При старте** — вход на SMTP без отправки. Логин или пароль не подошли — очередь **не читается**,
  письма ждут в ней (TTL 24 ч), контейнер `unhealthy`, в логе — что исправить. Контейнер не
  перезапускается по кругу: Gmail блокирует вход после серии неудачных попыток.
- **Ответ брокеру:** `ack` — сервер принял письмо (адреса, которые он отверг, — в логе числом);
  `reject` — сообщение не разобрать или все адресаты отвергнуты → `tf.dlq`; сервер недоступен —
  повтор через 5, 15, 30, 60 с, на 5-й попытке — `reject`.
- **Повторы не дублируют письма:** кому уже ушло по `notice_id`, помнится сутки в Redis
  (`notify:sent:<notice_id>:email`).
- **Лог:** `notify.sent` / `notify.failed` — JSON с `notice_id`, `ticket_id`, темой, числом адресатов
  и причиной. Адресов и текста писем в логе нет.

```bash
docker logs -f tf-mail
docker inspect --format '{{.State.Health.Status}}' tf-mail
```

Принятое сервером письмо ещё не доставлено: о несуществующем ящике Gmail сообщает позже письмом
на `TF_MAIL_SMTP_USER`.
