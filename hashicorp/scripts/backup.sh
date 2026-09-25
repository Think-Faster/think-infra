#!/bin/sh
# Снапшот хранилища Vault в hashicorp/backups/vault-<дата>.snap.
# Запуск из папки hashicorp:  VAULT_TOKEN=<токен> sh scripts/backup.sh
# Для cron — см. README. Хранится последние KEEP снапшотов.
set -eu

: "${VAULT_TOKEN:?VAULT_TOKEN is not set}"
KEEP="${KEEP:-14}"

cd "$(dirname "$0")/.."
mkdir -p backups

name="vault-$(date +%Y%m%d-%H%M%S).snap"

docker exec -e VAULT_TOKEN="$VAULT_TOKEN" vault \
  vault operator raft snapshot save "/tmp/$name"
docker cp "vault:/tmp/$name" "backups/$name"
docker exec vault rm -f "/tmp/$name"

# Удалить старые снапшоты, оставив KEEP последних.
ls -1t backups/vault-*.snap | tail -n +"$((KEEP + 1))" | xargs -r rm -f

echo "saved backups/$name"
