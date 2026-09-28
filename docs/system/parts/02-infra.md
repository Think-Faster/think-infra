# Часть II. Инфраструктура (think-infra)

Источник: репозиторий think-infra, ветка `dev`. Подробности по каждому компоненту — в README его папки;
здесь — как всё устроено вместе, политики и то, чего нет в README.

## 2.1. Репозиторий

| Папка / файл | Что | Выкатка |
|---|---|---|
| `hashicorp/` | Vault: compose, `vault.hcl`, `services.conf` (роли сервисов), `scripts/setup.sh`, `scripts/backup.sh` | вручную (`deploy.sh hashicorp`), никогда из CI |
| `postgree/` | PostgreSQL 16, `db/schemas.conf`, контейнер `create-schema`, `backup.sh` | `deploy-postgree.yml` |
| `kafka/` | Kafka 4.0 KRaft, `topics.conf`, `acls.conf`, init-контейнер | `deploy-kafka.yml` |
| `rabbitmq/` | RabbitMQ 4.1, `definitions.json`, `users.conf`, init-контейнер | `deploy-rabbitmq.yml` |
| `redis/` | Redis 7 с паролем и AOF | `deploy-redis.yml` |
| `web-server/` | nginx + certbot, шаблоны `nginx.conf.template`, `vault.conf.template` | `deploy-web-server.yml` |
| `mailing/` | `tf-mail` | `deploy-mailing.yml` |
| `telegram/` | `tf-tg` | `deploy-telegram.yml` |
| `samba/` | файловый обмен, в выкатку не входит | — |
| `secrets.conf` | **единственный** список секретов: папка, путь Vault, ключ, генератор | — |
| `stands/dev.env`, `stands/prod.env` | несекретные настройки стенда | — |
| `scripts/deploy.sh` | выкатка одного сервиса на стенд | вызывается workflow или вручную |
| `scripts/secrets.sh` | управление секретами (`status/init/set/get/rotate/env/import/relocate`) | вручную на сервере |
| `scripts/bootstrap-stand.sh` | новый стенд одной командой | вручную |
| `scripts/lib/vault.sh` | общие функции, `SHARED_SECRETS` | — |
| `.github/workflows/deploy-*.yml`, `deploy.yml` | выкатка по пушу в `dev`/`prod` | раннер стенда |
| `.github/workflows/deploy-apps-prod.yml` | prod: инфраструктура + tf-auth, tf-bff, tf-audit с раннера prod | вручную / пуш файла |
| `docs/vault-tz/`, `docs/notify-tz/`, `docs/funnel-tz/` | ТЗ для репозиториев сервисов | — |
| `docs/vault-entrypoint.sh` | скрипт входа в Vault для контейнеров (tf-auth, tf-bff) | копируется в репозитории сервисов |
| `QUICK_START.md` | пошаговая инструкция без предварительных знаний | — |

## 2.2. Принципы

1. **Секреты — только в Vault своего стенда.** В git, в `stands/*.env`, в файлах на сервере и в GitHub их
   нет. Исключение — доступ к Vault: пары AppRole в GitHub Environments. `deploy.sh` отказывается
   работать, если в файле стенда есть ключ из `secrets.conf`.
2. **Один источник правды на тип настройки.** Секреты перечислены в `secrets.conf`, несекретные настройки
   стенда — в `stands/<стенд>.env`, роли сервисов — в `hashicorp/services.conf`, топики — в
   `kafka/topics.conf`, ACL — в `kafka/acls.conf`, топология RabbitMQ — в `definitions.json` и `users.conf`,
   схемы БД — в `postgree/db/schemas.conf`.
3. **Выкатка идемпотентна.** Повторный запуск ничего не ломает: init-контейнеры переприменяют топологию,
   права и пароли, `create-schema` приводит схемы к нужному виду.
4. **Минимум наружу.** Опубликованы только 80/443 nginx и, на dev, 5432. Всё остальное доступно только
   внутри `think-fast-net`.
