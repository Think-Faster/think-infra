#!/bin/bash
set -e

DOMAIN="${DOMAIN:-tf.greefob.ru}"
REALM="${REALM:-TF.GREEFOB.RU}"
NETBIOS="${NETBIOS:-TF}"
# Пароля по умолчанию нет: без ADMIN_PASSWORD каталог не создаётся.
: "${ADMIN_PASSWORD:?ADMIN_PASSWORD is not set}"

echo "======================================"
echo "Samba AD DC"
echo "DOMAIN:  $DOMAIN"
echo "REALM:   $REALM"
echo "NETBIOS: $NETBIOS"
echo "======================================"

mkdir -p /var/lib/samba
mkdir -p /etc/samba

if [ ! -f /var/lib/samba/private/sam.ldb ]; then

    echo "Provisioning new Active Directory..."

    rm -f /etc/samba/smb.conf

    samba-tool domain provision \
        --realm="$REALM" \
        --domain="$NETBIOS" \
        --server-role=dc \
        --dns-backend=SAMBA_INTERNAL \
        --adminpass="$ADMIN_PASSWORD" \
        --use-rfc2307 \n        --skip-sysvolacl

    echo "AD provisioned."

fi

echo "Starting Samba AD DC..."

exec samba -i -M single
