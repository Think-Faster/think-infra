# ТЗ: tf-bff получает секреты из Vault при старте контейнера

Для агента и разработчиков репозитория **tf-bff**. Инфраструктура (Vault, PostgreSQL, Kafka, RabbitMQ, Redis) уже работает на стенде — менять её не нужно, только подключиться.

## 1. Цель

Пароли, ключи и токены сервиса не хранятся нигде, кроме Vault стенда: ни в git, ни в `.env` на сервере, ни в `appsettings*.json`, ни в образе, ни в GitHub Secrets. Контейнер при **каждом старте** (выкатка, `docker restart`, перезагрузка сервера) сам забирает свои секреты из Vault. В GitHub хранится только доступ сервиса к Vault — `VAULT_ROLE_ID` и `VAULT_SECRET_ID`.

**Код приложения не меняется**: оно, как и раньше, читает настройки из переменных окружения. Меняются Dockerfile, docker-compose и workflow выкатки.

## 2. Как это работает

```
GitHub Secrets (Environment dev/prod): VAULT_ROLE_ID, VAULT_SECRET_ID
        │  выкатка: docker compose up -d
        ▼
контейнер tf-bff стартует ─► vault-entrypoint.sh
        │   1. входит в Vault (http://vault:8200, сеть think-fast-net) по AppRole сервиса
        │   2. читает пути из VAULT_SECRET_PATHS → каждый ключ становится переменной окружения
        │   3. подставляет ${КЛЮЧ} в переменные из VAULT_EXPAND (строки подключения)
        │   4. пишет секреты-файлы из VAULT_FILES (ключи, сертификаты)
        │   5. отзывает токен, убирает VAULT_ROLE_ID/VAULT_SECRET_ID из окружения
        ▼
exec приложение — видит готовые переменные окружения
```

- Vault — контейнер `vault` в сети `think-fast-net`, адрес **`http://vault:8200`**. Снаружи сервера недоступен.
- Сервис может читать **только свои пути** (политика `tf-svc-tf-bff`). Запрос чужого пути — ошибка при старте.
- После перезагрузки сервера Vault запечатан, пока администратор его не распечатает. Контейнер в это время ждёт до 10 минут (пишет в лог попытки), затем падает и перезапускается по `restart`.

## 3. Секреты сервиса

Путь — относительно `secret/tf/`. Ключ = имя переменной окружения, которую получит контейнер.

| Путь (`VAULT_SECRET_PATHS`) | Переменная | Что это |
|---|---|---|
| `postgres/bff` | `TF_PG_BFF_USER_PASSWORD` | PostgreSQL, пользователь `bff_user` — **приложение** |
|  | `TF_PG_BFF_ADMIN_PASSWORD` | PostgreSQL, пользователь `bff_admin` — **только миграции** |
| `kafka/bff` | `TF_KAFKA_BFF_PASSWORD` | Kafka, пользователь `tf-bff` |
| `rabbit/bff` | `TF_RABBIT_BFF_PASSWORD` | RabbitMQ, пользователь `tf-bff` |
| `redis` | `TF_REDIS_PASSWORD` | Redis (если сервис им пользуется — иначе убрать путь из `VAULT_SECRET_PATHS`) |
| `app/tf-bff` | свои (раздел 4) | собственные секреты сервиса |

Путь `app/tf-bff` добавлять в `VAULT_SECRET_PATHS` только после того, как администратор завёл в нём секреты (раздел 4) — иначе старт упадёт: пути нет.

Не секреты (остаются в конфигурации сервиса как есть):

| Что | Значение |
|---|---|
| PostgreSQL | хост и порт — как сейчас; база `tf`; схема `bff`; пользователи `bff_user` (приложение) / `bff_admin` (миграции) |
| Kafka | `tf-kafka:9092`, `SASL_PLAINTEXT`, механизм `PLAIN`, пользователь `tf-bff`. Читает `tf.ingest.journal`, `tf.ingest.reference`, `tf.forecast.results`; пишет в `tf.dlq`. `group.id` начинается с `tf-bff` |
| RabbitMQ | `tf-rabbit:5672`, vhost `tf`, пользователь `tf-bff`. Публикует в `tf.model.commands` и `tf.notifications`. Очереди и exchange не объявляет (или `passive=true`) |
| Redis | `tf-redis:6379`, пароль обязателен |

Контейнер должен быть в сети `think-fast-net`.

