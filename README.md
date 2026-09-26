# tf.infra

Инфраструктура Think Faster: docker compose на стенд, по папке на сервис.

| Папка | Сервис | Секреты в Vault | Выкатка |
|---|---|---|---|
| [hashicorp](hashicorp/README.md) | Vault — хранилище секретов | — | вручную |
| [postgree](postgree) | PostgreSQL + создание схем | `secret/tf/postgres`, `secret/tf/postgres/<схема>` | `deploy-postgree.yml` |
| [kafka](kafka/README.md) | Kafka (KRaft, один брокер) | `secret/tf/kafka` | `deploy-kafka.yml` |
| [rabbitmq](rabbitmq/README.md) | RabbitMQ | `secret/tf/rabbit` | `deploy-rabbitmq.yml` |
| [redis](redis) | Redis | `secret/tf/redis` | `deploy-redis.yml` |
| [samba](samba) | Samba AD DC | `secret/tf/samba` | `deploy-samba.yml` |
| [web-server](web-server) | nginx + Let's Encrypt | — | `deploy-web-server.yml` |

Стенды: **dev** и **prod**. Ветки: фича → `dev` → `prod` → `master`.
Пуш в `dev` выкатывает изменённые сервисы на dev-стенд, пуш в `prod` — на prod.

## Секреты

Все пароли живут **только в Vault своего стенда**. В git, в `.env` на серверах и в GitHub их нет.
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
scripts/secrets.sh set SAMBA_ADMIN_PASSWORD # своё значение (спросит с клавиатуры)
scripts/secrets.sh get TF_RABBIT_BFF_PASSWORD   # передать владельцу сервиса
eval "$(scripts/secrets.sh env rabbitmq)"   # в текущую оболочку, для ручных docker compose
```

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
| `TF_PG_*` | да (`create-schema` синхронизирует пароли пользователей схем) |
| `TF_KAFKA_*_PASSWORD` | да (брокер перезапускается) |
| `KAFKA_CLUSTER_ID` | **никогда не меняется**, `rotate` запрещён |
| `TF_RABBIT_ADMIN_PASSWORD` | нет — сначала `rabbitmqctl change_password`, см. [rabbitmq/README.md](rabbitmq/README.md) |
| остальные `TF_RABBIT_*` | да (`tf-rabbit-init`) |
| `TF_REDIS_PASSWORD` | да (Redis перезапускается) |
| `SAMBA_ADMIN_PASSWORD` | нет — только при создании домена; менять `samba-tool user setpassword Administrator` |

### Ручные команды docker compose

Compose проверяет все `${…:?}` даже для `logs` и `ps`. В папке сервиса сначала:

```bash
eval "$(../scripts/secrets.sh env <папка>)"
```

Или использовать `docker logs <контейнер>` / `docker exec` — им переменные не нужны.

## Выкатка

```
push dev/prod ─► deploy-<сервис>.yml ─► deploy.yml (self-hosted runner стенда)
                                            │
                                            ├─ scripts/deploy.sh <сервис>
                                            │    ├─ вход в Vault: AppRole (VAULT_ROLE_ID/SECRET_ID из GitHub Environment)
                                            │    ├─ секреты сервиса → переменные окружения процесса (маскируются в логах)
                                            │    ├─ файлы сервиса из git → $TF_INFRA_DIR/<сервис>
                                            │    ├─ docker compose up + проверка (healthcheck, код init-контейнера)
                                            │    └─ отзыв токена Vault
