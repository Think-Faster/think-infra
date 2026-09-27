# Задание: tf-bff берёт секреты из Vault при старте контейнера

Для агента и разработчиков репозитория **tf-bff**.

## 1. Что происходит сейчас и что нужно

Инфраструктура стенда (PostgreSQL, Kafka, RabbitMQ, Redis, Vault) переведена на новую схему и
**поднята заново: пароли новые, база новая**. Все пароли лежат **только в Vault**. Старые пароли
из `.env` и GitHub Secrets больше не подходят — поэтому сейчас миграции падают с
`password authentication failed for user "tf"`.

Нужно, чтобы tf-bff при **каждом старте контейнера** сам забирал свои пароли из Vault.

**Код приложения почти не меняется**: оно, как и раньше, читает настройки из переменных окружения.
Меняются Dockerfile, docker-compose, скрипт миграций и workflow выкатки.

Проверено со стороны инфраструктуры: пользователь `bff_admin` с паролем из Vault подключается
к базе и попадает в схему `bff`. Всё готово — осталась конфигурация tf-bff.

## 2. Как это работает

```
GitHub Environment (dev / prod): VAULT_ROLE_ID, VAULT_SECRET_ID
        │  выкатка: docker compose up -d
        ▼
контейнер стартует ─► vault-entrypoint.sh (скрипт в конце документа)
        │  1. входит в Vault: http://vault:8200 (сеть think-fast-net)
        │  2. читает пути из VAULT_SECRET_PATHS → каждый ключ становится переменной окружения
        │  3. подставляет ${КЛЮЧ} в переменные из VAULT_EXPAND (строки подключения)
        │  4. убирает VAULT_ROLE_ID / VAULT_SECRET_ID из окружения
        ▼
exec приложение — видит готовые переменные окружения
```

- Vault доступен только из docker-сети `think-fast-net` (снаружи сервера — нет).
- tf-bff может читать **только свои пути** (таблица ниже). Любой другой путь — ошибка при старте.
- После перезагрузки сервера Vault запечатан, пока администратор его не откроет. Контейнер ждёт
  до 10 минут (пишет попытки в лог), потом падает и перезапускается по `restart`.

## 3. Что доступно tf-bff в Vault

| Путь (`VAULT_SECRET_PATHS`) | Переменная | Для чего |
|---|---|---|
| `postgres/bff` | `TF_PG_BFF_USER_PASSWORD` | PostgreSQL, пользователь **`bff_user`** — работа приложения |
| `postgres/bff` | `TF_PG_BFF_ADMIN_PASSWORD` | PostgreSQL, пользователь **`bff_admin`** — **только миграции** |
| `kafka/bff` | `TF_KAFKA_BFF_PASSWORD` | Kafka, пользователь `tf-bff` |
| `rabbit/bff` | `TF_RABBIT_BFF_PASSWORD` | RabbitMQ, пользователь `tf-bff` |
| `redis` | `TF_REDIS_PASSWORD` | Redis |

Больше ничего tf-bff не доступно — и не нужно:

- ❌ **Пользователь `tf`** — суперпользователь базы, его пароль tf-bff недоступен.
  Ни миграции, ни приложение под ним не работают.
- ❌ **Путь `app/tf-bff`** — не указывать. Собственных секретов у tf-bff в Vault нет; с этим путём
  контейнер упадёт (`нет доступа к secret/tf/app/tf-bff`). Если сервису нужны свои секреты
  (ключи внешних API и т.п.) — передать администратору **имена и назначение, без значений**;
  после того как их заведут, путь можно добавить.

## 4. Несекретные параметры — в конфигурации как есть

| Что | Значение |
|---|---|
| Сеть docker | **`think-fast-net`** (external). Сеть `postgree_app-network` больше не нужна |
| PostgreSQL | `tf-postgres:5432`, база `tf`, схема `bff` |
| Kafka | `tf-kafka:9092`, `SASL_PLAINTEXT`, механизм `PLAIN`, пользователь `tf-bff`; `group.id` начинается с `tf-bff`; сжатие продюсера `lz4`; сообщение ≤ 1 МБ |
| Kafka, права | читает `tf.ingest.journal`, `tf.ingest.reference`, `tf.forecast.results`; пишет в `tf.dlq` |
| RabbitMQ | `tf-rabbit:5672`, vhost `tf`, пользователь `tf-bff`; публикует в `tf.model.commands` и `tf.notifications`; очереди и exchange **не объявлять** (или `passive=true`) |
| Redis | `tf-redis:6379`, пароль обязателен |
| Порт приложения | **`8080`** — на него nginx проксирует `/api/bff/` |

