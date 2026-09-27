# tf.infra

Инфраструктура Think Faster: docker compose на стенд, по папке на сервис.

> Первый раз? Пошаговая инструкция без предварительных знаний — [QUICK_START.md](QUICK_START.md).

| Папка | Сервис | Секреты в Vault | Выкатка |
|---|---|---|---|
| [hashicorp](hashicorp/README.md) | Vault — хранилище секретов | — | `bootstrap-stand.sh` / вручную |
| [postgree](postgree) | PostgreSQL + схемы сервисов | `secret/tf/postgres`, `secret/tf/postgres/<схема>` | `deploy-postgree.yml` |
| [kafka](kafka/README.md) | Kafka (KRaft, один брокер) | `secret/tf/kafka` | `deploy-kafka.yml` |
| [rabbitmq](rabbitmq/README.md) | RabbitMQ | `secret/tf/rabbit` | `deploy-rabbitmq.yml` |
| [redis](redis) | Redis | `secret/tf/redis` | `deploy-redis.yml` |
| [web-server](web-server) | nginx + Let's Encrypt, веб-интерфейс Vault (`VAULT_DOMAIN`) | — | `deploy-web-server.yml` |
| [mailing](mailing/README.md) | `tf-mail` — письма из очереди `tf.notify.email` через SMTP | `app/tf-mail`, `rabbit/email`, `redis` | `deploy-mailing.yml` |
| [telegram](telegram/README.md) | `tf-tg` — сообщения бота из очереди `tf.notify.telegram` | `app/tf-tg`, `rabbit/telegram`, `redis` | `deploy-telegram.yml` |

Папка `samba` в выкатку не входит. `mailing` и `telegram` не входят в `bootstrap-stand.sh`: им нужны
секреты, которые заводятся руками (SMTP, токен бота), — после них выкатываются обычным пушем или Run workflow.

Стенды: **dev** и **prod**. Ветки: фича → `dev` → `prod` → `master`.
Пуш в `dev` выкатывает изменённые сервисы на dev-стенд, пуш в `prod` — на prod.

## Новый стенд — одной командой

На сервере (Linux, docker, docker compose v2, git, openssl), из клона репозитория на ветке стенда:

```bash
git clone <репозиторий> tf.infra && cd tf.infra && git checkout dev
scripts/bootstrap-stand.sh dev
```

Скрипт [bootstrap-stand.sh](scripts/bootstrap-stand.sh) по шагам:

1. проверяет окружение и настройки `stands/dev.env`;
2. создаёт docker-сеть `think-fast-net`;
3. поднимает Vault, инициализирует его и **один раз показывает ключи распечатывания и root-токен** —
   ждёт, пока вы их сохраните (`saved`), и распечатывает;
