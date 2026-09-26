#!/bin/bash
# Общие функции для scripts/secrets.sh и scripts/deploy.sh.
# Vault вызывается через `docker exec vault vault ...`: CLI на хосте не нужен,
# Vault слушает localhost:8200 внутри своего контейнера.
# Токен берётся из переменной окружения VAULT_TOKEN и передаётся в контейнер через stdin.

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

# Токен передаётся в контейнер первой строкой stdin, а не через `docker exec -e`:
# на сервере docker может вызываться через sudo, который очищает переменные окружения.
# В командную строку токен тоже не попадает.
VAULT_EXEC='IFS= read -r t; if [ -n "$t" ]; then VAULT_TOKEN="$t"; export VAULT_TOKEN; fi; exec vault "$@"'

# vault_cmd <args...> — команда vault без данных на stdin.
vault_cmd() {
    printf '%s\n' "${VAULT_TOKEN:-}" \
        | docker exec -i "$VAULT_CONTAINER" sh -c "$VAULT_EXEC" vault "$@"
}

# vault_in <args...> — команда vault, stdin передаётся в контейнер (для значений секретов).
vault_in() {
    { printf '%s\n' "${VAULT_TOKEN:-}"; cat; } \
        | docker exec -i "$VAULT_CONTAINER" sh -c "$VAULT_EXEC" vault "$@"
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

# user_home — домашний каталог текущего пользователя. Из системной записи, а не из $HOME:
# у GitHub runner-а, запущенного службой, $HOME может быть не задан.
user_home() {
    local home=""
    if command -v getent > /dev/null; then
        home="$(getent passwd "$(id -un)" | cut -d: -f6)"
    fi
    [ -n "$home" ] || home="${HOME:?не удалось определить домашний каталог}"
    echo "$home"
}

# load_stand_env — экспортирует несекретные настройки из stands/$TF_STAND.env.
# Переменная, уже заданная в окружении, не перезаписывается.
# STAND_KEYS — имена переменных из файла стенда (для scripts/deploy.sh: env-файл compose).
STAND_KEYS=()

load_stand_env() {
    local file line key value
    [ -n "${TF_STAND:-}" ] || die "TF_STAND не задан (dev или prod)"
    [[ "$TF_STAND" =~ ^[a-z0-9_-]+$ ]] || die "неверное имя стенда: $TF_STAND"
    file="$TF_ROOT/stands/$TF_STAND.env"
    [ -f "$file" ] || die "нет настроек стенда: $file"

    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || die "неверная строка в $file: $line"
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        # Секреты — только в Vault.
        if manifest | awk -v key="$key" '$3 == key { found = 1 } END { exit !found }'; then
            die "$key — секрет (secrets.conf), ему не место в $file"
        fi
        # ~/путь — в домашнем каталоге пользователя, от которого идёт выкатка.
        if [[ "$value" == "~/"* ]]; then
            value="$(user_home)/${value#\~/}"
        fi
        [ -n "${!key+x}" ] || export "$key=$value"
        STAND_KEYS+=("$key")
    done < "$file"
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