## 5. PostgreSQL: кто что делает

| Кто | Пользователь | Может |
|---|---|---|
| Инфраструктура | `tf` | создаёт схему `bff`, пользователей `bff_admin` / `bff_user`, выдаёт права — **уже сделано** |
| Миграции tf-bff | **`bff_admin`** | создавать и менять таблицы в схеме `bff` (владелец схемы) |
| Приложение tf-bff | **`bff_user`** | `SELECT / INSERT / UPDATE / DELETE`, последовательности; **без DDL** |

- У `bff_admin` и `bff_user` `search_path = bff`: имена таблиц можно писать без схемы.
- Миграции **не** создают базу, схему, роли и не выдают права — только таблицы внутри схемы `bff`.
- Приложение **не** вызывает `Database.Migrate()` при старте: под `bff_user` нет прав на DDL.
- Права приложения на новые таблицы появляются автоматически, если таблицы создаёт `bff_admin`.

## 6. К какому виду привести

### 6.1. Скрипт `vault-entrypoint.sh`

Положить в корень репозитория **как есть** (текст — в конце документа). Переносы строк — LF;
в `.gitattributes`: `*.sh text eol=lf`.

### 6.2. Dockerfile

Скрипту нужны `bash`, `curl`, `jq`. И в образе приложения, и в образе миграций:

```dockerfile
FROM mcr.microsoft.com/dotnet/aspnet:8.0
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl jq \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /app/publish .

COPY vault-entrypoint.sh /usr/local/bin/vault-entrypoint.sh
RUN chmod +x /usr/local/bin/vault-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/vault-entrypoint.sh"]
CMD ["dotnet", "BFF.WebApi.dll"]
```

Образ миграций — так же, с `CMD` запуска миграций. Если миграции идут через `psql`/скрипт в образе
`postgres`: `apt-get install -y curl jq` там же, `ENTRYPOINT` — `vault-entrypoint.sh`.
Секреты в `ARG` / `ENV` / `COPY` Dockerfile — запрещены.

### 6.3. docker-compose

Имена переменных (`ConnectionStrings__Default`, `Kafka__SaslPassword` и т.п.) — **условные**:
использовать те, что уже читает сервис (секции `appsettings.json` через `__`).

```yaml
x-vault: &vault
  VAULT_ADDR: http://vault:8200
  VAULT_ROLE_ID: ${VAULT_ROLE_ID:?VAULT_ROLE_ID is not set}
  VAULT_SECRET_ID: ${VAULT_SECRET_ID:?VAULT_SECRET_ID is not set}

services:
  # Миграции — под bff_admin, один раз перед запуском приложения.
  tf-bff-migrations:
    image: <образ миграций>
    container_name: tf-bff-migrations
    restart: "no"
    networks: [think-fast-net]
    environment:
      <<: *vault
      VAULT_SECRET_PATHS: postgres/bff
      VAULT_EXPAND: ConnectionStrings__Default
      # $$ — чтобы compose не подставлял сам: подставит vault-entrypoint.sh при старте
      ConnectionStrings__Default: "Host=tf-postgres;Port=5432;Database=tf;Username=bff_admin;Password=$${TF_PG_BFF_ADMIN_PASSWORD}"

  # Приложение — под bff_user.
  tf-bff:
    image: tf-bff:latest
    container_name: tf-bff
    restart: unless-stopped
    networks: [think-fast-net]
    depends_on:
      tf-bff-migrations:
        condition: service_completed_successfully
    environment:
      <<: *vault
      VAULT_SECRET_PATHS: postgres/bff kafka/bff rabbit/bff redis
      VAULT_EXPAND: ConnectionStrings__Default Redis__Configuration Kafka__SaslPassword RabbitMq__Password
      ConnectionStrings__Default: "Host=tf-postgres;Port=5432;Database=tf;Username=bff_user;Password=$${TF_PG_BFF_USER_PASSWORD}"
      Redis__Configuration: "tf-redis:6379,password=$${TF_REDIS_PASSWORD}"
      Kafka__SaslPassword: "$${TF_KAFKA_BFF_PASSWORD}"
      RabbitMq__Password: "$${TF_RABBIT_BFF_PASSWORD}"

networks:
  think-fast-net:
    external: true
```

Если миграции идут через `psql` (скрипт), а не через строку подключения .NET:

