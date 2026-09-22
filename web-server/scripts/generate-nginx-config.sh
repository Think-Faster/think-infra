#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

# ==================================================
# Load environment
# ==================================================

if [ ! -f .env ]; then
    echo "ERROR: .env file not found."
    echo "Create it first:"
    echo "  cp .env.example .env"
    exit 1
fi

set -a
source .env
set +a


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
        echo "ERROR: Required variable '$var' is not set."
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

envsubst \
'${DOMAIN} ${FRONTEND_HOST} ${FRONTEND_PORT} ${AUTH_HOST} ${AUTH_PORT} ${BFF_HOST} ${BFF_PORT}' \
< nginx/nginx.conf.template \
> nginx/nginx.conf


echo "==> nginx.conf generated successfully."

echo
echo "Generated file:"
echo "  nginx/nginx.conf"