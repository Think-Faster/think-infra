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