```

- Workflow срабатывает на изменения в папке сервиса, `scripts/`, `secrets.conf` и самих workflow.
  Перезапустить вручную: Actions → `deploy <сервис>` → **Run workflow** → ветка `dev` или `prod`.
- Файлы копируются поверх `$TF_INFRA_DIR/<сервис>`: данные (`samba/data`), сертификаты
  (`web-server/certbot`), локальный `.env` с несекретными настройками не трогаются.
  Файлы, удалённые из git, на сервере остаются — удалить вручную.
- Токен CI: только чтение `secret/tf/*`, живёт 15 минут, отзывается в конце выкатки.

Вручную на сервере (например, если Actions недоступен):

```bash
TF_INFRA_DIR=<каталог> VAULT_TOKEN=<токен> scripts/deploy.sh kafka
```

## Настройка стенда

Один раз на каждом стенде (dev, prod).

### 1. Vault

По [hashicorp/README.md](hashicorp/README.md): поднять, инициализировать, распечатать,
`hashicorp/scripts/setup.sh apply`, выдать токены, отозвать root.

### 2. Секреты

Существующий стенд — **сначала перенести действующие пароли**, иначе выкатка их поменяет
и сервисы с клиентами разъедутся:

```bash
export VAULT_TOKEN=<токен tf-admin>
scripts/secrets.sh import <TF_INFRA_DIR>/kafka/.env kafka
scripts/secrets.sh import <TF_INFRA_DIR>/rabbitmq/.env rabbitmq
scripts/secrets.sh import <TF_INFRA_DIR>/postgree/.env postgree
```

Пароль Samba не импортировать: значение из `.env` к домену никогда не применялось (см. ниже).
`deploy.sh` принимает только значения из `A-Z a-z 0-9 _ -`. Если импортированный пароль
содержит другие символы, выкатка остановится с ошибкой — тогда `scripts/secrets.sh rotate <КЛЮЧ>`.

Затем сгенерировать недостающее и проверить:

```bash
scripts/secrets.sh init
scripts/secrets.sh status
```

Новый стенд — сразу `init`.

### 3. Runner

На сервере стенда: GitHub → Settings → Actions → Runners → **New self-hosted runner** (Linux).
При `./config.sh` добавить метку стенда:

```bash
./config.sh --url https://github.com/<организация>/<репозиторий> --token <token> --labels dev
sudo ./svc.sh install && sudo ./svc.sh start
```

Пользователь runner-а должен быть в группе `docker`. Нужны `git`, `bash`, `docker compose` v2.

Runner выполняет код из репозитория с доступом к docker, то есть фактически с root-правами на сервере.
Workflow не запускаются на `pull_request`, поэтому код из форков на runner не попадает.

### 4. GitHub Environment

Settings → Environments → создать `dev` и `prod`:

| Что | Где | Значение |
|---|---|---|
| **Deployment branches** | Environment → Deployment branches and tags | `dev` — только ветка `dev`, `prod` — только `prod` |
| `VAULT_ROLE_ID` | Environment secrets | из `hashicorp/scripts/setup.sh ci-credentials` |
| `VAULT_SECRET_ID` | Environment secrets | оттуда же |
| `TF_INFRA_DIR` | Environment variables | каталог сервисов на сервере, например `/opt/tf.infra` |
| Required reviewers | Environment → Protection rules | для `prod` — по желанию |

Ограничение по веткам обязательно: иначе workflow из любой ветки получит секреты prod.

Сменить `VAULT_SECRET_ID` (утёк, ушёл сотрудник): `hashicorp/scripts/setup.sh ci-credentials --rotate`
отзывает все прежние и печатает новый — обновить в Environment.

### 5. Несекретные настройки

Остаются в локальных `.env` на сервере (в git их нет, выкатка их не трогает):

| Файл | Переменные |
|---|---|
| `$TF_INFRA_DIR/web-server/.env` | `DOMAIN`, `LETSENCRYPT_EMAIL`, хосты и порты (шаблон — `.env.example`) |
| `$TF_INFRA_DIR/samba/.env` | `SAMBA_DOMAIN`, `SAMBA_REALM`, `SAMBA_NETBIOS` |
| `$TF_INFRA_DIR/postgree/.env` | `DB_PORT` (по умолчанию 5432) |

Пароли из этих файлов после переноса в Vault удалить. Файлы `hashicorp/.env`, `postgree/.env.schemas`,
`kafka/.env`, `rabbitmq/.env` больше не нужны.

## Миграция существующего стенда: на что обратить внимание

- **`TF_INFRA_DIR` — это каталог, где сервисы запущены сейчас.** Имя проекта compose берётся
  из имени папки (`postgree`), а `samba/data` и сертификаты лежат рядом с compose-файлом.
  Другой каталог = новые пустые тома и новый домен Samba.
- **Пароли схем Postgres поменяются.** Раньше пароль совпадал с именем пользователя
  (`auth_user` / `auth_user`). Первая выкатка `postgree` выставит пароли из Vault —
  до неё передать новые пароли сервисам auth и bff (`scripts/secrets.sh get TF_PG_AUTH_USER_PASSWORD`).
- **У Redis появился пароль.** Клиенты (bff и др.) без пароля перестанут подключаться после выкатки `redis`.
- **Samba.** Раньше compose читал `DOMAIN`/`ADMIN_PASSWORD`, а в `.env` были `SAMBA_*`, поэтому домен
  создан с паролем по умолчанию из `entrypoint.sh`. Новый пароль к существующему домену не применяется —
  сменить вручную на значение из Vault:
  ```bash
  docker exec -it samba-ad samba-tool user setpassword Administrator --newpassword="$(scripts/secrets.sh get SAMBA_ADMIN_PASSWORD)"
  ```
- **Vault слушает только localhost.** Веб-интерфейс — через SSH-туннель (см. hashicorp/README.md).