5. **Каждой учётке — свой путь в Vault** (`kafka/bff`, `rabbit/model`, …). Права в Vault выдаются на путь
   целиком, поэтому сервис не видит пароли admin и чужих учёток.
6. **Тома не удаляются.** В `tf-vault-data`, `postgres_data`, `tf-kafka-data`, `tf-rabbit-data`,
   `tf-redis-data`, `tf-funnel-data`, `tf-ml-work` лежат данные. `down -v`, `volume rm` и `prune --volumes`
   запрещены.

## 2.3. Vault

### Развёртывание

- Контейнер `vault`, образ `hashicorp/vault:1.20.0`, хранилище raft в томе `tf-vault-data`, `ui = true`, без TLS.
- Порт `127.0.0.1:8200` на хосте и `http://vault:8200` в `think-fast-net`. Наружу — только через nginx
  (`VAULT_DOMAIN`, раздел 2.9) или по SSH-туннелю.
- **После каждого старта контейнера Vault запечатан.** Пока его не распечатают, сервисы, которым нужны
  секреты, ждут (vault-entrypoint — до 10 мин, tfkit/kit.go — `TF_VAULT_WAIT=900` с), а nginx на их маршрутах
  отдаёт `502`.
- Инициализация: 3 ключа распечатывания, порог 2 (`operator init -key-shares=3 -key-threshold=2`).
  Ключи показываются **один раз**. Восстановить их нельзя, можно только перевыпустить (rekey) двумя
  действующими.
- Хранилище секретов — KV v2 на `secret/`, все пути под `secret/tf/`.

### Политики и роли

| Политика | Права | Кто пользуется |
|---|---|---|
| `tf-deploy` | `read` на `secret/data/tf/*` | AppRole `tf-deploy` — CI и ручная выкатка инфраструктуры (`deploy.sh`) |
| `tf-admin` | `create/read/update/patch` на `secret/data/tf/*`, `read/list` на metadata, `list` на `secret/metadata/` | личные токены администраторов (`secrets.sh`, UI) |
| `tf-backup` | `read` на `sys/storage/raft/snapshot` | токен cron-бэкапа |
| `tf-svc-<сервис>` | `read` своих путей из `services.conf` | AppRole сервиса |
| `root` | всё | только временно: `setup.sh`, выдача кредов |

| AppRole | Пути (`services.conf`) | Токен | `secret_id` |
|---|---|---|---|
| `tf-deploy` | все `secret/tf/*` (чтение) | 15 мин, max 30 | бессрочный, без лимита использований |
| `tf-svc-tf-bff` | `postgres/bff kafka/bff rabbit/bff redis app/tf-bff` | 5 мин, max 15 | бессрочный |
| `tf-svc-tf-auth` | `postgres/auth redis app/tf-auth` | 5 мин | бессрочный |
| `tf-svc-tf-funnel` | `kafka/funnel redis app/tf-funnel` | 5 мин | бессрочный |
| `tf-svc-tf-model` | `kafka/model rabbit/model redis app/tf-model` | 5 мин | бессрочный |
| `tf-svc-tf-audit` | `postgres/audit redis app/tf-audit` | 5 мин | бессрочный |

`role_id` роли постоянный. `setup.sh apply` перезаписывает политики и параметры ролей, `role_id` при этом
не меняется. `secret_id` можно выдавать сколько угодно раз: новые добавляются к старым. `--rotate` отзывает
**все** прежние `secret_id` роли, и сервисы с ними перестанут входить в Vault.

### Токены

