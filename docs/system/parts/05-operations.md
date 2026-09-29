# Часть V. Руководство по эксплуатации

## 5.1. Здоровье сервисов

| Сервис | Снаружи | На сервере | Признак беды |
|---|---|---|---|
| сайт | `GET https://<домен>/` → 200 | `docker ps` → `tf-nginx Up` | 502 на всех `/api/*` — сервисы не запущены или Vault запечатан |
| tf-auth | `GET /api/auth/health` → `Healthy` | `docker ps` → `(healthy)` | `/login` → 500 — Redis; перезапуски — Vault/ключ JWT |
| tf-bff | `GET /api/bff/health/live` → 200, `/health/ready` → `{database, jwks}` | `docker logs tf-bff` | `503 auth_service_unavailable`, в логе `Fact message dropped` |
| tf-funnel | `GET /api/funnel/health` → `{"ok":true,…}` | `/status` с токеном: `unavailable`, `archive_errors`, `silent` | `last_accepted` старый, `source_silent: true` |
| tf-model | `GET /api/ml/health` → `last_hour` не старше ~1 ч | `docker logs tf-model`: строка `такт …` каждый час | `такт: пропущено часов N`, `OOMKilled` |
| tf-audit | — | `/health` внутри сети: `last_write`, `dead`, `lost`; `XINFO GROUPS audit` | растут `dead`/`lost`, `pending` |
| tf-mail / tf-tg | — | `docker ps` → `(healthy)`; `docker logs --tail 20` | `unhealthy` — нет брокера или не подошёл пароль SMTP / токен бота |
| vault | `vault.greefob.ru/v1/sys/health` (dev) | `docker exec vault vault status` | `Sealed true` |
| tf-postgres / tf-redis / tf-kafka / tf-rabbit | — | `docker ps` → `(healthy)` | `unhealthy`, аларм памяти/диска у RabbitMQ |
| сертификат | `openssl s_client -connect <домен>:443` → `notAfter` | `docker logs tf-certbot` | меньше 30 дней до конца |

## 5.2. Логи

Централизованного сбора логов нет. Смотреть: `docker logs --tail 100 -f <контейнер>`.

| Сервис | Формат | Что искать |
|---|---|---|
| tf-bff | Serilog JSON | `[vault-entrypoint]`, `Consuming fact alerts`, `Failed to publish`, `Fact message dropped after 4 attempts` |
| tf-auth | текст .NET | `[vault-entrypoint] …загружено`, `Failed login attempt`, `Login rate limit exceeded`, `RedisConnectionException` |
| tf-funnel | slog, текст | `воронка слушает :8000`, `шина молчит`, `замолчали каналы`, `статус N каналов не записан`, `жду распечатывания Vault` |
| tf-model | текст | `такт …`, `команда <id> <вид>: ok`, `приём Kafka упал`, `такт: пропущено часов` |
| tf-audit | текст | `запись аудита стоит`, `в audit:dead` |
| tf-mail / tf-tg | текст + JSON событий | `вход как … — ok`, `RabbitMQ: читаю`, `notify.sent`, `notify.failed`, `повтор` |
| init-контейнеры | текст | `docker logs tf-kafka-init` / `tf-rabbit-init` — применённая топология |

Перед тем как пересылать логи, удалите из них всё, что похоже на `hvs.…`, ключи распечатывания,
`VAULT_SECRET_ID`, пароли, заголовки `Cookie:` и `Authorization:`.

## 5.3. Что наблюдать (мониторинга и метрик нет)

| Что | Как | Норма |
|---|---|---|
| Очереди RabbitMQ | `docker exec tf-rabbit rabbitmqctl list_queues -p tf name messages_ready messages_unacknowledged` | `tf.notify.*` и `tf.model.commands` около 0, `tf.dlq` не растёт |
| DLQ RabbitMQ | UI → `tf.dlq` → Get messages (Automatic ack — забрать), заголовок `x-death` | пусто или разобрано |
| Kafka DLQ и лаг | `kafka-consumer-groups.sh --describe --group tf-model-ingest` / `tf-bff-facts` (kafka/README.md) | лаг небольшой |
| Аудит | `XINFO GROUPS audit`, `XLEN audit:dead` | `pending` и `lag` небольшие |
| Диск | `df -h /`, `docker system df`, `du -sh` томов `tf-funnel-data`, `tf-ml-work`, `postgres_backups` | запас больше 20 % |
| Память | `docker stats --no-stream` | нет `OOMKilled` в `docker inspect` |
| Поток данных | `/api/funnel/health` → `last_accepted`, `/api/ml/health` → `last_hour` | свежие |
| Бэкапы | `ls -lt $TF_INFRA_DIR/hashicorp/backups`, `docker run --rm -v postgres_backups:/b alpine ls -l /b` | файл за последние сутки |
| Сертификат | `notAfter` | дольше 30 дней |

## 5.4. Типовые операции

### Секреты

| Операция | Команда | Применение |
|---|---|---|
| что есть / чего нет | `scripts/secrets.sh status [папка]` | — |
| сгенерировать недостающие | `scripts/secrets.sh init [папка]` | выкатить папку |
| своё значение (SMTP, токен бота, `sub`) | `scripts/secrets.sh set <КЛЮЧ>` | выкатить или перезапустить сервис |
| передать владельцу сервиса | `scripts/secrets.sh get <КЛЮЧ>` | только через менеджер паролей |
| ротация генерируемого | `scripts/secrets.sh rotate <КЛЮЧ>` | см. таблицу ниже |

