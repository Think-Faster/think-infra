#!/bin/bash
# Управление секретами инфраструктуры в Vault стенда. Список секретов — secrets.conf.
# Запускается на сервере стенда (рядом с контейнером vault) с токеном администратора:
#
#   export VAULT_TOKEN=<токен с политикой tf-admin>
#   scripts/secrets.sh status [папка]      что есть в Vault, чего нет (без значений)
#   scripts/secrets.sh init [папка]        сгенерировать все недостающие секреты
#   scripts/secrets.sh rotate <КЛЮЧ>       сгенерировать новое значение и перезаписать
#   scripts/secrets.sh set <КЛЮЧ>          записать своё значение (из stdin или с клавиатуры)
#   scripts/secrets.sh import <.env> [папка]  перенести значения из старого .env (только недостающие)
#   scripts/secrets.sh relocate <путь>     перенести ключи из старого пути в пути по secrets.conf
#   scripts/secrets.sh get <КЛЮЧ>          напечатать значение (чтобы передать владельцу сервиса)
#   eval "$(scripts/secrets.sh env <папка>)"  секреты сервиса в переменные текущей оболочки
#                                          (для ручных docker compose up / run)
#
# Значения генерируются openssl (см. генераторы в secrets.conf) и сразу пишутся в Vault
# через stdin — на диск и в историю команд не попадают.

set -Eeuo pipefail

LOG_TAG="SECRETS"
source "$(dirname "$0")/lib/vault.sh"

cmd_status() {
    local svc path key gen missing=0
    printf '%-10s %-16s %-30s %s\n' "SERVICE" "PATH" "KEY" "STATUS"
    while read -r svc path key gen; do
        if kv_get "$path" "$key" > /dev/null; then
            printf '%-10s %-16s %-30s %s\n' "$svc" "$path" "$key" "ok"
        else
            printf '%-10s %-16s %-30s %s\n' "$svc" "$path" "$key" "MISSING"
            missing=$((missing + 1))
        fi
    done < <(manifest "${1:-}")
    [ "$missing" -eq 0 ] || { log "missing: $missing (scripts/secrets.sh init)"; exit 2; }
}

cmd_init() {
    local svc path key gen created=0
    while read -r svc path key gen; do
        if kv_get "$path" "$key" > /dev/null; then
            continue
        fi
        if [ "$gen" = "manual" ]; then
            log "skip $key: значение выдаётся извне — scripts/secrets.sh set $key"
            continue
        fi
        generate "$gen" | kv_write "$path" "$key"
        log "generated $KV_MOUNT/$KV_PREFIX/$path $key ($gen)"
        created=$((created + 1))
    done < <(manifest "${1:-}")
    log "created: $created"
}

cmd_rotate() {
    local key="${1:?usage: rotate <KEY>}"
    lookup_key "$key"
    [ "$KEY_GENERATOR" != "cluster-id" ] || die "$key нельзя менять: брокер не стартует на старом томе"
    [ "$KEY_GENERATOR" != "manual" ] || die "$key выдаётся извне — новое значение: scripts/secrets.sh set $key"
    generate "$KEY_GENERATOR" | kv_write "$KEY_PATH" "$key"
    log "rotated $KV_MOUNT/$KV_PREFIX/$KEY_PATH $key"
    log "применить: выкатить '$KEY_SERVICE' (см. README, раздел «Ротация»)"
}

cmd_set() {
    local key="${1:?usage: set <KEY>}" value
    lookup_key "$key"
    if [ -t 0 ]; then
        read -r -s -p "$key: " value
        echo >&2
    else
        value="$(cat)"
    fi
    value="${value//$'\r'/}"
    value="${value%$'\n'}"
    [ -n "$value" ] || die "пустое значение"
    printf '%s' "$value" | kv_write "$KEY_PATH" "$key"
    log "saved $KV_MOUNT/$KV_PREFIX/$KEY_PATH $key"
}

cmd_import() {
    local file="${1:?usage: import <.env> [folder]}" svc path key gen value imported=0
    [ -f "$file" ] || die "файл не найден: $file"
    while read -r svc path key gen; do
        value="$(tr -d '\r' < "$file" | sed -n "s/^$key=//p" | tail -n 1)"
        value="${value%\"}"; value="${value#\"}"
        case "$value" in
            ""|PASSWORD|CHANGE_ME) continue ;;
        esac
        if kv_get "$path" "$key" > /dev/null; then
            log "skip $key: already in Vault"
            continue
        fi
        printf '%s' "$value" | kv_write "$path" "$key"
        log "imported $KV_MOUNT/$KV_PREFIX/$path $key"
        imported=$((imported + 1))
    done < <(manifest "${2:-}")
    log "imported: $imported"
}

# relocate <старый путь> — переносит ключи, которые по secrets.conf теперь живут в другом пути
# (например, TF_KAFKA_BFF_PASSWORD из kafka в kafka/bff), и удаляет их из старого пути.
# Значения не меняются. Повторный запуск ничего не делает.
cmd_relocate() {
    local old="${1:?usage: relocate <старый путь>}" svc path key gen value current moved=0
    vault_cmd kv get -mount="$KV_MOUNT" "$KV_PREFIX/$old" > /dev/null 2>&1 \
        || die "нет $KV_MOUNT/$KV_PREFIX/$old"

    while read -r svc path key gen; do
        [ "$path" != "$old" ] || continue
        value="$(kv_get "$old" "$key")" || continue

        if current="$(kv_get "$path" "$key")"; then
            [ "$current" = "$value" ] \
                || die "$key уже есть в $path с другим значением — разобраться вручную"
        else
            printf '%s' "$value" | kv_write "$path" "$key"
        fi

        # JSON merge patch: null удаляет ключ из старого пути.
        printf '{"%s": null}' "$key" | vault_in kv patch -mount="$KV_MOUNT" "$KV_PREFIX/$old" - > /dev/null
        log "moved $key: $old -> $path"
        moved=$((moved + 1))
    done < <(manifest)

    log "moved: $moved"
}

cmd_get() {
    local key="${1:?usage: get <KEY>}"
    lookup_key "$key"
    kv_get "$KEY_PATH" "$key" || die "$key нет в Vault"
    echo
}

cmd_env() {
    local folder="${1:?usage: env <folder>}" svc path key gen value
    [ -n "$(manifest "$folder")" ] || die "в secrets.conf нет секретов для '$folder'"
    while read -r svc path key gen; do
        value="$(kv_get "$path" "$key")" || die "$key нет в Vault"
        printf 'export %s=%q\n' "$key" "$value"
    done < <(manifest "$folder")
}

command -v openssl > /dev/null || die "openssl не установлен"

[ "$#" -ge 1 ] || usage
cmd="$1"; shift

case "$cmd" in
    status|init|rotate|set|import|relocate|get|env) ;;
    *) usage ;;
esac

vault_require_unsealed
vault_require_token

"cmd_$cmd" "$@"
