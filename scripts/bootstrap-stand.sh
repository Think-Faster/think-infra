#!/bin/bash
# Разворачивает и настраивает всю инфраструктуру на стенде одной командой.
# Запускается на сервере стенда из клона репозитория (ветка = стенд), в терминале:
#
#   scripts/bootstrap-stand.sh <dev|prod> [--skip <сервис>]...
#
#   --skip web-server   не выкатывать сервис (например, пока нет DNS для Let's Encrypt)
#
# Шаги — каждый идемпотентен, после ошибки скрипт можно просто запустить снова:
#   1. проверки: docker, git, openssl, права на $TF_INFRA_DIR, настройки stands/<стенд>.env
#   2. docker-сеть think-fast-net
#   3. Vault: выкатка, инициализация (ключи печатаются ОДИН раз), распечатывание
#   4. Vault: хранилище secret/, политики, AppRole для CI (hashicorp/scripts/setup.sh apply)
#   5. секреты: генерация недостающих (scripts/secrets.sh init)
#   6. сервисы: postgree, redis, kafka, rabbitmq, web-server (scripts/deploy.sh)
#   7. cron: ежедневные бэкапы Vault и PostgreSQL
#   8. доступ CI и сервисов (VAULT_ROLE_ID / VAULT_SECRET_ID) и личный токен администратора
#   9. отзыв root-токена (по желанию)
#
# Токен Vault: на новом стенде — root из инициализации; на существующем — спросит
# (или взять из VAULT_TOKEN). Нужен root: шаг 4 создаёт политики.

set -Eeuo pipefail

LOG_TAG="STAND"
source "$(dirname "$0")/lib/vault.sh"

SERVICES=(postgree redis kafka rabbitmq web-server)
NETWORK="think-fast-net"

# ============================================================
# Arguments
# ============================================================

[ "$#" -ge 1 ] || usage
STAND="$1"; shift
SKIP=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        --skip) SKIP+=("${2:?--skip <сервис>}"); shift 2 ;;
        *) usage ;;
    esac
done

skipped() {
    local s
    for s in "${SKIP[@]+"${SKIP[@]}"}"; do
        [ "$s" = "$1" ] && return 0
    done
    return 1
}

export TF_STAND="$STAND"

step() {
    echo >&2
    log "============================================================"
    log "$*"
    log "============================================================"
}

confirm() {
    local answer
    read -r -p "$1 [y/N] " answer
    [[ "$answer" =~ ^[yYдД] ]]
}

# ============================================================
# 1. Checks
# ============================================================

step "1/9 Проверки"

[ -t 0 ] || die "скрипт интерактивный (спрашивает ключи Vault) — запускать в терминале"

for cmd in docker git openssl; do
    command -v "$cmd" > /dev/null || die "не установлен: $cmd"
done
docker compose version > /dev/null 2>&1 || die "нужен docker compose v2"
docker info > /dev/null 2>&1 || die "нет доступа к docker (пользователь в группе docker?)"

load_stand_env
: "${TF_INFRA_DIR:?TF_INFRA_DIR is not set (stands/$STAND.env)}"

if ! skipped web-server; then
    for var in DOMAIN LETSENCRYPT_EMAIL; do
        [ "${!var:-CHANGE_ME}" != "CHANGE_ME" ] \
            || die "$var не задан в stands/$STAND.env (или запустить с --skip web-server)"
    done
fi

mkdir -p "$TF_INFRA_DIR" 2> /dev/null && [ -w "$TF_INFRA_DIR" ] \
    || die "нет прав на $TF_INFRA_DIR: sudo mkdir -p $TF_INFRA_DIR && sudo chown $(id -un) $TF_INFRA_DIR"

branch="$(git -C "$TF_ROOT" rev-parse --abbrev-ref HEAD)"
if [ "$branch" != "$STAND" ]; then
    log "WARNING: выкатывается ветка '$branch', а стенд — '$STAND'"
    confirm "Продолжить?" || exit 1
fi
if [ -n "$(git -C "$TF_ROOT" status --porcelain)" ]; then
    log "WARNING: есть незакоммиченные изменения — выкатывается только закоммиченное (HEAD)"
