#!/bin/bash
# Выкатка одного сервиса инфраструктуры на стенд. Запускается GitHub Actions
# на self-hosted runner стенда (.github/workflows/deploy.yml) или вручную на сервере.
#
#   TF_STAND=<dev|prod> scripts/deploy.sh <postgree|kafka|rabbitmq|redis|web-server|hashicorp>
#
# hashicorp (сам Vault) через CI не выкатывается: после перезапуска он запечатан.
# Его выкатывает scripts/bootstrap-stand.sh или администратор вручную.
#
# Переменные окружения:
#   TF_STAND                        стенд: настройки берутся из stands/<стенд>.env (обязательно)
#   VAULT_ROLE_ID, VAULT_SECRET_ID  AppRole tf-deploy (так входит CI)
#   VAULT_TOKEN                     или готовый токен (ручной запуск)
#   Любая переменная из stands/<стенд>.env, заданная в окружении, имеет приоритет над файлом.
#
# Что делает:
#   1. читает несекретные настройки стенда из stands/<стенд>.env;
#   2. входит в Vault и читает секреты сервиса из secrets.conf в переменные окружения
#      этого процесса (на диск не пишутся, в логах Actions маскируются);
#   3. копирует файлы сервиса из git (HEAD) в $TF_INFRA_DIR/<сервис>, не трогая
#      неотслеживаемые файлы: данные, сертификаты, бэкапы;
#   4. поднимает сервис через docker compose и проверяет результат.

set -Eeuo pipefail

LOG_TAG="DEPLOY"
source "$(dirname "$0")/lib/vault.sh"

SERVICE="${1:?usage: TF_STAND=<dev|prod> $0 <postgree|kafka|rabbitmq|redis|web-server|hashicorp>}"

case "$SERVICE" in
    postgree|kafka|rabbitmq|redis|web-server|hashicorp) ;;
    *) die "неизвестный сервис: $SERVICE" ;;
esac

load_stand_env
: "${TF_INFRA_DIR:?TF_INFRA_DIR is not set (stands/$TF_STAND.env)}"

# Сообщения docker compose о контейнерах из другого compose-файла того же проекта
# (postgres и create-schema) — не ошибка.
export COMPOSE_IGNORE_ORPHANS=True

# ============================================================
# Vault
# ============================================================

LOGGED_IN=0

revoke_token() {
    if [ "$LOGGED_IN" -eq 1 ]; then
        vault_cmd token revoke -self > /dev/null 2>&1 || true
    fi
}

trap revoke_token EXIT

mask() {
    if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
        echo "::add-mask::$1"
    fi
}

load_secrets() {
    local svc path key gen value count=0

    if [ -z "$(manifest "$SERVICE")" ]; then
        log "no secrets for $SERVICE"
        return
    fi

    vault_require_unsealed

    if [ -n "${VAULT_ROLE_ID:-}" ] && [ -n "${VAULT_SECRET_ID:-}" ]; then
        log "Vault login: AppRole"
        VAULT_TOKEN="$(
            printf '%s' "$VAULT_SECRET_ID" \
            | docker exec -i "$VAULT_CONTAINER" \
                vault write -field=token auth/approle/login role_id="$VAULT_ROLE_ID" secret_id=-
        )" || die "не удалось войти в Vault по AppRole (VAULT_ROLE_ID / VAULT_SECRET_ID)"
        LOGGED_IN=1
        mask "$VAULT_TOKEN"
    fi

    vault_require_token

    while read -r svc path key gen; do
        value="$(kv_get "$path" "$key")" \
            || die "секрета $key нет в Vault ($KV_MOUNT/$KV_PREFIX/$path). На сервере: scripts/secrets.sh init $SERVICE"

        # Значения подставляются в JAAS, JSON и SQL — допускаем только безопасные символы.
        [[ "$value" =~ ^[A-Za-z0-9_-]+$ ]] \
            || die "$key содержит недопустимые символы (разрешены A-Z a-z 0-9 _ -)"

        mask "$value"
        export "$key=$value"
        count=$((count + 1))
    done < <(manifest "$SERVICE")

    log "secrets loaded: $count"
}

