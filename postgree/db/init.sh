#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BOOTSTRAP_SCRIPT="$SCRIPT_DIR/bootstrap.sh"
SCHEMAS_FILE="$SCRIPT_DIR/schemas.conf"

log() {
    echo "[INIT] $(date '+%Y-%m-%d %H:%M:%S') $*"
}

error_handler() {
    local exit_code=$?
    log "ERROR: init.sh failed."
    log "Exit code: $exit_code"
    log "Line: ${BASH_LINENO[0]:-unknown}"
    exit "$exit_code"
}

trap error_handler ERR

log "============================================================"
log "TF PostgreSQL schema installer"
log "============================================================"

log "Script directory: $SCRIPT_DIR"
log "Bootstrap script: $BOOTSTRAP_SCRIPT"
log "Schemas file:     $SCHEMAS_FILE"

if [ ! -f "$SCHEMAS_FILE" ]; then
    log "ERROR: schemas.conf not found: $SCHEMAS_FILE"
    exit 1
fi

if [ ! -x "$BOOTSTRAP_SCRIPT" ]; then
    log "ERROR: bootstrap.sh is not executable: $BOOTSTRAP_SCRIPT"
    exit 1
fi

log "Environment:"
log "  POSTGRES_HOST=${POSTGRES_HOST:-<not set>}"
log "  POSTGRES_PORT=${POSTGRES_PORT:-<not set>}"
log "  POSTGRES_DB=${POSTGRES_DB:-<not set>}"
log "  POSTGRES_ADMIN_USER=${POSTGRES_ADMIN_USER:-<not set>}"
log "  POSTGRES_ADMIN_PASSWORD=<hidden>"

log "Checking required environment variables..."

: "${POSTGRES_HOST:?POSTGRES_HOST is not set}"
: "${POSTGRES_PORT:?POSTGRES_PORT is not set}"
: "${POSTGRES_DB:?POSTGRES_DB is not set}"
: "${POSTGRES_ADMIN_USER:?POSTGRES_ADMIN_USER is not set}"
: "${POSTGRES_ADMIN_PASSWORD:?POSTGRES_ADMIN_PASSWORD is not set}"

log "All required environment variables are present."

log "Reading schemas from: $SCHEMAS_FILE"

schema_count=0

while IFS= read -r schema || [ -n "$schema" ]; do

    # Убираем CR на случай Windows-файла
    schema="${schema//$'\r'/}"

    # Убираем пробелы по краям
    schema="$(echo "$schema" | xargs)"

    # Пустая строка
    if [ -z "$schema" ]; then
        continue
    fi

    # Комментарий
    if [[ "$schema" == \#* ]]; then
        log "Skipping comment: $schema"
        continue
    fi

    schema_count=$((schema_count + 1))

    log "------------------------------------------------------------"
    log "Processing schema #$schema_count: $schema"
    log "------------------------------------------------------------"

    "$BOOTSTRAP_SCRIPT" "$schema"

    log "Schema processing finished successfully: $schema"

done < "$SCHEMAS_FILE"

log "------------------------------------------------------------"
log "Schemas processed: $schema_count"
log "------------------------------------------------------------"

log "============================================================"
log "PostgreSQL initialization completed successfully."
log "============================================================"