4. создаёт в Vault хранилище, политики и AppRole для CI;
5. генерирует все секреты из `secrets.conf`;
6. выкатывает postgree, redis, kafka, rabbitmq, web-server (Let's Encrypt — при первом запуске);
7. ставит в cron ежедневные бэкапы Vault (03:00) и PostgreSQL (04:00);
8. печатает `VAULT_ROLE_ID` / `VAULT_SECRET_ID` для GitHub и выдаёт личный токен администратора;
9. предлагает отозвать root-токен.

Каждый шаг идемпотентен: после ошибки скрипт запускается снова, готовое не трогается.
На уже развёрнутом стенде он спросит ключ распечатывания (если Vault запечатан) и root-токен.

Если DNS домена ещё не настроен — `scripts/bootstrap-stand.sh dev --skip web-server`,
web-server выкатится потом обычным пушем.

После скрипта — один раз настроить GitHub (раздел «Настройка GitHub»).

## Настройки стендов

Несекретные настройки — по одному файлу на стенд в git: [stands/dev.env](stands/dev.env),
[stands/prod.env](stands/prod.env). Там каталог выкатки `TF_INFRA_DIR`, порт PostgreSQL,
домен и адреса сервисов для nginx.

Один файл на стенд, а не `.env` в каждой папке: переменных немного, стенд описан целиком
в одном месте, изменения проходят ревью, и на сервере не остаётся локальных файлов,
которые нужно создавать руками. Пароли в эти файлы класть нельзя — `deploy.sh` проверяет,
что там нет ключей из `secrets.conf`.

Изменить настройку — правка файла и пуш: выкатятся все сервисы стенда.
Переменная окружения с тем же именем имеет приоритет над файлом (для ручных запусков).

## Секреты

Все пароли живут **только в Vault своего стенда**. В git, в файлах на серверах и в GitHub их нет.
В GitHub хранится только доступ CI к Vault (AppRole с правом чтения).

Полный список — [secrets.conf](secrets.conf): сервис, путь в Vault, имя переменной и способ генерации.
Имя ключа в Vault = имя переменной окружения, которую ждёт `docker-compose.yml`.

Секреты создаются и меняются скриптом [scripts/secrets.sh](scripts/secrets.sh) на сервере стенда.
Значения генерирует `openssl` и сразу пишет в Vault через stdin — они не попадают на диск,
в историю команд и на экран.

```bash
export VAULT_TOKEN=<ваш токен tf-admin>     # hashicorp/scripts/setup.sh admin-token <имя>

scripts/secrets.sh status                   # что есть, чего не хватает (без значений)
scripts/secrets.sh init                     # сгенерировать всё недостающее
scripts/secrets.sh init kafka               # только для одного сервиса
scripts/secrets.sh rotate TF_KAFKA_BFF_PASSWORD
scripts/secrets.sh set TF_REDIS_PASSWORD    # своё значение (спросит с клавиатуры)
scripts/secrets.sh get TF_RABBIT_BFF_PASSWORD   # передать владельцу сервиса
eval "$(scripts/secrets.sh env rabbitmq)"   # в текущую оболочку, для ручных docker compose
```

Секреты с генератором `manual` (SMTP для `tf-mail`, токен бота `tf-tg`) `init` не создаёт — их вводят
руками: `scripts/secrets.sh set <КЛЮЧ>` или в веб-интерфейсе Vault (`https://<VAULT_DOMAIN>`,
см. [hashicorp/README.md](hashicorp/README.md#веб-интерфейс)). `status` показывает их как `MISSING (manual)`.

### Добавить секрет

1. Строка в `secrets.conf`.
2. `scripts/secrets.sh init <папка>` — на **каждом** стенде.
3. Переменная в `docker-compose.yml` сервиса: `${ИМЯ:?ИМЯ is not set}`.
4. Пуш — выкатка подхватит.

Новая схема в `postgree/db/schemas.conf` — это тоже два секрета:
`TF_PG_<СХЕМА>_ADMIN_PASSWORD` и `TF_PG_<СХЕМА>_USER_PASSWORD` в `secrets.conf`.

### Ротация

`scripts/secrets.sh rotate <КЛЮЧ>`, затем выкатка сервиса (`workflow_dispatch` в Actions или пуш).
Клиенты сервиса должны получить новый пароль — иначе они перестанут подключаться.

| Секрет | Применяется выкаткой |
|---|---|
| `POSTGRES_PASSWORD` | да (`ALTER USER tf`) |
| `TF_PG_*` | да (`create-schema` выставляет пароли пользователей схем) |
| `TF_KAFKA_*_PASSWORD` | да (брокер перезапускается) |
| `KAFKA_CLUSTER_ID` | **никогда не меняется**, `rotate` запрещён |
| `TF_RABBIT_ADMIN_PASSWORD` | нет — сначала `rabbitmqctl change_password`, см. [rabbitmq/README.md](rabbitmq/README.md) |
| остальные `TF_RABBIT_*` | да (`tf-rabbit-init`) |
| `TF_REDIS_PASSWORD` | да (Redis перезапускается) |
| `TF_AUTH_JWT_PRIVATE_KEY_B64` | при перезапуске `tf-auth` (`docker restart tf-auth`). Все выданные токены станут недействительны — пользователи перелогинятся |

### Ручные команды docker compose

Compose проверяет все `${…:?}` даже для `logs` и `ps`. В папке сервиса сначала:

```bash
eval "$(../scripts/secrets.sh env <папка>)"
```

Или использовать `docker logs <контейнер>` / `docker exec` — им переменные не нужны.

## Сервисы приложения (tf-bff, tf-auth, tf-funnel)

Сервисы забирают секреты из Vault сами, при каждом старте контейнера: скрипт
[docs/vault-entrypoint.sh](docs/vault-entrypoint.sh) входит по AppRole сервиса (`http://vault:8200`
в сети `think-fast-net`), выставляет переменные окружения и запускает приложение.
ТЗ для репозиториев сервисов, по файлу на репозиторий — [docs/vault-tz/](docs/vault-tz/README.md).

- Какой сервис какие пути читает — [hashicorp/services.conf](hashicorp/services.conf).
  По нему `hashicorp/scripts/setup.sh apply` (с root-токеном) создаёт политику и AppRole `tf-svc-<сервис>`.
- Доступ для GitHub репозитория сервиса: `hashicorp/scripts/setup.sh service-credentials <сервис>` →
  `VAULT_ROLE_ID` / `VAULT_SECRET_ID` в Environment `dev` / `prod` этого репозитория.
- Собственные секреты сервиса (JWT, ключи API) — строки `app/<сервис>` в `secrets.conf`,
  затем `scripts/secrets.sh init` (генерируемые) или `scripts/secrets.sh set <КЛЮЧ>` (генератор `manual`).
- Пароль каждой учётки Kafka / RabbitMQ лежит в своём пути (`kafka/bff`, `rabbit/model`, ...):
  сервис не видит пароли admin и чужих учёток. Стенд, где пароли ещё в общих путях `kafka` / `rabbit`,
  переводится командами `scripts/secrets.sh relocate kafka` и `scripts/secrets.sh relocate rabbit`.

## PostgreSQL: схемы и права

Схемы перечислены в [postgree/db/schemas.conf](postgree/db/schemas.conf). Для схемы `auth`:

| Роль | Кто | Что может | `search_path` |
|---|---|---|---|
| `auth_admin` | **миграции** | владелец схемы и всех её объектов, DDL | `auth` |
| `auth_user` | **приложение** | `SELECT/INSERT/UPDATE/DELETE`, последовательности, функции; без DDL | `auth` |
| `auth_maintenance`, `auth_read_write` | групповые роли (NOLOGIN) | — | — |

Контейнер `create-schema` запускается при **каждой** выкатке `postgree` и приводит схемы к этому
виду — идемпотентно, данные не трогает:

- создаёт недостающие роли, выставляет пароли из Vault и `search_path`;
- объекты схемы, созданные не `<схема>_admin` (под `tf`, через `SET ROLE`), передаёт `<схема>_admin`;
- заново выдаёт права на все существующие объекты и права по умолчанию на будущие;
- проверяет, что у приложения есть доступ ко всем таблицам и последовательностям, иначе падает.

Правила для сервисов:

- миграции — под `<схема>_admin`, приложение — под `<схема>_user`;
- имена таблиц можно писать без схемы: `search_path` указывает на свою схему;
- если таблица создана вручную под другим пользователем — перевыкатить `postgree`
  (Actions → `deploy postgree` → Run workflow), права и владелец исправятся.

## Выкатка

```
push dev/prod ─► deploy-<сервис>.yml ─► deploy.yml (self-hosted runner стенда)
                                            │
                                            ├─ scripts/deploy.sh <сервис>   (TF_STAND = ветка)
                                            │    ├─ настройки стенда: stands/<стенд>.env
                                            │    ├─ вход в Vault: AppRole (VAULT_ROLE_ID/SECRET_ID из GitHub Environment)
                                            │    ├─ секреты сервиса → переменные окружения процесса (маскируются в логах)
                                            │    ├─ файлы сервиса из git → $TF_INFRA_DIR/<сервис>
                                            │    ├─ docker compose up + проверка (healthcheck, код init-контейнера)
                                            │    └─ отзыв токена Vault
```

- Workflow срабатывает на изменения в папке сервиса, `scripts/`, `stands/`, `secrets.conf` и самих workflow.
  Перезапустить вручную: Actions → `deploy <сервис>` → **Run workflow** → ветка `dev` или `prod`.
- Файлы копируются поверх `$TF_INFRA_DIR/<сервис>`: сертификаты (`web-server/certbot`),
  бэкапы, токен бэкапа не трогаются. Файлы, удалённые из git, на сервере остаются — удалить вручную.
- Vault через CI не выкатывается: после перезапуска он запечатан. Изменения `hashicorp/` —
  вручную: `TF_STAND=<стенд> scripts/deploy.sh hashicorp`, затем распечатать.

Вручную на сервере (например, если Actions недоступен):

```bash
TF_STAND=dev VAULT_TOKEN=<токен> scripts/deploy.sh kafka
```

## Настройка GitHub

Один раз на каждый стенд.

### Environment

Settings → Environments → создать `dev` и `prod`:

| Что | Где | Значение |
|---|---|---|
| **Deployment branches** | Environment → Deployment branches and tags | `dev` — только ветка `dev`, `prod` — только `prod` |
| `VAULT_ROLE_ID` | Environment secrets | из вывода `bootstrap-stand.sh` (или `hashicorp/scripts/setup.sh ci-credentials`) |
| `VAULT_SECRET_ID` | Environment secrets | оттуда же |
| Required reviewers | Environment → Protection rules | для `prod` — по желанию |

Ограничение по веткам обязательно: иначе workflow из любой ветки получит секреты prod.

Сменить `VAULT_SECRET_ID` (утёк, ушёл сотрудник): `hashicorp/scripts/setup.sh ci-credentials --rotate`
отзывает все прежние и печатает новый — обновить в Environment.

### Runner

На сервере стенда: GitHub → Settings → Actions → Runners → **New self-hosted runner** (Linux).
При `./config.sh` добавить метку стенда:

```bash
./config.sh --url https://github.com/<организация>/<репозиторий> --token <token> --labels dev
sudo ./svc.sh install && sudo ./svc.sh start
```

Пользователь runner-а должен быть в группе `docker` и иметь права на запись в `TF_INFRA_DIR`.

Runner выполняет код из репозитория с доступом к docker, то есть фактически с root-правами на сервере.
Workflow не запускаются на `pull_request`, поэтому код из форков на runner не попадает.

## Перевод существующего стенда

Стенд, поднятый до этой схемы (пароли в `.env`, Vault в dev-режиме):

1. **Перенести действующие пароли в Vault до первой выкатки** — иначе выкатка их поменяет:
   ```bash
   export VAULT_TOKEN=<root или tf-admin>
   scripts/secrets.sh import <старый каталог>/kafka/.env kafka
   scripts/secrets.sh import <старый каталог>/rabbitmq/.env rabbitmq
   scripts/secrets.sh import <старый каталог>/postgree/.env postgree
   ```
   `deploy.sh` принимает только значения из `A-Z a-z 0-9 _ -`. Если импортированный пароль
   содержит другие символы, выкатка остановится с ошибкой — тогда `scripts/secrets.sh rotate <КЛЮЧ>`.
2. `TF_INFRA_DIR` в `stands/<стенд>.env` — каталог, где сервисы запущены сейчас (там сертификаты
   web-server). Тома данных от каталога не зависят: у kafka, rabbitmq, redis, vault имена заданы явно,
   у postgres — по имени папки `postgree`.
3. `scripts/bootstrap-stand.sh <стенд>` — доделает остальное. Старые `.env` с паролями после этого удалить.

На что обратить внимание:

- **Пароли схем Postgres поменяются.** Раньше пароль совпадал с именем пользователя
  (`auth_user` / `auth_user`). Первая выкатка `postgree` выставит пароли из Vault —
  до неё передать новые пароли сервисам auth и bff (`scripts/secrets.sh get TF_PG_AUTH_USER_PASSWORD`).
- **У Redis появился пароль.** Клиенты (bff и др.) без пароля перестанут подключаться после выкатки `redis`.
- **Vault слушает только localhost.** Веб-интерфейс — поддомен `VAULT_DOMAIN` через nginx или SSH-туннель
  (см. hashicorp/README.md).
- **Старый cron бэкапа PostgreSQL** (`postgree/cron-control.sh`, путь `/opt/tf`) заменён задачей,
  которую ставит `bootstrap-stand.sh`. Старую запись удалить: `crontab -e`.