| Токен | Как выдаётся | Срок | Замечания |
|---|---|---|---|
| Root | `Initial Root Token` при инициализации или `operator generate-root` двумя ключами | бессрочный | держать только на время работы и сразу отзывать; в GitHub и файлах не хранить |
| Личный (tf-admin) | `setup.sh admin-token <имя>` под root | период 720 ч, продлевается при каждом использовании | **сейчас выдаётся дочерним к root**: отзыв root отзывает и его (раздел 6.2, кейс 3). До правки выдавать вручную с `-orphan` |
| Бэкап (tf-backup) | `setup.sh backup-token` | период 768 ч, `-orphan` | лежит в `$TF_INFRA_DIR/hashicorp/.backup-token` (600) |
| Токен сервиса | AppRole-вход при старте | 5 мин | контейнер отзывает его сразу после чтения |
| Токен CI | AppRole `tf-deploy` | 15 мин | `deploy.sh` отзывает его в конце выкатки |

### Как секрет попадает в контейнер

| Способ | Сервисы | Механизм |
|---|---|---|
| Выкатка подставляет переменные | `tf-postgres`, `tf-kafka`, `tf-rabbit`, `tf-redis`, `tf-nginx` (нет секретов), `tf-mail`, `tf-tg` | `deploy.sh` входит в Vault (пара CI или `VAULT_TOKEN`), читает ключи папки из `secrets.conf` плюс `SHARED_SECRETS` и передаёт их в `docker compose --env-file` (файл 600, удаляется после выкатки). Генерируемые значения — только `A-Za-z0-9_-`; `manual` — любые, кроме `'` и перевода строки |
| `vault-entrypoint.sh` | `tf-auth`, `tf-bff` | ENTRYPOINT контейнера: AppRole-вход, чтение `VAULT_SECRET_PATHS`, подстановка в `VAULT_EXPAND`, файлы из `VAULT_FILES`, отзыв токена, `exec` приложения |
| Сам по AppRole | `tf-funnel` (kit.go), `tf-model`, `tf-audit` (tfkit.py) | вход при старте, чтение нужных путей, секреты в памяти процесса |

`SHARED_SECRETS` (`scripts/lib/vault.sh`) — ключи чужих папок, которые получает сервис этого репозитория:
`mailing` → `TF_RABBIT_EMAIL_PASSWORD TF_REDIS_PASSWORD`, `telegram` → `TF_RABBIT_TELEGRAM_PASSWORD TF_REDIS_PASSWORD`.

### Веб-интерфейс

На dev — `https://vault.greefob.ru`: nginx снимает TLS и проксирует на `vault:8200`. Сам Vault при этом не
меняется и не перезапускается, а токены и роли остаются прежними. Вход — Method **Token**, личный токен
tf-admin. Секреты лежат в `secret/` → `tf/`. На prod интерфейс выключен: чтобы включить, нужна A-запись
`vault.thinkfaster.ru` и `VAULT_DOMAIN` в `stands/prod.env`. Без поддомена интерфейс открывается по туннелю:
`ssh -L 8200:127.0.0.1:8200 <пользователь>@<сервер>`, затем `http://localhost:8200`.

## 2.4. Каталог секретов

