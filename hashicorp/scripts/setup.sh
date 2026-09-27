#!/bin/bash
# Настройка Vault стенда для секретов инфраструктуры и выкатки из GitHub Actions.
# Запускается на сервере стенда с root-токеном (см. hashicorp/README.md, «6. Отозвать root-токен»).
#
#   export VAULT_TOKEN=<root-токен>
#   hashicorp/scripts/setup.sh apply                   хранилище secret/, политики, AppRole tf-deploy
#                                                      и роли сервисов из hashicorp/services.conf (идемпотентно)
#   hashicorp/scripts/setup.sh ci-credentials [--rotate]  VAULT_ROLE_ID и новый VAULT_SECRET_ID для GitHub;
#                                                      --rotate сначала отзывает все прежние secret_id
#   hashicorp/scripts/setup.sh service-credentials <сервис> [--rotate]
#                                                      VAULT_ROLE_ID / VAULT_SECRET_ID сервиса (tf-bff, tf-auth, ...)
#   hashicorp/scripts/setup.sh admin-token <имя>       выдать личный токен администратора (политика tf-admin)
#   hashicorp/scripts/setup.sh backup-token            токен для cron-бэкапа (политика tf-backup)
#
# Политики:
#   tf-deploy  только чтение secret/tf/*  — для CI (AppRole tf-deploy)
#   tf-admin   чтение и запись secret/tf/* — для людей (scripts/secrets.sh)
#   tf-backup  только снапшот хранилища    — для hashicorp/scripts/backup.sh
#   tf-svc-<сервис>  чтение своих путей    — для контейнеров сервисов (hashicorp/services.conf)

set -Eeuo pipefail

LOG_TAG="VAULT-SETUP"
source "$(dirname "$0")/../../scripts/lib/vault.sh"

cmd_apply() {
    if vault_cmd secrets list -format=json | grep -q "\"$KV_MOUNT/\""; then
        log "secrets engine $KV_MOUNT/ already enabled"
    else
        vault_cmd secrets enable -path="$KV_MOUNT" kv-v2 > /dev/null
        log "enabled kv-v2 at $KV_MOUNT/"
    fi

    vault_in policy write tf-deploy - > /dev/null <<EOF
# CI: только чтение секретов инфраструктуры.
path "$KV_MOUNT/data/$KV_PREFIX/*" {
  capabilities = ["read"]
}
EOF
    log "policy tf-deploy written"

    vault_in policy write tf-admin - > /dev/null <<EOF
# Администраторы: создание, чтение и изменение секретов инфраструктуры (без удаления).
path "$KV_MOUNT/data/$KV_PREFIX/*" {
  capabilities = ["create", "read", "update", "patch"]
}
path "$KV_MOUNT/metadata/$KV_PREFIX/*" {
  capabilities = ["read", "list"]
}
# Чтобы в веб-интерфейсе открывался корень хранилища (видна только папка tf/).
path "$KV_MOUNT/metadata/" {
  capabilities = ["list"]
}
EOF
    log "policy tf-admin written"

    vault_in policy write tf-backup - > /dev/null <<EOF
# Бэкапы: только снапшот хранилища (hashicorp/scripts/backup.sh).
path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}
EOF
    log "policy tf-backup written"

    if vault_cmd auth list -format=json | grep -q '"approle/"'; then
        log "auth method approle already enabled"
    else
        vault_cmd auth enable approle > /dev/null
        log "enabled auth method approle"
    fi

    # Токен CI живёт 15 минут — этого хватает на выкатку, после неё deploy.sh его отзывает.
    vault_cmd write auth/approle/role/tf-deploy \
        token_policies=tf-deploy \
        token_ttl=15m \
        token_max_ttl=30m \
        secret_id_ttl=0 \
        secret_id_num_uses=0 > /dev/null
    log "AppRole tf-deploy written"

    apply_services

    log "done. Next: $0 ci-credentials"
}