| Секрет | Как применяется после ротации |
|---|---|
| `POSTGRES_PASSWORD`, `TF_PG_*` | выкатка `postgree` (`ALTER USER`, `create-schema`), затем перезапуск потребителей (секреты читаются при старте) |
| `TF_KAFKA_*_PASSWORD` | выкатка `kafka` (брокер перезапустится), затем перезапуск потребителей |
| `KAFKA_CLUSTER_ID` | **никогда** |
| `TF_RABBIT_ADMIN_PASSWORD` | сначала `rabbitmqctl change_password admin`, потом выкатка |
| прочие `TF_RABBIT_*` | выкатка `rabbitmq` (`tf-rabbit-init`), затем перезапуск потребителей |
| `TF_REDIS_PASSWORD` | выкатка `redis`, затем перезапуск **всех** клиентов Redis |
| `TF_AUTH_JWT_PRIVATE_KEY_B64` | `docker restart tf-auth`: все пользователи разлогинятся; потребители ключа (воронка, модель, аудит, BFF) перечитают его по истечении кеша или после перезапуска |
| пара AppRole сервиса | `service-credentials <сервис>` (без `--rotate`) → новый секрет в GitHub → выкатка сервиса |

### Прочее

| Операция | Как |
|---|---|
| Новый секрет сервиса | строка в `secrets.conf` → `secrets.sh init`/`set` на **каждом** стенде → путь в `services.conf` (если путь новый) → `setup.sh apply` |
| Новый сервис с Vault | строка в `services.conf` → `setup.sh apply` → `service-credentials` → Environment репозитория |
| Новый топик / ACL | `kafka/topics.conf`, `kafka/acls.conf` → выкатка `kafka` |
| Новая очередь / права | `rabbitmq/definitions.json`, `users.conf` → выкатка `rabbitmq` (удаление из файлов **не** удаляет из брокера) |
| Новая схема БД | строка в `postgree/db/schemas.conf` + два пароля в `secrets.conf` → `secrets.sh init postgree` → выкатка `postgree` |
| Снять блокировку входа | `redis-cli --scan --pattern 'auth:login-rate:*'` → `DEL` (или подождать 60 с) |
| Первый суперпользователь tf-auth | `POST /register`, затем `UPDATE auth."Users" SET "SuperUser" = true …` (tf-auth §9) |
| Первый администратор BFF | сидинг `001_seed_initial_data.sql` (tf-bff §8) |
| Очистить DLQ RabbitMQ | после разбора: `rabbitmqctl purge_queue -p tf tf.dlq` |
| Очистить архив воронки вручную | `docker run --rm -v tf-funnel-data:/data alpine sh -c 'du -sh /data/archive/*'`, затем удалить каталоги дней |
| Скорость эмулятора (dev) | повтор `deploy-emulator-dev.yml` с `speed` или `POST /api/speed` изнутри сети (tf-emulator §8) |
| кто подключил Telegram, `chat_id` групп | `docker exec tf-tg python chats.py` |
| Бэкап Vault вручную | `VAULT_TOKEN_FILE=$TF_INFRA_DIR/hashicorp/.backup-token sh $TF_INFRA_DIR/hashicorp/scripts/backup.sh` |

## 5.5. Ресурсы

| Контейнер | Лимит памяти | Растёт на диске |
|---|---|---|
| tf-model | dev 4 ГБ, prod 2500 МБ (`TF_MEMORY` 2 / 1 ГБ) | `tf-ml-work`: горячий журнал 100 суток + журнал прогнозов |
| tf-funnel | 512 МБ (`GOMEMLIMIT` 400 МБ) | `tf-funnel-data`: около 10–30 байт на событие, 14 дней на prod |
| tf-bff | 512 МБ, 1 CPU | — |
| tf-auth | **не задан** (Argon2 — 64 МБ на проверку пароля) | — |
| tf-audit | 256 МБ | PostgreSQL `audit.*` растёт бесконечно |
| tf-emulator | 384 МБ | — |
| tf-mail, tf-tg | 256 МБ | — |
| tf-rabbit | 1 ГБ (аларм на 60 %) | том очередей |
| tf-kafka, tf-postgres, tf-redis, vault, tf-front | не заданы | тома данных; бэкапы Postgres 7 дней |

## 5.6. Правила безопасности эксплуатации

- ❌ Удалять тома (`down -v`, `volume rm`, `prune --volumes`).
- ❌ Перезапускать `vault` без необходимости и выкатывать `hashicorp` из CI: после этого его нужно
  распечатывать.
- ❌ `vault operator init` на работающем стенде.
- ❌ Держать root-токен дольше, чем идёт работа, и хранить его где-либо, кроме менеджера паролей.
- ❌ `--rotate` у ролей без плана обновить секреты во всех репозиториях.
- ❌ Отправлять ключи, токены, пароли, `VAULT_SECRET_ID` в чаты, issue, коммиты, скриншоты.
- ❌ Собирать образы на dev-сервере.
- ❌ Выкатывать эмулятор или задавать `TF_FUNNEL_PULL` на prod.
- ❌ Править файлы в `TF_INFRA_DIR` руками: ими управляет выкатка.
- ✅ Работать в терминале с `set +H`; вводить секреты через `read -rs`; проверять конфиг nginx до выкатки
  web-server; хранить креды dev и prod раздельно.