| Путь `secret/tf/…` | Ключ | Генератор | Потребитель |
|---|---|---|---|
| `postgres` | `POSTGRES_PASSWORD` | hex | суперпользователь `tf` (только инфраструктура, бэкап) |
| `postgres/auth` | `TF_PG_AUTH_ADMIN_PASSWORD`, `TF_PG_AUTH_USER_PASSWORD` | hex | миграции / приложение tf-auth |
| `postgres/bff` | `TF_PG_BFF_ADMIN_PASSWORD`, `TF_PG_BFF_USER_PASSWORD` | hex | миграции / приложение tf-bff |
| `postgres/audit` | `TF_PG_AUDIT_USER_PASSWORD` (+ `…_ADMIN_…`) | — | tf-audit. **Не заведён** (раздел 2.5) |
| `kafka` | `KAFKA_CLUSTER_ID` | cluster-id, **не ротируется** | брокер |
| `kafka` | `TF_KAFKA_ADMIN_PASSWORD` | hex | обслуживание |
| `kafka/funnel`, `kafka/model`, `kafka/bff` | `TF_KAFKA_<СЕРВИС>_PASSWORD` | hex | учётки SASL |
| `rabbit` | `TF_RABBIT_ADMIN_PASSWORD` | hex | admin (применяется только при первом старте тома) |
| `rabbit/bff`, `rabbit/model`, `rabbit/email`, `rabbit/telegram` | `TF_RABBIT_<…>_PASSWORD` | hex | `tf-bff`, `tf-model`, `tf-notify-email`, `tf-notify-telegram` |
| `redis` | `TF_REDIS_PASSWORD` | hex | все клиенты Redis |
| `app/tf-auth` | `TF_AUTH_JWT_PRIVATE_KEY_B64` | rsa-b64 | ключ подписи JWT; ротация разлогинивает всех |
| `app/tf-funnel` | `TF_FUNNEL_SERVICE_SUBS` | manual | `sub` техучётки шины |
| `app/tf-model`, `app/tf-audit` | `TF_MODEL_SERVICE_SUBS`, `TF_AUDIT_SERVICE_SUBS` | — (нет в `secrets.conf`) | заводятся руками при необходимости |
| `app/tf-mail` | `TF_MAIL_SMTP_HOST`, `_PORT`, `_USER`, `_PASSWORD` | manual | tf-mail (dev: Gmail; prod: Resend) |
| `app/tf-tg` | `TF_TG_BOT_TOKEN` | manual | tf-tg (свой бот на каждый стенд) |

Секреты `manual` не создаются ни `bootstrap`, ни `secrets.sh init`: их вводят руками (`secrets.sh set <КЛЮЧ>`
или UI). `secrets.sh status` показывает их как `MISSING (manual)` и не завершается из-за них ошибкой.

## 2.5. PostgreSQL

- Контейнер `tf-postgres` (`postgres:16`), база `tf`, суперпользователь `tf`. Сети: `think-fast-net` и
  `postgree_app-network`. Вторую до сих пор объявляет compose tf-auth, и она существует, пока выкатан `postgree`.
- Схемы — из `postgree/db/schemas.conf` (сейчас `auth`, `bff`). Для каждой схемы есть роли `<схема>_admin`
  (владелец, DDL, миграции) и `<схема>_user` (DML, без DDL), `search_path` указывает на схему.
- Контейнер `create-schema` запускается при каждой выкатке `postgree`. Он создаёт роли, выставляет пароли
  из Vault, передаёт владение объектами `<схема>_admin`, выдаёт права и проверяет, что `_user` видит все
  таблицы.
- **Схема `audit`:** роль `tf-svc-tf-audit` есть, а строки `audit` в `schemas.conf` и паролей в `secrets.conf`
  нет. Их убрали сознательно (коммит 13d1fdb): без паролей в `secrets.conf` выкатка `postgree` остановилась бы.
  Заводится отдельным шагом администратора (Часть VIII, № 3).
- Доступ людей: dev — `176.123.167.161:5432`; prod — только SSH-туннель на `127.0.0.1:15432` (pgAdmin: вкладка
  SSH Tunnel, Identity file). Пароли — `scripts/secrets.sh get <КЛЮЧ>` под личным токеном.
- Бэкап: cron в 04:00, `pg_dump -Fc` в том `postgres_backups`, хранятся 7 дней. Бэкап лежит на том же
  сервере, копии вне сервера нет.

## 2.6. Kafka

Один брокер KRaft (`apache/kafka:4.0.0`), `SASL_PLAINTEXT`/`PLAIN`, replication factor 1, порт на хост не
опубликован.

| Топик | Партиции | Хранение | Кто пишет | Кто читает |
|---|---|---|---|---|
| `tf.ingest.readings` | 6 | 7 дней | tf-funnel | tf-model; tf-bff — ACL есть, не использует |
| `tf.ingest.journal` | 3 | 30 дней | tf-funnel | tf-model; tf-bff — ACL есть, не использует |
| `tf.ingest.reference` | 3 | compact, вечно | tf-funnel (`channel.status`) | tf-model; tf-bff — ACL есть, не использует |
| `tf.forecast.results` | 3 | 7 дней | tf-model | tf-bff (группа `tf-bff-facts`) |
| `tf.dlq` | 1 | 14 дней | tf-funnel, tf-model, tf-bff (ACL) | — |