# ============================================================
# Files
# ============================================================

sync_files() {
    local target="$TF_INFRA_DIR/$SERVICE"

    mkdir -p "$TF_INFRA_DIR"
    log "copying $SERVICE ($(git -C "$TF_ROOT" rev-parse --short HEAD)) -> $target"
    git -C "$TF_ROOT" archive --format=tar HEAD "$SERVICE" | tar -x -C "$TF_INFRA_DIR"

    cd "$target"
}

# wait_init <контейнер> — ждёт одноразовый init-контейнер и проверяет код выхода.
wait_init() {
    local code
    log "waiting for $1..."
    code="$(timeout 600 docker wait "$1")" || die "$1 не завершился за 10 минут"
    docker logs "$1" 2>&1 | tail -n 30
    [ "$code" = "0" ] || die "$1 завершился с кодом $code"
}

# ============================================================
# Services
# ============================================================

deploy_postgree() {
    local schema upper key env_args=()

    # Каждой схеме из schemas.conf нужны пароли в secrets.conf.
    while IFS= read -r schema; do
        upper="${schema^^}"
        for key in "TF_PG_${upper}_ADMIN_PASSWORD" "TF_PG_${upper}_USER_PASSWORD"; do
            [ -n "${!key:-}" ] || die "схема $schema: нет $key в secrets.conf"
            env_args+=(-e "$key")
        done
    done < <(tr -d '\r' < db/schemas.conf | sed 's/#.*//' | awk 'NF { print $1 }')

    docker compose up -d --wait postgres

    # POSTGRES_PASSWORD образ применяет только при создании базы. Синхронизируем с Vault
    # при каждой выкатке (локальный вход в контейнере без пароля).
    log "syncing password of user tf"
    printf "ALTER USER tf PASSWORD '%s';\n" "$POSTGRES_PASSWORD" \
        | docker exec -i tf-postgres psql -q -U tf -d tf -v ON_ERROR_STOP=1 > /dev/null

    log "creating schemas and syncing schema user passwords"
    docker compose -f docker-compose.create_schema.yml build
    docker compose -f docker-compose.create_schema.yml run --rm -T "${env_args[@]}" create-schema
}

deploy_kafka() {
    docker compose up -d
    wait_init tf-kafka-init
}

deploy_rabbitmq() {
    docker compose up -d
    wait_init tf-rabbit-init
}

deploy_redis() {
    docker compose up -d --wait
}

deploy_web_server() {
    local var
    for var in DOMAIN LETSENCRYPT_EMAIL; do
        [ "${!var:-CHANGE_ME}" != "CHANGE_ME" ] || die "$var не задан в stands/$TF_STAND.env"
    done

    if [ ! -f "certbot/conf/live/$DOMAIN/fullchain.pem" ]; then
        # Первый запуск: сертификата нет, nginx ещё не занимает порт 80.
        log "no certificate for $DOMAIN, requesting from Let's Encrypt"
        bash scripts/init-letsencrypt.sh
    fi

    bash scripts/generate-nginx-config.sh
    docker compose up -d --wait
    docker compose exec -T nginx nginx -t
    docker compose exec -T nginx nginx -s reload
}

deploy_hashicorp() {
    local rc=0
    docker compose up -d
    # Ждём, пока Vault ответит (запечатанный — тоже ответ).
    for _ in $(seq 1 30); do
        rc=0
        docker exec "$VAULT_CONTAINER" vault status > /dev/null 2>&1 || rc=$?
        [ "$rc" -ne 1 ] && break
        sleep 2
    done
    [ "$rc" -ne 1 ] || die "Vault не отвечает: docker logs $VAULT_CONTAINER"
    [ "$rc" -eq 0 ] || log "WARNING: Vault запечатан — распечатать (hashicorp/README.md)"
}

# ============================================================
# Main
# ============================================================

command -v docker > /dev/null || die "docker не установлен"

log "============================================================"
log "Deploy $SERVICE to stand $TF_STAND ($TF_INFRA_DIR)"
log "============================================================"

load_secrets
sync_files
"deploy_${SERVICE//-/_}"

log "Deploy $SERVICE finished successfully."