Что уже известно о сервисе:

- Сервис на .NET, контейнер `tf-bff`, образ `tf-bff:latest`, запуск `dotnet BFF.WebApi.dll`, порт `8080`.

## 4. Собственные секреты сервиса

JWT-ключи, SMTP-пароли, токены ботов, ключи внешних API — в `secret/tf/app/tf-bff`.

1. Составить список: имя переменной → назначение → откуда значение:
   **генерируется** (случайная строка, например секрет HMAC) или **выдаётся извне** (токен бота, ключ API, готовый ключ RSA).
2. Имя: `TF_BFF_<НАЗНАЧЕНИЕ>`, только `A-Z 0-9 _`.
3. **Многострочные значения** (PEM-ключи, сертификаты) хранятся в Vault в **base64 одной строкой**, имя заканчивается на `_B64`. В контейнер они попадают файлом через `VAULT_FILES` (раздел 5.4) — приложение читает файл, как раньше.
4. Передать список администратору — **только имена и назначение, без значений**. Он заведёт секреты в Vault на каждом стенде, после этого путь `app/tf-bff` добавляется в `VAULT_SECRET_PATHS`.

Значения секретов никогда не передаются через чат, issue, PR или commit.

## 5. Что сделать в репозитории

### 5.1. Инвентаризация

Выписать все переменные окружения, `appsettings*.json`, файлы ключей и настройки сервиса и разделить на **секреты** (пароли, токены, ключи, строки подключения с паролем) и **настройки** (хосты, порты, имена пользователей, флаги). Таблицу «переменная → секрет/настройка → откуда после миграции» приложить к PR.

### 5.2. Скрипт `vault-entrypoint.sh`

Положить в корень репозитория как есть (текст — в приложении в конце документа). Переносы строк — **LF**; в `.gitattributes`: `*.sh text eol=lf`.

### 5.3. Dockerfile

Скрипту нужны `bash`, `curl`, `jq`, `base64`. Для образов .NET (`mcr.microsoft.com/dotnet/aspnet`, Debian):

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

Для Alpine-образов: `RUN apk add --no-cache bash curl jq`. Секреты в `ARG` / `ENV` / `COPY` Dockerfile — запрещены.

### 5.4. docker-compose

```yaml
services:
  tf-bff:
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

- Имена переменных в примере (`ConnectionStrings__Default`, `Redis__Configuration` и т.п.) — **условные**: использовать те, что уже читает сервис (секции `appsettings.json` через `__`). Менять их не нужно — меняется только источник значения.
- Если сервис читает переменную с паролем напрямую, `VAULT_EXPAND` не нужен: переменная `TF_…` уже будет в окружении.
- Нельзя: значения секретов в compose, `env_file:` с секретами, `${VAR:-значение}` для секретов.

### 5.5. Workflow выкатки

В GitHub Environment `dev` (и `prod`) репозитория администратор кладёт `VAULT_ROLE_ID` и `VAULT_SECRET_ID`. Шаг выкатки передаёт их в окружение `docker compose`:

```yaml
jobs:
  deploy:
    environment: dev          # prod — для выкатки на prod
    runs-on: ...              # как сейчас
    steps:
      # ... сборка образа как сейчас ...
      - name: Deploy
        env:
          VAULT_ROLE_ID: ${{ secrets.VAULT_ROLE_ID }}
          VAULT_SECRET_ID: ${{ secrets.VAULT_SECRET_ID }}
        run: docker compose up -d
