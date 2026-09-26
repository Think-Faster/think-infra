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

required_vars=(
    DOMAIN
    LETSENCRYPT_EMAIL
)

for var in "${required_vars[@]}"; do
    if [ -z "${!var:-}" ]; then
        echo "ERROR: Required variable '$var' is not set (stands/<стенд>.env)."
        exit 1
    fi
done


# ==================================================
# Prepare directories
# ==================================================

mkdir -p certbot/conf
mkdir -p certbot/www


# ==================================================
# Choose mode
# ==================================================

# Имена сертификата: DOMAIN и DOMAIN_ALIASES (через запятую). Папка — live/${DOMAIN}.
domain_args=(--cert-name "${DOMAIN}" --domain "${DOMAIN}")
aliases="${DOMAIN_ALIASES:-}"
for alias in ${aliases//,/ }; do
    domain_args+=(--domain "$alias")
done

# nginx уже работает (добавилось имя в DOMAIN_ALIASES) — проверка через его
# /.well-known/acme-challenge/ (webroot). Иначе certbot сам слушает порт 80 (standalone).
if [ -n "$(docker ps -q --filter name='^tf-nginx$' --filter status=running)" ]; then
    MODE=webroot
else
    MODE=standalone
fi


# ==================================================
# Check port 80
# ==================================================

if [ "$MODE" = standalone ]; then

# WEB_BIND — адрес, на котором слушает nginx (stands/<стенд>.env). При 0.0.0.0 мешает любой
# занятый :80, при конкретном адресе — только он сам и «все адреса».
WEB_BIND="${WEB_BIND:-0.0.0.0}"
if [ "$WEB_BIND" = "0.0.0.0" ]; then
    busy="$(ss -lnt 2>/dev/null | awk '$4 ~ /:80$/')"
else
    busy="$(ss -lnt 2>/dev/null | awk -v ip="$WEB_BIND"         '$4 == ip ":80" || $4 == "0.0.0.0:80" || $4 == "*:80" || $4 == "[::]:80"')"
fi

if [ -n "$busy" ]; then
    echo "ERROR: Port 80 is already in use (${WEB_BIND})."
    echo
    echo "Let's Encrypt standalone mode requires port 80."
    exit 1
fi

fi


# ==================================================
# Request certificate
# ==================================================

echo
echo "=============================================="
echo " Let's Encrypt certificate generation"
echo "=============================================="
echo
echo "Domain: ${DOMAIN} ${DOMAIN_ALIASES:-}"
echo "Mode:   ${MODE}"
echo "Email:  ${LETSENCRYPT_EMAIL}"
echo


if [ "$MODE" = webroot ]; then
    mode_args=(-v "$(pwd)/certbot/www:/var/www/certbot")
    certbot_args=(--webroot -w /var/www/certbot)
else
    mode_args=(-p "${WEB_BIND}:80:80")
    certbot_args=(--standalone --preferred-challenges http)
fi

# --expand: к уже выпущенному сертификату добавляются новые имена.
docker run \
    --rm \
    "${mode_args[@]}" \
    -v "$(pwd)/certbot/conf:/etc/letsencrypt" \
    certbot/certbot:latest \
    certonly \
    --non-interactive \
    "${certbot_args[@]}" \
    "${domain_args[@]}" \
    --expand \
    --email "${LETSENCRYPT_EMAIL}" \
    --agree-tos \
    --no-eff-email

# certbot создаёт live/ и archive/ с правами 700 от root: выкатка идёт не от root и не видит
# fullchain.pem. 750 — чтение группе каталога стенда (у /srv/thinkfaster/tf.infra — tf).
# chmod внутри контейнера: на хосте у пользователя выкатки может не быть sudo.
docker run \
    --rm \
    --entrypoint chmod \
    -v "$(pwd)/certbot/conf:/etc/letsencrypt" \
    certbot/certbot:latest \
    750 /etc/letsencrypt/live /etc/letsencrypt/archive


echo
echo "=============================================="
echo " Certificate successfully generated"
echo "=============================================="
echo
echo "Certificate directory:"
echo
echo "  certbot/conf/live/${DOMAIN}/"
echo