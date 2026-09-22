#!/bin/sh
# Загружает топологию из definitions.json и пользователей из users.conf через HTTP API.
# Идемпотентен: существующие exchange, очереди и привязки не дублируются,
# политики, пароли и права перезаписываются значениями из файлов.

set -eu

API="${RABBIT_API:-http://tf-rabbit:15672/api}"
VHOST="tf"
DEFINITIONS_FILE="${DEFINITIONS_FILE:-/etc/tf/definitions.json}"
USERS_FILE="${USERS_FILE:-/etc/tf/users.conf}"

: "${TF_RABBIT_ADMIN_PASSWORD:?TF_RABBIT_ADMIN_PASSWORD is not set}"

log() {
    echo "[RABBIT-INIT] $(date '+%Y-%m-%d %H:%M:%S') $*"
}

fail() {
    log "ERROR: $*"
    exit 1
}

# api <METHOD> <path> [json]
api() {
    if [ -n "${3:-}" ]; then
        curl -sS --fail-with-body -o /tmp/api.out \
            -u "admin:$TF_RABBIT_ADMIN_PASSWORD" \
            -H "content-type: application/json" \
            -X "$1" --data-binary "$3" "$API$2" \
        || { cat /tmp/api.out; echo; return 1; }
    else
        curl -sS --fail-with-body -o /tmp/api.out \
            -u "admin:$TF_RABBIT_ADMIN_PASSWORD" \
            -X "$1" "$API$2" \
        || { cat /tmp/api.out; echo; return 1; }
    fi
}

# Экранирует обратную косую черту и кавычки для JSON.
json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

log "============================================================"
log "TF RabbitMQ topology and users installer"
log "============================================================"
log "API:         $API"
log "Definitions: $DEFINITIONS_FILE"
log "Users:       $USERS_FILE"

[ -f "$DEFINITIONS_FILE" ] || fail "definitions file not found: $DEFINITIONS_FILE"
[ -f "$USERS_FILE" ]       || fail "users file not found: $USERS_FILE"

# ============================================================
# Topology
# ============================================================

log "Importing topology (exchanges, queues, bindings, policies)..."

curl -sS --fail-with-body -o /tmp/api.out \
    -u "admin:$TF_RABBIT_ADMIN_PASSWORD" \
    -H "content-type: application/json" \
    -X POST --data-binary "@$DEFINITIONS_FILE" "$API/definitions" \
|| { cat /tmp/api.out; echo; fail "topology import failed"; }

log "Topology imported."

# ============================================================
# Users
# ============================================================

user_count=0

# Убираем CR (файлы из Windows), комментарии и пустые строки.
tr -d '\r' < "$USERS_FILE" | sed 's/#.*//' | grep -v '^[[:space:]]*$' > /tmp/users.conf || true

while read -r name password_var configure write read extra; do

    if [ -z "$read" ] || [ -n "$extra" ]; then
        fail "invalid line in users file: '$name $password_var $configure $write $read $extra'"
    fi

    case "$password_var" in
        *[!A-Z0-9_]*) fail "invalid password variable name: $password_var" ;;
    esac

    eval "password=\${$password_var:-}"
    [ -n "$password" ] || fail "$password_var is not set (user $name)"

    user_count=$((user_count + 1))

    log "User: $name (configure '$configure', write '$write', read '$read')"

    api PUT "/users/$name" \
        "{\"password\":\"$(json_escape "$password")\",\"tags\":\"\"}" \
    || fail "cannot create/update user $name"

    api PUT "/permissions/$VHOST/$name" \
        "{\"configure\":\"$(json_escape "$configure")\",\"write\":\"$(json_escape "$write")\",\"read\":\"$(json_escape "$read")\"}" \
    || fail "cannot set permissions for $name"

done < /tmp/users.conf

log "Users processed: $user_count"

# ============================================================
# guest
# ============================================================

if curl -sS -o /dev/null -w '%{http_code}' \
        -u "admin:$TF_RABBIT_ADMIN_PASSWORD" "$API/users/guest" | grep -q '^200$'; then
    log "Deleting user guest..."
    api DELETE "/users/guest" || fail "cannot delete guest"
else
    log "User guest does not exist."
fi

# ============================================================
# Result
# ============================================================

log "============================================================"
log "Queues in vhost $VHOST:"
api GET "/queues/$VHOST?columns=name,type,policy" || fail "cannot list queues"
sed 's/},{/}\n{/g' /tmp/api.out | sed 's/^/[RABBIT-INIT]   /'
echo

log "============================================================"
log "RabbitMQ initialization completed successfully."
log "============================================================"