```

После успешной выкатки — удалить прежние секреты сервиса из GitHub Secrets и `.env` на сервере (сообщить администратору, что можно удалять).

### 5.6. PostgreSQL: приложение и миграции — разные пользователи

| Пользователь | Для чего | Права |
|---|---|---|
| `bff_user` | **приложение** | `SELECT/INSERT/UPDATE/DELETE`, последовательности; **без DDL** |
| `bff_admin` | **миграции** (EF Core) | владелец схемы `bff`, DDL |

- У обоих `search_path = bff`: имена таблиц можно писать без схемы.
- `Database.Migrate()` при старте приложения под `bff_user` **упадёт** (нет прав на DDL). Миграции — под `bff_admin` с паролем `TF_PG_BFF_ADMIN_PASSWORD`: отдельный контейнер/шаг миграций перед запуском приложения или отдельная строка подключения только для миграций.
- Рабочая строка подключения приложения — только под `bff_user`.
- Таблицы, созданные не тем пользователем, инфраструктура при следующей выкатке передаст `bff_admin` и выдаст права — но правильно сразу создавать их под `bff_admin`.

### 5.7. Локальная разработка

Без `VAULT_ROLE_ID` скрипт Vault не трогает и запускает приложение с переменными как есть. Локально — `.env` (в `.gitignore`) с тестовыми значениями; в репозитории — `.env.example` с `CHANGE_ME`.

### 5.8. Логи

Не печатать строки подключения, пароли, ключи и переменные окружения (ни при старте, ни при ошибке). Скрипт сам значения не выводит — только имена путей и файлов.

## 6. Критерии приёмки

1. В репозитории нет действующих секретов (`git grep` по фрагментам паролей пуст; `.env` в `.gitignore`). Если секрет был в истории git — сообщить администратору, его сменят.
2. В GitHub Secrets — только `VAULT_ROLE_ID`, `VAULT_SECRET_ID` (в Environments `dev` / `prod`).
3. На сервере нет `.env` с паролями сервиса; выкатка на dev проходит, сервис работает.
4. В логе старта контейнера: `secret/tf/<путь>: загружено` по каждому пути и `запуск приложения`.
5. `docker restart tf-bff` — сервис снова поднимается и работает (секреты читаются заново).
6. `docker inspect` контейнера не содержит паролей — только `VAULT_ROLE_ID` / `VAULT_SECRET_ID` и строки с `${...}`.
7. Приложение работает под `bff_user`, миграции выполняются под `bff_admin`.

## 7. Чего не делать

- Не использовать чужие пути и учётки (другого сервиса, `admin`, `tf`) — политика их не пустит.
- Не класть токен Vault (`hvs.…`) в конфигурацию — только `VAULT_ROLE_ID` / `VAULT_SECRET_ID`.
- Не выводить секреты в лог, не передавать их значения в чатах, issue, PR.

## 8. Что передать администратору

Только имена, **никогда значения**:

- список собственных секретов сервиса (раздел 4) — имя, назначение, «генерируется» или «выдаётся извне»;
- если нужен доступ к ещё одному пути Vault (например, сервис начал пользоваться Redis или RabbitMQ);
- если секрет когда-то был закоммичен в git — его нужно сменить;
- когда выкатка на dev прошла — что старые секреты из GitHub и `.env` можно удалять.

## Приложение: `vault-entrypoint.sh`

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
#   VAULT_FILES         (необязательно) секреты-файлы через пробел в виде КЛЮЧ:путь.
#                       Значение секрета хранится в Vault в base64 (одной строкой) и
#                       записывается в файл раскодированным, права 600. Для ключей и сертификатов:
#                       VAULT_FILES="TF_AUTH_JWT_PRIVATE_KEY_B64:/run/secrets/jwt-private.pem"
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

    # Значение передаётся в base64: любые символы, включая переводы строк, доходят без искажений.
    while IFS=' ' read -r key encoded; do
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { revoke; log "ERROR: недопустимое имя ключа '$key' в $path"; exit 1; }
        value="$(printf '%s' "$encoded" | base64 -d)"
        export "$key=$value"
        loaded+=("$key")
    done < <(jq -r '.data.data | to_entries[] | "\(.key) \(.value | tostring | @base64)"' <<< "$json")

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

# ------------------------------------------------------------
# Секреты-файлы (ключи, сертификаты)
# ------------------------------------------------------------

for item in ${VAULT_FILES:-}; do
    key="${item%%:*}"
    file="${item#*:}"
    [ "$key" != "$item" ] && [ -n "$file" ] || { log "ERROR: VAULT_FILES: ожидается КЛЮЧ:путь, получено '$item'"; exit 1; }
    [ -n "${!key+x}" ] || { log "ERROR: VAULT_FILES: ключа $key нет в VAULT_SECRET_PATHS"; exit 1; }
    mkdir -p "$(dirname "$file")"
    (umask 077 && printf '%s' "${!key}" | base64 -d > "$file") \
        || { log "ERROR: VAULT_FILES: $key — не base64 или нельзя записать $file"; exit 1; }
    log "файл $file: записан"
done

log "секретов загружено: ${#loaded[@]}, запуск приложения"

# Доступ к Vault приложению не нужен.
unset VAULT_ROLE_ID VAULT_SECRET_ID

exec "$@"
```
