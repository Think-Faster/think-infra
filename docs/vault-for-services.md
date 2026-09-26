# ТЗ: сервис получает секреты из Vault при старте контейнера

Для агентов и разработчиков репозиториев сервисов: **tf-bff**, **tf-auth**, **tf-funnel**
(и следующих сервисов по тому же образцу).

## 1. Цель

Пароли, ключи и токены сервиса не хранятся нигде, кроме Vault стенда: ни в git, ни в `.env`
на сервере, ни в `appsettings*.json`, ни в образе, ни в GitHub Secrets.
Контейнер при **каждом старте** (выкатка, перезапуск, перезагрузка сервера) сам забирает свои
секреты из Vault. В GitHub хранится только доступ сервиса к Vault — пара `VAULT_ROLE_ID` / `VAULT_SECRET_ID`.

**Код приложения не меняется**: оно, как и раньше, читает настройки из переменных окружения.
Меняются Dockerfile, docker-compose и workflow выкатки.

## 2. Как это работает

```
GitHub Secrets (Environment dev/prod): VAULT_ROLE_ID, VAULT_SECRET_ID
        │  выкатка: docker compose up -d
        ▼
контейнер сервиса стартует ─► vault-entrypoint.sh
        │   1. входит в Vault (http://vault:8200, сеть think-fast-net) по AppRole сервиса
        │   2. читает пути из VAULT_SECRET_PATHS → каждый ключ становится переменной окружения
        │   3. подставляет ${КЛЮЧ} в переменные из VAULT_EXPAND (строки подключения)
        │   4. отзывает токен, убирает VAULT_ROLE_ID/VAULT_SECRET_ID из окружения
        ▼
exec приложение (dotnet ...) — видит готовые переменные окружения
```

- Vault — контейнер `vault` в сети `think-fast-net`, адрес **`http://vault:8200`**. Снаружи сервера недоступен.
- Сервис может читать **только свои пути** (политика `tf-svc-<сервис>`). Запрос чужого пути — ошибка при старте.
- После перезагрузки сервера Vault запечатан, пока администратор его не распечатает. Контейнер
  в это время ждёт до 10 минут (пишет в лог попытки), затем падает и перезапускается по `restart`.

## 3. Секреты сервисов

Путь — относительно `secret/tf/`. Ключ = имя переменной окружения, которую получит контейнер.

| Сервис | `VAULT_SECRET_PATHS` | Переменные | Что это |
|---|---|---|---|
| tf-bff | `postgres/bff` | `TF_PG_BFF_USER_PASSWORD` | PostgreSQL, пользователь `bff_user` — **приложение** |
| | | `TF_PG_BFF_ADMIN_PASSWORD` | PostgreSQL, пользователь `bff_admin` — **только миграции** |
| | `kafka/bff` | `TF_KAFKA_BFF_PASSWORD` | Kafka, пользователь `tf-bff` |
| | `rabbit/bff` | `TF_RABBIT_BFF_PASSWORD` | RabbitMQ, пользователь `tf-bff` |
| | `redis` | `TF_REDIS_PASSWORD` | Redis |
| | `app/tf-bff` | свои (раздел 4) | JWT, ключи API и т.п. |
| tf-auth | `postgres/auth` | `TF_PG_AUTH_USER_PASSWORD` | PostgreSQL, `auth_user` — **приложение** |
| | | `TF_PG_AUTH_ADMIN_PASSWORD` | PostgreSQL, `auth_admin` — **только миграции** |
| | `redis` | `TF_REDIS_PASSWORD` | Redis (если сервис им пользуется) |
| | `app/tf-auth` | свои (раздел 4) | ключ подписи JWT и т.п. |
| tf-funnel | `kafka/funnel` | `TF_KAFKA_FUNNEL_PASSWORD` | Kafka, пользователь `tf-funnel` |
| | `app/tf-funnel` | свои (раздел 4) | |

Путь `app/<сервис>` указывать в `VAULT_SECRET_PATHS`, только когда в нём появились секреты (иначе старт упадёт: пути нет).

Не секреты (остаются в конфигурации сервиса как есть):

| Что | Значение |
|---|---|
| PostgreSQL | хост и порт — как сейчас; база `tf`; пользователи `<схема>_user` / `<схема>_admin` |
| Kafka | `tf-kafka:9092`, `SASL_PLAINTEXT`, `PLAIN`, пользователь `tf-bff` / `tf-funnel`; `group.id` начинается с имени сервиса |
| RabbitMQ | `tf-rabbit:5672`, vhost `tf`, пользователь `tf-bff` |
| Redis | `tf-redis:6379`, пароль обязателен |

