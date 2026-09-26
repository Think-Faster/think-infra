#!/bin/bash
# Общие функции для scripts/secrets.sh и scripts/deploy.sh.
# Vault вызывается через `docker exec vault vault ...`: CLI на хосте не нужен,
# Vault слушает localhost:8200 внутри своего контейнера.
# Токен берётся из переменной окружения VAULT_TOKEN и передаётся в контейнер без значения
# в командной строке (`-e VAULT_TOKEN`), поэтому не виден в списке процессов.

TF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFEST="$TF_ROOT/secrets.conf"
VAULT_CONTAINER="${VAULT_CONTAINER:-vault}"
KV_MOUNT="secret"
KV_PREFIX="tf"

log() {
    echo "[$LOG_TAG] $*" >&2
}

die() {
    log "ERROR: $*"
    exit 1
}

# vault_cmd <args...> — команда vault без stdin.
vault_cmd() {
    docker exec -e VAULT_TOKEN "$VAULT_CONTAINER" vault "$@" < /dev/null
}

# vault_in <args...> — команда vault, stdin передаётся в контейнер (для значений секретов).
vault_in() {
    docker exec -i -e VAULT_TOKEN "$VAULT_CONTAINER" vault "$@"
}

vault_require_unsealed() {
    local rc=0
    docker exec "$VAULT_CONTAINER" vault status > /dev/null 2>&1 || rc=$?
    case "$rc" in
        0) ;;
        2) die "Vault запечатан (sealed). Распечатайте его: см. hashicorp/README.md" ;;
        *) die "Vault недоступен: контейнер '$VAULT_CONTAINER' не запущен или не инициализирован" ;;
    esac
}

vault_require_token() {
    [ -n "${VAULT_TOKEN:-}" ] || die "VAULT_TOKEN не задан"
    export VAULT_TOKEN
    vault_cmd token lookup > /dev/null 2>&1 || die "токен Vault недействителен или истёк"
    # Периодические токены (admin-token) продлеваются только явно. root не продлевается — не ошибка.
    vault_cmd token renew > /dev/null 2>&1 || true
}

# usage — печатает шапку вызвавшего скрипта (комментарии после #!) и завершается.
usage() {
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
    exit 1
}

# manifest [папка сервиса] — строки secrets.conf без комментариев: <папка> <путь> <ключ> <генератор>
manifest() {
    [ -f "$MANIFEST" ] || die "не найден $MANIFEST"
    tr -d '\r' < "$MANIFEST" | sed 's/#.*//' | awk -v svc="${1:-}" '
        NF == 0 { next }
        NF != 4 { print "invalid line in secrets.conf: " $0 > "/dev/stderr"; exit 1 }
        svc == "" || $1 == svc { print $1, $2, $3, $4 }
    '
}

# lookup_key <КЛЮЧ> — находит ключ в манифесте (ключи уникальны)
# и заполняет KEY_SERVICE, KEY_PATH, KEY_GENERATOR. Вызывать без $(...): die должен завершить скрипт.
lookup_key() {
    local entry key
    entry="$(manifest | awk -v key="$1" '$3 == key')"
    [ -n "$entry" ] || die "ключа $1 нет в secrets.conf"
    [ "$(echo "$entry" | wc -l)" -eq 1 ] || die "ключ $1 встречается в secrets.conf несколько раз"
    read -r KEY_SERVICE KEY_PATH key KEY_GENERATOR <<< "$entry"
}

# kv_get <путь> <КЛЮЧ> — печатает значение или завершается с ненулевым кодом.
kv_get() {
    vault_cmd kv get -mount="$KV_MOUNT" -field="$2" "$KV_PREFIX/$1" 2> /dev/null
}

# kv_write <путь> <КЛЮЧ> — записывает значение из stdin, не трогая остальные ключи пути.
kv_write() {
    local verb=put
    if vault_cmd kv get -mount="$KV_MOUNT" "$KV_PREFIX/$1" > /dev/null 2>&1; then
        verb=patch
    fi
    vault_in kv "$verb" -mount="$KV_MOUNT" "$KV_PREFIX/$1" "$2=-" > /dev/null
}

# generate <генератор> — печатает новое значение без перевода строки.
generate() {
    local value
    case "$1" in
        hex)
            value="$(openssl rand -hex 24)"
            ;;
        ad)
            while :; do
                value="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9')"
                value="${value:0:32}"
                [ "${#value}" -eq 32 ] && [[ "$value" =~ [A-Z] ]] && [[ "$value" =~ [a-z] ]] && [[ "$value" =~ [0-9] ]] && break
            done
            ;;
        cluster-id)
            # Как kafka-storage.sh random-uuid: 16 байт в base64url без '='. Не начинается с '-'.
            while :; do
                value="$(openssl rand -base64 16 | tr '+/' '-_' | tr -d '=\r\n')"
                [[ "$value" != -* ]] && break
            done
            ;;
        *)
            die "неизвестный генератор: $1"
            ;;
    esac
    printf '%s' "$value"
}