Для всех топиков: `lz4`, сообщение не больше 1 МБ. ACL — `kafka/acls.conf`. Группы потребителей должны
начинаться с имени сервиса (`tf-model-ingest`, `tf-bff-facts`). Выход за права даёт
`TopicAuthorizationException` / `GroupAuthorizationException`.

## 2.7. RabbitMQ

vhost `tf`, все очереди quorum и durable. TTL, DLX и лимиты задаются политиками, поэтому их можно менять
без пересоздания очередей.

| Exchange | Тип | Ключ | Очередь | TTL | Лимит | Издатель → потребитель |
|---|---|---|---|---|---|---|
| `tf.model.commands` | topic | `#` | `tf.model.commands` | 1 ч | 10 000 | tf-bff → tf-model |
| `tf.notifications` | direct | `email` | `tf.notify.email` | 24 ч | 10 000 | tf-bff → tf-mail |
| `tf.notifications` | direct | `telegram` | `tf.notify.telegram` | 24 ч | 10 000 | tf-bff → tf-tg |
| `tf.dlx` | fanout | — | `tf.dlq` | — | 100 000 | отказы всех очередей |

Сообщение попадает в `tf.dlq` в четырёх случаях: `reject`/`nack` без повтора, 5 возвратов в очередь
(`delivery-limit`), истёк TTL, переполнение очереди (`drop-head`). Причина — в заголовке `x-death`.

| Пользователь | configure | write | read |
|---|---|---|---|
| `tf-bff` | — | `tf.model.commands`, `tf.notifications` | — |
| `tf-model` | — | — | `tf.model.commands` |
| `tf-notify-email` (tf-mail) | — | — | `tf.notify.email` |
| `tf-notify-telegram` (tf-tg) | — | — | `tf.notify.telegram` |
| `admin` | всё | всё | всё (только обслуживание) |

Прав `configure` нет ни у одного сервиса: объявлять exchange и очереди можно только пассивно
(`passive=true`). Management UI открывается только по SSH-туннелю (rabbitmq/README.md).

Kafka `tf.dlq` и RabbitMQ `tf.dlq` называются одинаково, но это **разные** сущности.

## 2.8. Redis

Redis 7 с паролем (`TF_REDIS_PASSWORD`) и AOF, том `tf-redis-data`. Кто что хранит:

| Ключ / поток | Владелец | Назначение | Срок |
|---|---|---|---|
| поток `audit` | пишут tf-auth, tf-bff, tf-funnel, tf-model, tf-audit | журнал действий | `MAXLEN ~1 000 000` |
| поток `audit:requests` | пишут tf-funnel, tf-model, tf-audit | журнал запросов | `MAXLEN ~1 000 000` |
| поток `audit:dead` | tf-audit | отвергнутые события | `MAXLEN ~100 000` |
| группа `audit-writer` | tf-audit | позиция чтения | — |
| `auth:login-rate:{ip}:{логин}` | tf-auth | неудачные входы | TTL 60 с |
| `email:ratelimit:{email}` | tf-bff | антиспам ручной рассылки | TTL 60 с |
| `notify:sent:{notice_id}:{email\|telegram}` | tf-mail, tf-tg | кому уже ушло уведомление | 24 ч |

Redis — единственный буфер аудита: если он потеряет данные, события пропадут. Когда Redis недоступен,
сервисы ведут себя по-разному. tf-auth: вход отвечает `500`. tf-bff: лимит антиспама пропускает всё,
аудит уходит в лог. tf-funnel и tf-model: аудит копится в спул-файле. tf-mail и tf-tg: дедуп переходит
в память процесса.