Все контейнеры — в сети `think-fast-net`.

## 4. Собственные секреты сервиса

JWT-ключи, SMTP-пароли, токены ботов, ключи внешних API — в `secret/tf/app/<сервис>`.

1. Составить список: имя переменной → назначение → откуда значение: **генерируется** (случайная
   строка, например ключ подписи JWT) или **выдаётся извне** (токен бота, ключ API).
2. Имя: `TF_<СЕРВИС>_<НАЗНАЧЕНИЕ>`, только `A-Z 0-9 _`, например `TF_AUTH_JWT_SIGNING_KEY`.
3. Передать список администратору (**только имена, без значений**). Он заведёт секреты в Vault
   на каждом стенде, после этого путь `app/<сервис>` добавляется в `VAULT_SECRET_PATHS`.

Значения секретов никогда не передаются через чат, issue, PR или commit.

## 5. Что сделать в репозитории сервиса

### 5.1. Инвентаризация

Выписать все переменные окружения и настройки сервиса и разделить на **секреты** (пароли, токены,
ключи, строки подключения с паролем) и **настройки** (хосты, порты, имена пользователей, флаги).
Таблицу «переменная → секрет/настройка → откуда после миграции» приложить к PR.

### 5.2. Скрипт `vault-entrypoint.sh`

Положить в репозиторий сервиса как есть (текст — в приложении в конце документа).
Переносы строк — **LF**; в `.gitattributes`: `*.sh text eol=lf`.

### 5.3. Dockerfile

Скрипту нужны `bash`, `curl`, `jq`. Для образов .NET (`mcr.microsoft.com/dotnet/aspnet`, Debian):

```dockerfile
FROM mcr.microsoft.com/dotnet/aspnet:8.0
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl jq \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /app/publish .

COPY vault-entrypoint.sh /usr/local/bin/vault-entrypoint.sh
RUN chmod +x /usr/local/bin/vault-entrypoint.sh

# Было: ENTRYPOINT ["dotnet", "BFF.WebApi.dll"]
ENTRYPOINT ["/usr/local/bin/vault-entrypoint.sh"]
CMD ["dotnet", "BFF.WebApi.dll"]
```

Для Alpine-образов: `RUN apk add --no-cache bash curl jq`.
Секреты в `ARG` / `ENV` / `COPY` Dockerfile — запрещены.

### 5.4. docker-compose

```yaml
services:
  tf-bff:
    image: tf-bff:latest
    container_name: tf-bff
    restart: unless-stopped
    networks:
      - think-fast-net
    environment:
      # Доступ к Vault: из GitHub Secrets через окружение выкатки.
      VAULT_ADDR: http://vault:8200
      VAULT_ROLE_ID: ${VAULT_ROLE_ID:?VAULT_ROLE_ID is not set}
      VAULT_SECRET_ID: ${VAULT_SECRET_ID:?VAULT_SECRET_ID is not set}

      # Какие пути читать (раздел 3). Каждый ключ станет переменной окружения.
      VAULT_SECRET_PATHS: postgres/bff kafka/bff rabbit/bff redis

      # Переменные, в которые подставить секреты при старте.
      VAULT_EXPAND: ConnectionStrings__Default Redis__Configuration Kafka__SaslPassword RabbitMq__Password

      # $$ — чтобы docker compose не подставлял сам: в контейнер попадёт литерал ${...},
      # его заменит vault-entrypoint.sh значением из Vault.
      ConnectionStrings__Default: "Host=<как сейчас>;Port=5432;Database=tf;Username=bff_user;Password=$${TF_PG_BFF_USER_PASSWORD}"
      Redis__Configuration: "tf-redis:6379,password=$${TF_REDIS_PASSWORD}"
      Kafka__SaslPassword: "$${TF_KAFKA_BFF_PASSWORD}"
      RabbitMq__Password: "$${TF_RABBIT_BFF_PASSWORD}"

networks:
  think-fast-net:
    external: true
```

- Имена `ConnectionStrings__Default`, `Kafka__SaslPassword` и т.п. — **те, что уже читает сервис**
  (секции `appsettings.json` через `__`). Менять их не нужно — меняется только источник значения.
- Если сервис читает переменную с паролем напрямую, можно не использовать `VAULT_EXPAND`:
  например, `TF_REDIS_PASSWORD` уже будет в окружении.
