#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

# ==================================================
# Load environment
# ==================================================

# Переменные задаёт scripts/deploy.sh из stands/<стенд>.env.
# Для ручного запуска можно положить их в web-server/.env.

if [ -f .env ]; then
    set -a
    source .env
    set +a
fi


# ==================================================
# Validate environment
# ==================================================

# Модель: имя контейнера в think-fast-net одинаково на всех стендах, в stands/*.env можно не задавать.
ML_HOST="${ML_HOST:-tf-model}"
ML_PORT="${ML_PORT:-8000}"

required_vars=(
    DOMAIN
    DOCKER_NETWORK

    FRONTEND_HOST
    FRONTEND_PORT

    AUTH_HOST
    AUTH_PORT

    BFF_HOST
    BFF_PORT

    FUNNEL_HOST
    FUNNEL_PORT

    ML_HOST
    ML_PORT
)

for var in "${required_vars[@]}"; do
    if [ -z "${!var:-}" ]; then
        echo "ERROR: Required variable '$var' is not set (stands/<стенд>.env)."
        exit 1
    fi
done


# ==================================================
# Check certificate
# ==================================================

CERTIFICATE="certbot/conf/live/${DOMAIN}/fullchain.pem"
PRIVATE_KEY="certbot/conf/live/${DOMAIN}/privkey.pem"

if [ ! -f "$CERTIFICATE" ]; then
    echo "ERROR: Certificate not found:"
    echo "  $CERTIFICATE"
    echo
    echo "Run:"
    echo "  ./scripts/init-letsencrypt.sh"
    exit 1
fi

if [ ! -f "$PRIVATE_KEY" ]; then
    echo "ERROR: Private key not found:"
    echo "  $PRIVATE_KEY"
    exit 1
fi


# ==================================================
# Generate nginx.conf
# ==================================================

echo "==> Generating nginx.conf..."

# server_name: основной домен и DOMAIN_ALIASES (через запятую в файле стенда).
aliases="${DOMAIN_ALIASES:-}"
SERVER_NAMES="$DOMAIN ${aliases//,/ }"
SERVER_NAMES="${SERVER_NAMES% }"

# Порт 80 отвечает и за поддомен Vault: проверка Let's Encrypt и редирект на HTTPS.
HTTP_SERVER_NAMES="$SERVER_NAMES${VAULT_DOMAIN:+ $VAULT_DOMAIN}"

# envsubst берётся из образа nginx: на хосте gettext может не быть.
# Подставляются только перечисленные переменные, $host и т.п. остаются для nginx.
# Значения — явно (не секреты): docker может вызываться через sudo, который очищает окружение.
# render <шаблон> <имена переменных> <-e VAR=...>...
render() {
    local template="$1" names="$2"
    shift 2
    docker run --rm -i "$@" nginx:1.29-alpine envsubst "$names" < "$template"
}

# access_rules <ИМЯ_НАСТРОЙКИ> — правила nginx из списка адресов и подсетей через запятую:
# "allow a; allow b; deny all;". Пусто — пустая строка (доступ всем).
access_rules() {
    local name="$1" list="${!1:-}" net rules=""
    for net in ${list//,/ }; do
        if [[ ! "$net" =~ ^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$ ]]; then
            echo "ERROR: $name: '$net' — не адрес и не подсеть (stands/<стенд>.env)." >&2
            exit 1
        fi
        rules+="allow $net; "
    done
    [ -z "$rules" ] || rules+="deny all;"
    printf '%s' "$rules"
}

# FUNNEL_EVENTS_ALLOW: статический IP шины — только он может слать пакеты в /api/funnel/events.
FUNNEL_EVENTS_ACCESS="$(access_rules FUNNEL_EVENTS_ALLOW)"

# Пишем через временный файл: nginx.conf смонтирован в контейнер, частичный файл ему не нужен.
render nginx/nginx.conf.template \
    '${DOMAIN} ${SERVER_NAMES} ${HTTP_SERVER_NAMES} ${FRONTEND_HOST} ${FRONTEND_PORT} ${AUTH_HOST} ${AUTH_PORT} ${BFF_HOST} ${BFF_PORT} ${FUNNEL_HOST} ${FUNNEL_PORT} ${FUNNEL_EVENTS_ACCESS} ${ML_HOST} ${ML_PORT}' \
    -e "DOMAIN=$DOMAIN" -e "SERVER_NAMES=$SERVER_NAMES" -e "HTTP_SERVER_NAMES=$HTTP_SERVER_NAMES" \
    -e "FRONTEND_HOST=$FRONTEND_HOST" -e "FRONTEND_PORT=$FRONTEND_PORT" \
    -e "AUTH_HOST=$AUTH_HOST" -e "AUTH_PORT=$AUTH_PORT" \
    -e "BFF_HOST=$BFF_HOST" -e "BFF_PORT=$BFF_PORT" \
    -e "FUNNEL_HOST=$FUNNEL_HOST" -e "FUNNEL_PORT=$FUNNEL_PORT" -e "FUNNEL_EVENTS_ACCESS=$FUNNEL_EVENTS_ACCESS" \
    > nginx/nginx.conf.tmp

# cat, а не mv: сохраняем inode файла, смонтированного в работающий контейнер.
cat nginx/nginx.conf.tmp > nginx/nginx.conf
rm -f nginx/nginx.conf.tmp


# ==================================================
# Vault UI (tf.d/vault.conf)
# ==================================================

# Каталог смонтирован в контейнер целиком: файлы в нём можно заменять и удалять.
mkdir -p nginx/tf.d

if [ -n "${VAULT_DOMAIN:-}" ]; then
    echo "==> Generating tf.d/vault.conf (https://$VAULT_DOMAIN)..."

    # VAULT_ALLOW: адреса и подсети через запятую. Пусто — доступ всем, защита — токен Vault.
    VAULT_ACCESS="$(access_rules VAULT_ALLOW)"

    render nginx/vault.conf.template '${DOMAIN} ${VAULT_DOMAIN} ${VAULT_ACCESS}' \
        -e "DOMAIN=$DOMAIN" -e "VAULT_DOMAIN=$VAULT_DOMAIN" -e "VAULT_ACCESS=$VAULT_ACCESS" \
        > nginx/tf.d/vault.conf
else
    rm -f nginx/tf.d/vault.conf
fi


echo "==> nginx.conf generated successfully."

echo
echo "Generated files:"
echo "  nginx/nginx.conf"
ls nginx/tf.d/*.conf 2> /dev/null | sed 's/^/  /' || true