# Политики и AppRole сервисов приложения из hashicorp/services.conf.
apply_services() {
    local file="$TF_ROOT/hashicorp/services.conf" service paths path policy
    [ -f "$file" ] || return 0

    while read -r service paths; do
        [[ "$service" =~ ^[a-z0-9-]+$ ]] || die "неверное имя сервиса в services.conf: $service"
        [ -n "$paths" ] || die "у сервиса $service в services.conf нет путей"

        policy="# Сервис $service: только чтение своих секретов (hashicorp/services.conf)."
        for path in $paths; do
            [[ "$path" =~ ^[a-z0-9/_-]+$ ]] || die "неверный путь в services.conf: $path"
            policy+=$'\n'"path \"$KV_MOUNT/data/$KV_PREFIX/$path\" {"$'\n'"  capabilities = [\"read\"]"$'\n'"}"
        done
        printf '%s\n' "$policy" | vault_in policy write "tf-svc-$service" - > /dev/null

        # Контейнер входит при каждом старте: secret_id бессрочный, токен живёт 5 минут —
        # только чтобы прочитать секреты, потом контейнер его отзывает.
        vault_cmd write "auth/approle/role/tf-svc-$service" \
            token_policies="tf-svc-$service" \
            token_ttl=5m \
            token_max_ttl=15m \
            secret_id_ttl=0 \
            secret_id_num_uses=0 > /dev/null
        log "service $service: policy and AppRole tf-svc-$service ($paths)"
    done < <(tr -d '\r' < "$file" | sed 's/#.*//' | awk 'NF')
}

# print_credentials <роль> [--rotate] — role_id и новый secret_id роли.
print_credentials() {
    local role="$1" role_id secret_id accessor
    vault_cmd read "auth/approle/role/$role" > /dev/null 2>&1 \
        || die "нет AppRole $role — сначала $0 apply"
    if [ "${2:-}" = "--rotate" ]; then
        for accessor in $(vault_cmd list -format=json "auth/approle/role/$role/secret-id" 2> /dev/null \
                          | grep -o '"[^"]*"' | tr -d '"'); do
            vault_cmd write "auth/approle/role/$role/secret-id-accessor/destroy" \
                secret_id_accessor="$accessor" > /dev/null
            log "revoked secret_id $accessor"
        done
    fi
    role_id="$(vault_cmd read -field=role_id "auth/approle/role/$role/role-id")"
    secret_id="$(vault_cmd write -f -field=secret_id "auth/approle/role/$role/secret-id")"
    echo "VAULT_ROLE_ID=$role_id"
    echo "VAULT_SECRET_ID=$secret_id"
}

cmd_ci_credentials() {
    echo "Добавить в GitHub: Settings → Environments → <стенд> → Environment secrets"
    echo
    print_credentials tf-deploy "${1:-}"
}

cmd_service_credentials() {
    local service="${1:?usage: service-credentials <сервис> [--rotate]}"
    echo "Добавить в GitHub репозитория $service: Settings → Environments → <стенд> → Environment secrets"
    echo
    print_credentials "tf-svc-$service" "${2:-}"
}

cmd_admin_token() {
    local name="${1:?usage: admin-token <имя>}"
    # period: scripts/secrets.sh продлевает токен при каждом запуске;
    # если не пользоваться им 30 дней — истечёт, выдать новый.
    vault_cmd token create \
        -policy=tf-admin \
        -period=720h \
        -display-name="$name" \
        -field=token
    echo
}

cmd_backup_token() {
    # Для cron: может только снимать снапшоты. backup.sh продлевает его при каждом запуске.
    vault_cmd token create \
        -policy=tf-backup \
        -orphan \
        -period=768h \
        -display-name=backup \
        -field=token
    echo
}

[ "$#" -ge 1 ] || usage
cmd="$1"; shift

case "$cmd" in
    apply|ci-credentials|service-credentials|admin-token|backup-token) ;;
    *) usage ;;
esac

vault_require_unsealed
vault_require_token

# Все команды setup.sh создают политики, роли и токены — нужен root. Личный токен (tf-admin)
# проходит проверку выше, но дальше получил бы невнятное "permission denied".
if ! vault_cmd token lookup -format=json 2> /dev/null | grep -q '"root"'; then
    die "нужен root-токен (короткий, ~28 символов), а в VAULT_TOKEN другой — например личный tf-admin.
       Root: 'Initial Root Token' из инициализации; если отозван — выпустить ключами распечатывания
       (QUICK_START.md, раздел 13, «Нужен root-токен»)."
fi

"cmd_${cmd//-/_}" "$@"