- Нельзя: значения секретов в compose, `env_file:` с секретами, `${VAR:-значение}` для секретов.

### 5.5. Workflow выкатки

В GitHub Environment `dev` (и `prod`) репозитория лежат `VAULT_ROLE_ID` и `VAULT_SECRET_ID`.
Шаг выкатки передаёт их в окружение `docker compose`:

```yaml
jobs:
  deploy:
    environment: dev          # prod — для ветки prod
    runs-on: ...              # как сейчас
    steps:
      # ... сборка образа как сейчас ...
      - name: Deploy
        env:
          VAULT_ROLE_ID: ${{ secrets.VAULT_ROLE_ID }}
          VAULT_SECRET_ID: ${{ secrets.VAULT_SECRET_ID }}
        run: docker compose up -d
```

Все прежние секреты сервиса (пароли БД, Kafka, RabbitMQ, JWT и т.п.) из GitHub Secrets
и из `.env` на сервере — удалить после успешной выкатки.

### 5.6. PostgreSQL: приложение и миграции — разные пользователи

| Пользователь | Для чего | Права |
|---|---|---|
| `<схема>_user` | **приложение** | `SELECT/INSERT/UPDATE/DELETE`, последовательности; **без DDL** |
| `<схема>_admin` | **миграции** (EF Core) | владелец схемы, DDL |

- У обоих `search_path = <схема>`: имена таблиц можно писать без схемы.
- `Database.Migrate()` при старте приложения под `<схема>_user` **упадёт** (нет прав на DDL).
  Миграции — отдельной строкой подключения под `<схема>_admin` с паролем
  `TF_PG_<СХЕМА>_ADMIN_PASSWORD`: отдельный контейнер/шаг миграций перед запуском приложения,
  или отдельная строка подключения только для миграций внутри приложения.
- Рабочая строка подключения приложения — только под `<схема>_user`.

### 5.7. Локальная разработка

Без `VAULT_ROLE_ID` скрипт Vault не трогает и запускает приложение с переменными как есть.
Локально — `.env` (в `.gitignore`) с тестовыми значениями; в репозитории — `.env.example` с `CHANGE_ME`.

### 5.8. Логи

Не печатать строки подключения, пароли и переменные окружения (ни при старте, ни при ошибке).
Скрипт сам значения не выводит — только имена путей.

## 6. Критерии приёмки

1. В репозитории нет действующих секретов (`git grep` по фрагментам паролей пуст; `.env` в `.gitignore`).
   Если секрет был в истории git — сообщить администратору, его сменят.
2. В GitHub Secrets сервиса — только `VAULT_ROLE_ID`, `VAULT_SECRET_ID` (в Environments `dev` / `prod`).
3. На сервере нет `.env` с паролями; выкатка на dev проходит, контейнер `healthy`.
4. В логе старта контейнера: `secret/tf/<путь>: загружено` по каждому пути и `запуск приложения`.
5. `docker restart <контейнер>` — сервис снова поднимается и работает (секреты читаются заново).
6. Приложение работает под `<схема>_user`, миграции выполняются под `<схема>_admin`.
7. `docker inspect <контейнер>` не содержит паролей — только `VAULT_ROLE_ID` / `VAULT_SECRET_ID`
   и строки с `${...}`.

## 7. Чего не делать

- Не использовать чужие пути и учётки (другого сервиса, `admin`, `tf`) — политика их не пустит.
- Не класть токен Vault (`hvs.…`) в конфигурацию — только `VAULT_ROLE_ID` / `VAULT_SECRET_ID`.
- Не выводить секреты в лог, не передавать их значения в чатах, issue, PR.

## Приложение: `vault-entrypoint.sh`

Исходник: `docs/vault-entrypoint.sh` в репозитории инфраструктуры.