fi

log "stand:     $STAND"
log "infra dir: $TF_INFRA_DIR"
log "commit:    $(git -C "$TF_ROOT" log -1 --format='%h %s')"
log "services:  ${SERVICES[*]}${SKIP[*]:+ (skip: ${SKIP[*]})}"

# ============================================================
# 2. Network
# ============================================================

step "2/9 Сеть $NETWORK"

if docker network inspect "$NETWORK" > /dev/null 2>&1; then
    log "network exists"
else
    docker network create "$NETWORK" > /dev/null
    log "network created"
fi

# ============================================================
# 3. Vault: deploy, init, unseal
# ============================================================

step "3/9 Vault"

bash "$TF_ROOT/scripts/deploy.sh" hashicorp < /dev/null

vault_state() {
    docker exec "$VAULT_CONTAINER" vault status -format=json 2> /dev/null || true
}

if vault_state | grep -q '"initialized": false'; then
    log "Vault не инициализирован — инициализация"

    init_out="$(docker exec "$VAULT_CONTAINER" vault operator init -key-shares=3 -key-threshold=2)"
    mapfile -t unseal_keys < <(echo "$init_out" | sed -n 's/^Unseal Key [0-9]*: //p')
    root_token="$(echo "$init_out" | sed -n 's/^Initial Root Token: //p')"
    [ "${#unseal_keys[@]}" -eq 3 ] && [ -n "$root_token" ] || die "не удалось разобрать вывод vault operator init"

    cat >&2 <<EOF

################################################################################
#  Ключи Vault стенда $STAND. Показываются ОДИН раз и больше нигде не хранятся.
#  Сохраните их в менеджер паролей команды СЕЙЧАС. Без них данные не восстановить.
#  Для распечатывания после каждого перезапуска нужны любые 2 ключа из 3.
################################################################################

$(echo "$init_out" | grep -E '^(Unseal Key|Initial Root Token)')

################################################################################
EOF
    answer=""
    while [ "$answer" != "saved" ]; do
        read -r -p "Введите 'saved', когда ключи сохранены: " answer
    done
    clear || true

    docker exec "$VAULT_CONTAINER" vault operator unseal "${unseal_keys[0]}" > /dev/null
    docker exec "$VAULT_CONTAINER" vault operator unseal "${unseal_keys[1]}" > /dev/null
    unset unseal_keys init_out

    export VAULT_TOKEN="$root_token"
    unset root_token
else
    log "Vault уже инициализирован"

    while vault_state | grep -q '"sealed": true'; do
        read -r -s -p "Vault запечатан. Ключ распечатывания: " key
        echo >&2
        docker exec "$VAULT_CONTAINER" vault operator unseal "$key" > /dev/null || log "ключ не принят"
        unset key
    done

    if [ -z "${VAULT_TOKEN:-}" ]; then
        log "нужен root-токен (если отозван — выпустить: hashicorp/README.md, «6. Отозвать root-токен»)"
        read -r -s -p "Root-токен Vault: " VAULT_TOKEN
        echo >&2
        export VAULT_TOKEN
    fi
fi

vault_require_unsealed
vault_require_token
log "Vault готов"

# ============================================================
# 4. Vault: policies, AppRole
# ============================================================

step "4/9 Настройка Vault"

bash "$TF_ROOT/hashicorp/scripts/setup.sh" apply < /dev/null

# ============================================================
# 5. Secrets
# ============================================================

step "5/9 Секреты"

bash "$TF_ROOT/scripts/secrets.sh" init < /dev/null
bash "$TF_ROOT/scripts/secrets.sh" status < /dev/null

# ============================================================
# 6. Services
# ============================================================

step "6/9 Сервисы"

for svc in "${SERVICES[@]}"; do
    if skipped "$svc"; then
        log "skip $svc"
        continue
    fi
    # stdin закрыт: docker compose run иначе съест ввод из терминала.
    bash "$TF_ROOT/scripts/deploy.sh" "$svc" < /dev/null
done

# ============================================================
# 7. Cron: backups
# ============================================================

step "7/9 Бэкапы (cron)"

