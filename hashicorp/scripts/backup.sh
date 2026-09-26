#!/bin/sh
# Снапшот хранилища Vault в hashicorp/backups/vault-<дата>.snap.
# Запуск из папки hashicorp:  VAULT_TOKEN=<токен> sh scripts/backup.sh
# Токен — от `scripts/setup.sh backup-token` (политика tf-backup).
# Для cron — см. README. Хранится последние KEEP снапшотов.
set -eu

: "${VAULT_TOKEN:?VAULT_TOKEN is not set}"
export VAULT_TOKEN
KEEP="${KEEP:-14}"
VAULT_CONTAINER="${VAULT_CONTAINER:-vault}"

cd "$(dirname "$0")/.."
mkdir -p backups

name="vault-$(date +%Y%m%d-%H%M%S).snap"

# Токен периодический: продлеваем при каждом запуске, иначе через 32 дня истечёт.
docker exec -e VAULT_TOKEN "$VAULT_CONTAINER" vault token renew > /dev/null 2>&1 || true

docker exec -e VAULT_TOKEN "$VAULT_CONTAINER" \
  vault operator raft snapshot save "/tmp/$name"
docker cp "$VAULT_CONTAINER:/tmp/$name" "backups/$name"
docker exec "$VAULT_CONTAINER" rm -f "/tmp/$name"

# Удалить старые снапшоты, оставив KEEP последних.
ls -1t backups/vault-*.snap | tail -n +"$((KEEP + 1))" | xargs -r rm -f

echo "saved backups/$name"
