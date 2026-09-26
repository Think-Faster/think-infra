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
# Check port 80
# ==================================================

if ss -lnt 2>/dev/null | grep -q ':80 '; then
    echo "ERROR: Port 80 is already in use."
    echo
    echo "Let's Encrypt standalone mode requires port 80."
    exit 1
fi


# ==================================================
# Request certificate
# ==================================================

echo
echo "=============================================="
echo " Let's Encrypt certificate generation"
echo "=============================================="
echo
echo "Domain: ${DOMAIN}"
echo "Email:  ${LETSENCRYPT_EMAIL}"
echo


docker run \
    --rm \
    -p 80:80 \
    -v "$(pwd)/certbot/conf:/etc/letsencrypt" \
    certbot/certbot:latest \
    certonly \
    --standalone \
    --preferred-challenges http \
    --domain "${DOMAIN}" \
    --email "${LETSENCRYPT_EMAIL}" \
    --agree-tos \
    --no-eff-email


echo
echo "=============================================="
echo " Certificate successfully generated"
echo "=============================================="
echo
echo "Certificate directory:"
echo
echo "  certbot/conf/live/${DOMAIN}/"
echo