## 2.9. Веб-сервер (tf-nginx)

- Сертификат Let's Encrypt на `DOMAIN`, `DOMAIN_ALIASES` и `VAULT_DOMAIN`. Лежит в `web-server/certbot/`
  каталога выкатки. `tf-certbot` дважды в сутки делает `renew` через webroot, nginx перечитывает конфиг
  раз в 6 ч.
- Выкатка web-server: проверяет, каких имён нет в сертификате, и дозапрашивает их (webroot, если nginx
  работает, иначе standalone). Открывает `certbot/www` на чтение: без этого проверка Let's Encrypt падала
  с 403 (раздел 6.2, кейс 6). Генерирует `nginx.conf` и `tf.d/*.conf` из шаблонов через `envsubst` в
  контейнере nginx, поднимает контейнер, выполняет `nginx -t` и `reload`.
- Маршруты и лимиты — таблица в разделе 1.6.
- `tf.d/vault.conf` генерируется, только если задан `VAULT_DOMAIN`.
- Настройки: `DOMAIN`, `DOMAIN_ALIASES`, `LETSENCRYPT_EMAIL`, `WEB_BIND`, `*_HOST`/`*_PORT` (`ML_HOST`/`ML_PORT`
  по умолчанию `tf-model:8000`), `FUNNEL_EVENTS_ALLOW`, `VAULT_DOMAIN`, `VAULT_ALLOW`.
- **Проверка конфига до выкатки** (сайт не трогается) — раздел 4.3.

## 2.10. Уведомления: tf-mail и tf-tg

Оба сервиса — потребители очередей RabbitMQ без HTTP API и без портов. Устроены одинаково, общий модуль
`app/broker.py` лежит копией в обеих папках (менять оба файла).

- **Контракт** (издатель — tf-bff): exchange `tf.notifications`, ключ `email` или `telegram`, JSON
  `{schema: 1, notice_id (uuid), subject (≤255), text (≤20000), to: {emails | chat_ids}, ticket_id?, kind?, request_id?}`.
  Полное ТЗ для издателя — `docs/notify-tz/tf-bff.md`. Реализация tf-bff сверена с ним: поля совпадают,
  BFF шлёт одно письмо на адресата и один Telegram на всех.
- **Ответ брокеру:**
  - `ack` — ушло хотя бы кому-то (отказы по адресам — в лог числом);
  - `reject` → `tf.dlq` — сообщение не разобрать (не JSON, нет `notice_id`, нет адресатов, хотя бы один адрес
    с ошибкой, Telegram длиннее 4096) или не ушло никому по постоянной причине;
  - `nack` с повтором через 5/15/30/60 с — временная ошибка; на 5-й попытке — `reject`.
- **Дедуп:** кому уже ушло, помнится по `notice_id` сутки в Redis (или в памяти, если Redis недоступен).
- **Старт:** tf-mail входит на SMTP без отправки, tf-tg вызывает `getMe`. Если логин, пароль или токен не
  подошли, очередь **не читается**, контейнер остаётся `unhealthy` и **не перезапускается по кругу**
  (Gmail блокирует вход после серии неудач). Выкатка в этом случае падает со строкой в логе.
- **Здоровье:** файл `/tmp/tf-alive` обновляется, пока есть соединение с брокером; `HEALTHCHECK` проверяет
  его свежесть (60 с).
- **Лог:** события `notify.sent` / `notify.failed` в JSON с `notice_id`, `ticket_id`, темой, числом адресатов
  и причиной. Адресов и текста в логе нет. В поток Redis `audit` сервисы **не пишут** (Часть VII, № 10).
- **Почта на prod:** хостинг молча режет исходящие 25/465/587 (с хоста и из docker). Используется Resend:
  `smtp.resend.com:2587`, логин `resend`, пароль — API-ключ, отправитель `MAIL_FROM=noreply@thinkfaster.ru`
  (домен подтверждён в Resend через DKIM и SPF в DNS reg.ru). На dev — Gmail `587` с паролем приложения.