```bash
#!/bin/bash
# ============================================================
# vault-entrypoint.sh — при старте контейнера забирает секреты сервиса из Vault
# в переменные окружения и запускает приложение. Код приложения не меняется:
# оно читает переменные окружения, как раньше.
#
# Dockerfile (нужны bash, curl, jq):
#   COPY vault-entrypoint.sh /usr/local/bin/vault-entrypoint.sh
#   RUN chmod +x /usr/local/bin/vault-entrypoint.sh
#   ENTRYPOINT ["/usr/local/bin/vault-entrypoint.sh"]
#   CMD ["dotnet", "Service.dll"]
#
# Переменные окружения контейнера:
#   VAULT_ADDR          адрес Vault: http://vault:8200 (сеть think-fast-net)
#   VAULT_ROLE_ID       AppRole сервиса (из GitHub Secrets)
#   VAULT_SECRET_ID     AppRole сервиса (из GitHub Secrets)
#   VAULT_SECRET_PATHS  пути в secret/tf/ через пробел, например "postgres/bff redis app/tf-bff".
#                       Каждый ключ пути становится переменной окружения с тем же именем.
#   VAULT_EXPAND        (необязательно) имена переменных через пробел, в значениях которых
#                       ${КЛЮЧ} заменяется значением секрета. Для строк подключения:
#                       ConnectionStrings__Default="...;Password=${TF_PG_BFF_USER_PASSWORD}"
#
# Без VAULT_ROLE_ID (локальная разработка) Vault не используется — приложение запускается
# с переменными окружения как есть.
# ============================================================

set -euo pipefail

log() {
    echo "[vault-entrypoint] $*" >&2
}

if [ -z "${VAULT_ROLE_ID:-}" ]; then
    log "VAULT_ROLE_ID не задан — запуск без Vault"
    exec "$@"
fi

: "${VAULT_ADDR:?VAULT_ADDR is not set}"
: "${VAULT_SECRET_ID:?VAULT_SECRET_ID is not set}"
: "${VAULT_SECRET_PATHS:?VAULT_SECRET_PATHS is not set}"

# ------------------------------------------------------------
# Вход. После перезагрузки сервера Vault запечатан, пока администратор его не распечатает, —
# ждём до 10 минут, затем падаем (docker перезапустит контейнер по restart-политике).
# ------------------------------------------------------------

login() {
    jq -nc --arg r "$VAULT_ROLE_ID" --arg s "$VAULT_SECRET_ID" '{role_id: $r, secret_id: $s}' \
        | curl -sSf --max-time 10 -X POST --data @- "$VAULT_ADDR/v1/auth/approle/login" \
        | jq -er '.auth.client_token'
}

token=""
for attempt in $(seq 1 60); do
    if token="$(login 2> /dev/null)"; then
        break
    fi
    token=""
    log "Vault недоступен, запечатан или неверный VAULT_ROLE_ID/VAULT_SECRET_ID — попытка $attempt/60"
    sleep 10
done

[ -n "$token" ] || { log "ERROR: не удалось войти в Vault ($VAULT_ADDR)"; exit 1; }

revoke() {
    curl -sf --max-time 10 -X POST -H "X-Vault-Token: $token" \
        "$VAULT_ADDR/v1/auth/token/revoke-self" > /dev/null 2>&1 || true
}

# ------------------------------------------------------------
# Чтение секретов
# ------------------------------------------------------------

loaded=()

for path in $VAULT_SECRET_PATHS; do
    if ! json="$(curl -sSf --max-time 10 -H "X-Vault-Token: $token" \
                   "$VAULT_ADDR/v1/secret/data/tf/$path" 2> /dev/null)"; then
        revoke
        log "ERROR: нет доступа к secret/tf/$path (нет такого пути или его нет в политике сервиса)"
        exit 1
    fi

    while IFS=$'\t' read -r key value; do
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { revoke; log "ERROR: недопустимое имя ключа '$key' в $path"; exit 1; }
        export "$key=$value"
        loaded+=("$key")
    done < <(jq -r '.data.data | to_entries[] | [.key, (.value | tostring)] | @tsv' <<< "$json")

    log "secret/tf/$path: загружено"
done

revoke
unset token

# ------------------------------------------------------------
# Подстановка ${КЛЮЧ} в перечисленные переменные (строки подключения)
# ------------------------------------------------------------

shopt -u patsub_replacement 2> /dev/null || true

for name in ${VAULT_EXPAND:-}; do
    [ -n "${!name+x}" ] || { log "ERROR: VAULT_EXPAND: переменная $name не задана"; exit 1; }
    value="${!name}"
    for key in "${loaded[@]}"; do
        pattern='${'"$key"'}'
        value="${value//"$pattern"/${!key}}"
    done
    if [[ "$value" == *'${'* ]]; then
        log "ERROR: в $name остались неподставленные \${...} — такого ключа нет в VAULT_SECRET_PATHS"
        exit 1
    fi
    export "$name=$value"
done

log "секретов загружено: ${#loaded[@]}, запуск приложения"

# Доступ к Vault приложению не нужен.
unset VAULT_ROLE_ID VAULT_SECRET_ID

exec "$@"
```