```yaml
    environment:
      <<: *vault
      VAULT_SECRET_PATHS: postgres/bff
      VAULT_EXPAND: PGPASSWORD
      PGHOST: tf-postgres
      PGPORT: "5432"
      PGDATABASE: tf
      PGUSER: bff_admin
      PGPASSWORD: "$${TF_PG_BFF_ADMIN_PASSWORD}"
```

Запрещено: значения секретов в compose, `env_file` с секретами, `${VAR:-значение}` для секретов.

### 6.4. Скрипт миграций

- Убрать все упоминания пользователя **`tf`**, проверку «can `tf` connect», создание базы, схемы,
  ролей, `GRANT`. Проверять подключение **`bff_admin`**.
- Только создание и изменение таблиц в схеме `bff` (схему можно не указывать — `search_path = bff`).
- Идемпотентно: повторный запуск на уже мигрированной базе — без ошибок.

### 6.5. Код приложения

- Не вызывать `Database.Migrate()` при старте.
- Не печатать в лог строки подключения, пароли, переменные окружения.
- Не генерировать и не подставлять секреты «по умолчанию», если их нет: на стенде всё приходит
  из Vault, отсутствие — ошибка конфигурации, сервис должен падать с понятным сообщением.

### 6.6. Workflow выкатки

```yaml
jobs:
  deploy:
    environment: dev          # prod — для выкатки на prod
    steps:
      # ... сборка образов как сейчас ...
      - name: Deploy
        env:
          VAULT_ROLE_ID: ${{ secrets.VAULT_ROLE_ID }}
          VAULT_SECRET_ID: ${{ secrets.VAULT_SECRET_ID }}
        run: docker compose up -d
```

`VAULT_ROLE_ID` / `VAULT_SECRET_ID` для tf-bff уже лежат (или будут положены администратором)
в GitHub → Settings → Environments → `dev` / `prod`.

### 6.7. Удалить старое

- Все прежние секреты tf-bff из GitHub Secrets (пароли БД, Kafka, RabbitMQ, Redis) — кроме пары `VAULT_…`.
- `.env` с паролями на сервере и в репозитории; в репозитории — `.env.example` с `CHANGE_ME`,
  `.env` в `.gitignore`.
- Подключение к `postgree_app-network`.

### 6.8. Локальная разработка

Без `VAULT_ROLE_ID` скрипт Vault не трогает и запускает приложение с переменными как есть —
локально работает `.env` с тестовыми значениями.

## 7. Критерии приёмки

1. `tf-bff-migrations`: в логе `secret/tf/postgres/bff: загружено`, затем код выхода `0`.
2. `tf-bff`: в логе `загружено` по `postgres/bff`, `kafka/bff`, `rabbit/bff`, `redis`, затем `запуск приложения`.
3. `docker exec tf-nginx wget -qO- http://tf-bff:8080/health` отвечает; `https://<домен>/api/bff/…` работает.
4. `docker restart tf-bff` — сервис снова поднимается (секреты читаются заново).
5. Таблицы схемы `bff` принадлежат `bff_admin`; приложение работает под `bff_user`.
6. Нигде нет паролей: ни в репозитории, ни в образе, ни в GitHub Secrets (кроме пары `VAULT_…`),
   ни в `docker inspect` (там только `${…}`).

## 8. Если не стартует

| В логе | Причина | Что делать |
|---|---|---|
| `password authentication failed for user "tf"` | подключение под `tf` | заменить на `bff_admin` (миграции) / `bff_user` (приложение) |
| `password authentication failed for user "bff_…"` | перепутаны переменные | `_ADMIN_` — миграции, `_USER_` — приложение; проверить `$$` и `VAULT_EXPAND` |
| `нет доступа к secret/tf/<путь>` | путь не из таблицы раздела 3 (часто `app/tf-bff`) | убрать путь; если нужен — запрос администратору |
| `Vault недоступен, запечатан или неверный VAULT_ROLE_ID/VAULT_SECRET_ID` | неверные значения в GitHub или Vault запечатан | проверить Environment secrets; иначе — администратору |
| `в X остались неподставленные ${...}` | имя в `${…}` не совпадает с ключом из Vault | сверить с таблицей раздела 3 |
| `could not translate host name "tf-postgres"` | контейнер не в `think-fast-net` | добавить сеть |
| `permission denied for schema bff` / `must be owner` | DDL под `bff_user` | миграции — только под `bff_admin` |

Администратору — только имена путей и переменных, **никогда значения**.

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
