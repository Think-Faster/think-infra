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
    DOCKER_NETWORK

    FRONTEND_HOST
    FRONTEND_PORT

    AUTH_HOST
    AUTH_PORT

    BFF_HOST
    BFF_PORT
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

# envsubst берётся из образа nginx: на хосте gettext может не быть.
# Подставляются только перечисленные переменные, $host и т.п. остаются для nginx.
# Пишем через временный файл: nginx.conf смонтирован в контейнер, частичный файл ему не нужен.
docker run --rm -i \
    -e DOMAIN -e FRONTEND_HOST -e FRONTEND_PORT -e AUTH_HOST -e AUTH_PORT -e BFF_HOST -e BFF_PORT \
    nginx:1.29-alpine \
    envsubst '${DOMAIN} ${FRONTEND_HOST} ${FRONTEND_PORT} ${AUTH_HOST} ${AUTH_PORT} ${BFF_HOST} ${BFF_PORT}' \
    < nginx/nginx.conf.template \
    > nginx/nginx.conf.tmp

# cat, а не mv: сохраняем inode файла, смонтированного в работающий контейнер.
cat nginx/nginx.conf.tmp > nginx/nginx.conf
rm -f nginx/nginx.conf.tmp


echo "==> nginx.conf generated successfully."

echo
echo "Generated file:"
echo "  nginx/nginx.conf"