- **Telegram:** `docker exec tf-tg python chats.py` показывает, кто писал боту за сутки (оттуда берут `chat_id`).
- Подробно — `mailing/README.md`, `telegram/README.md`.

## 2.11. Выкатка

### Три механизма

| Что | Как | dev | prod |
|---|---|---|---|
| Инфраструктура think-infra | `scripts/deploy.sh <сервис>`: настройки стенда, вход в Vault, секреты в env-файл, `git archive` папки в `$TF_INFRA_DIR/<сервис>`, `docker compose up`, проверка | вручную (раннера нет) | `deploy-<сервис>.yml` на раннере `self-hosted, prod` (пара CI в Environment `prod`) или вручную |
| tf-auth, tf-bff, tf-audit на prod | `deploy-apps-prod.yml` (think-infra): код из `/srv/thinkfaster/services/<репо>`, пары `TF_<СЕРВИС>_VAULT_*` из Environment `prod`, шаги по списку, упавший не прерывает остальные | — | вручную, `steps` на выбор |
| Приложения из своих репозиториев | workflow репозиториев: tf-auth, tf-bff, tf-front — SSH/scp и сборка на сервере; tf-funnel — образ в Docker Hub; tf-model, tf-audit, tf-emulator — сборка в CI, `docker save` → scp → `docker load` | по пушу | вручную |

Не держите два пути выкатки одного сервиса с разными параметрами. Из `deploy-apps-prod.yml` шаги `funnel` и
`model` уже убраны (коммит e4c4d0f): их выкатывает только Think-Faster.

### Особенности prod

- Docker вызывается через `sudo -n /usr/local/bin/tf-docker`. `sudo` сбрасывает окружение, поэтому
  `VAULT_ROLE_ID`/`VAULT_SECRET_ID` до compose не доходят, пока в sudoers нет
  `Defaults!/usr/local/bin/tf-docker env_keep += "VAULT_ROLE_ID VAULT_SECRET_ID"`. До этого их передают
  временным `--env-file` (tf-auth §8).
- `docker compose` разрешён только внутри `/srv/thinkfaster`.
- В GitHub Environment `prod` репозиториев лежат только пары AppRole. Root-токену (`VAULT_TOKEN`) там не
  место: без него `deploy-apps-prod.yml` пропускает шаги `apply` и `secrets`, это нормально.

### Ветки, версии, `[skip ci]`

Фича → PR в `dev` → `dev` → `prod`. Выпуск: `Merge branch 'dev' into prod [skip ci]`, `dev` перематывается на
тот же коммит, на него ставятся аннотированные теги `devX.Y.Z` / `prodX.Y.Z` с описанием. `[skip ci]` в
последнем коммите пуша отключает все workflow этого пуша. Им пользуются, когда выкатка идёт вручную
(на dev нет раннера) или когда меняется только документация.

## 2.12. Бэкапы и восстановление

| Что | Когда | Куда | Хранение | Восстановление |
|---|---|---|---|---|
| Vault (снапшот raft) | cron 03:00 | `$TF_INFRA_DIR/hashicorp/backups/` | 14 последних | `docker cp` снапшота в контейнер → `operator raft snapshot restore -force`. После восстановления действуют ключи и токены **того** Vault |
| PostgreSQL (`pg_dump -Fc`) | cron 04:00 | том `postgres_backups` | 7 дней | `pg_restore` в контейнере `tf-postgres` |
| Kafka, RabbitMQ, Redis | — | тома | — | бэкапа нет: данные транзитные |
| Архив воронки, том модели | — | тома `tf-funnel-data`, `tf-ml-work` | архив — `TF_FUNNEL_ARCHIVE_DAYS` | бэкапа нет |

Все бэкапы лежат **на том же сервере**. Снапшоты Vault без ключей распечатывания бесполезны: они
зашифрованы. Копирование вне сервера не настроено (Часть VIII).