# install_cron <метка> <строка> — добавляет или заменяет задачу с меткой.
install_cron() {
    local tag="# tf-infra:$1"
    { crontab -l 2> /dev/null | grep -vF "$tag" || true; echo "$2 $tag"; } | crontab -
    log "cron: $1"
}

if command -v crontab > /dev/null; then
    backup_token_file="$TF_INFRA_DIR/hashicorp/.backup-token"
    if [ ! -s "$backup_token_file" ]; then
        (umask 077 && bash "$TF_ROOT/hashicorp/scripts/setup.sh" backup-token | tr -d '\n' > "$backup_token_file")
        log "backup token saved to $backup_token_file (chmod 600)"
    fi
    mkdir -p "$TF_INFRA_DIR/hashicorp/backups"

    install_cron vault-backup \
        "0 3 * * * VAULT_TOKEN_FILE=$backup_token_file sh $TF_INFRA_DIR/hashicorp/scripts/backup.sh >> $TF_INFRA_DIR/hashicorp/backups/backup.log 2>&1"
    install_cron postgres-backup \
        "0 4 * * * bash $TF_INFRA_DIR/postgree/backup.sh >> $TF_INFRA_DIR/postgree/backup.log 2>&1"

    if crontab -l 2> /dev/null | grep -q "TF PostgreSQL backup"; then
        log "WARNING: в crontab есть старая задача postgree/cron-control.sh — удалите её (crontab -e)"
    fi
else
    log "WARNING: crontab не установлен — бэкапы не запланированы (hashicorp/README.md, «Бэкапы»)"
fi

# ============================================================
# 8. Access: CI, admin
# ============================================================

step "8/9 Доступ"

if vault_cmd list auth/approle/role/tf-deploy/secret-id > /dev/null 2>&1; then
    log "доступ CI уже выдан. Выпустить новый (старый перестанет работать):"
    log "  hashicorp/scripts/setup.sh ci-credentials --rotate"
else
    echo >&2
    bash "$TF_ROOT/hashicorp/scripts/setup.sh" ci-credentials | sed "s/<стенд>/$STAND/"
fi

# Доступ сервисов приложения (hashicorp/services.conf) — для GitHub их репозиториев.
while read -r service _; do
    if vault_cmd list "auth/approle/role/tf-svc-$service/secret-id" > /dev/null 2>&1; then
        log "доступ $service уже выдан. Новый: hashicorp/scripts/setup.sh service-credentials $service --rotate"
    else
        echo >&2
        bash "$TF_ROOT/hashicorp/scripts/setup.sh" service-credentials "$service" < /dev/null | sed "s/<стенд>/$STAND/"
    fi
done < <(tr -d '\r' < "$TF_ROOT/hashicorp/services.conf" | sed 's/#.*//' | awk 'NF')

echo >&2
read -r -p "Имя администратора для личного токена Vault (Enter — пропустить): " admin_name
if [ -n "$admin_name" ]; then
    echo "Токен $admin_name (сохранить в менеджер паролей):"
    bash "$TF_ROOT/hashicorp/scripts/setup.sh" admin-token "$admin_name"
fi

# ============================================================
# 9. Root token
# ============================================================

step "9/9 Root-токен"

if vault_cmd token lookup -format=json 2> /dev/null | grep -q '"root"'; then
    log "Root-токен нужен только для настройки Vault. Выпустить заново можно ключами распечатывания."
    if confirm "Отозвать root-токен сейчас?"; then
        vault_cmd token revoke -self > /dev/null
        log "root-токен отозван"
    fi
fi

# ============================================================
# Done
# ============================================================

cat >&2 <<EOF

================================================================================
Стенд $STAND развёрнут.

Осталось один раз (README.md, «Настройка стенда»):
  1. GitHub → Settings → Environments → $STAND:
       - Deployment branches: только ветка $STAND
       - Environment secrets: VAULT_ROLE_ID, VAULT_SECRET_ID (выше)
  2. GitHub runner на этом сервере с меткой $STAND:
       ./config.sh --url <репозиторий> --token <token> --labels $STAND
     пользователь runner-а — в группе docker, с правами на запись в $TF_INFRA_DIR.
================================================================================
EOF
