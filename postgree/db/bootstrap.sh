#!/bin/bash

set -Eeuo pipefail

POSTGRES_HOST="${POSTGRES_HOST:-tf-postgres}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_DB="${POSTGRES_DB:-tf}"
POSTGRES_ADMIN_USER="${POSTGRES_ADMIN_USER:-postgres}"
POSTGRES_ADMIN_PASSWORD="${POSTGRES_ADMIN_PASSWORD:-}"

if [ "$#" -ne 1 ]; then
    echo "[BOOTSTRAP] ERROR: expected exactly one argument."
    echo "[BOOTSTRAP] Usage: $0 <schema_name>"
    exit 1
fi

SCHEMA_NAME="$1"

log() {
    echo "[BOOTSTRAP] $(date '+%Y-%m-%d %H:%M:%S') $*"
}

error_handler() {
    local exit_code=$?

    log "============================================================"
    log "ERROR: bootstrap.sh failed"
    log "Schema: $SCHEMA_NAME"
    log "Exit code: $exit_code"
    log "============================================================"

    exit "$exit_code"
}

trap error_handler ERR

log "============================================================"
log "Starting schema bootstrap"
log "============================================================"

log "Schema:            $SCHEMA_NAME"
log "PostgreSQL host:   $POSTGRES_HOST"
log "PostgreSQL port:   $POSTGRES_PORT"
log "Database:          $POSTGRES_DB"
log "Admin user:        $POSTGRES_ADMIN_USER"
log "Admin password:    <hidden>"

if [ -z "$POSTGRES_ADMIN_PASSWORD" ]; then
    log "ERROR: POSTGRES_ADMIN_PASSWORD is empty."
    exit 1
fi

# ------------------------------------------------------------
# Validate schema name
# ------------------------------------------------------------

log "Validating schema name..."

if [[ ! "$SCHEMA_NAME" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
    log "ERROR: invalid schema name: $SCHEMA_NAME"
    log "Allowed characters: letters, numbers and underscore."
    exit 1
fi

log "Schema name is valid."

# ------------------------------------------------------------
# Build names
# ------------------------------------------------------------

MAINTENANCE_ROLE="${SCHEMA_NAME}_maintenance"
READ_WRITE_ROLE="${SCHEMA_NAME}_read_write"

ADMIN_USER="${SCHEMA_NAME}_admin"
APP_USER="${SCHEMA_NAME}_user"

log "Generated PostgreSQL objects:"
log "  Schema:          $SCHEMA_NAME"
log "  Maintenance:     $MAINTENANCE_ROLE"
log "  Read/write:      $READ_WRITE_ROLE"
log "  Admin user:      $ADMIN_USER"
log "  Application user:$APP_USER"

# ------------------------------------------------------------
# PostgreSQL connectivity
# ------------------------------------------------------------

log "Checking PostgreSQL connectivity..."

log "Running pg_isready..."

if ! pg_isready \
    -h "$POSTGRES_HOST" \
    -p "$POSTGRES_PORT" \
    -U "$POSTGRES_ADMIN_USER" \
    -d "$POSTGRES_DB"; then

    log "ERROR: PostgreSQL is not available."
    log "Host:     $POSTGRES_HOST"
    log "Port:     $POSTGRES_PORT"
    log "Database: $POSTGRES_DB"
    log "User:     $POSTGRES_ADMIN_USER"

    log "DNS check:"
    getent hosts "$POSTGRES_HOST" || true

    log "Network check:"
    if command -v nc >/dev/null 2>&1; then
        nc -vz "$POSTGRES_HOST" "$POSTGRES_PORT" || true
    else
        log "nc is not installed."
    fi

    exit 1
fi

log "PostgreSQL is reachable."

# ------------------------------------------------------------
# PostgreSQL authentication
# ------------------------------------------------------------

log "Testing PostgreSQL authentication..."

if ! PGPASSWORD="$POSTGRES_ADMIN_PASSWORD" \
    psql \
        -h "$POSTGRES_HOST" \
        -p "$POSTGRES_PORT" \
        -U "$POSTGRES_ADMIN_USER" \
        -d "$POSTGRES_DB" \
        -c "SELECT current_database(), current_user;" \
        >/tmp/bootstrap_connection_test.log 2>&1; then

    log "ERROR: PostgreSQL authentication failed."

    log "psql output:"
    cat /tmp/bootstrap_connection_test.log

    rm -f /tmp/bootstrap_connection_test.log

    exit 1
fi

rm -f /tmp/bootstrap_connection_test.log

log "PostgreSQL authentication successful."

# ------------------------------------------------------------
# Check schema existence
# ------------------------------------------------------------

log "Checking whether schema '$SCHEMA_NAME' already exists..."

SCHEMA_EXISTS=$(
    PGPASSWORD="$POSTGRES_ADMIN_PASSWORD" \
    psql \
        -h "$POSTGRES_HOST" \
        -p "$POSTGRES_PORT" \
        -U "$POSTGRES_ADMIN_USER" \
        -d "$POSTGRES_DB" \
        -tAc \
        "SELECT 1 FROM pg_namespace WHERE nspname = '$SCHEMA_NAME';"
)

SCHEMA_EXISTS="$(echo "$SCHEMA_EXISTS" | xargs)"

if [ "$SCHEMA_EXISTS" = "1" ]; then
    log "Schema '$SCHEMA_NAME' already exists."
    log "IMPORTANT: Existing schema will NOT be modified."
    log "Skipping."

    exit 0
fi

log "Schema '$SCHEMA_NAME' does not exist."
log "A new schema will be created."

# ------------------------------------------------------------
# Passwords
# ------------------------------------------------------------

log ""
log "============================================================"
log "Creating new schema: $SCHEMA_NAME"
log "============================================================"
log ""

log "Waiting for passwords..."

if ! read -r -s -p "Password for ${ADMIN_USER}: " ADMIN_PASSWORD </dev/tty; then
    echo
    log "ERROR: failed to read password for ${ADMIN_USER}."
    log "Make sure the container is started with stdin_open=true and tty=true."
    exit 1
fi

echo

if [ -z "$ADMIN_PASSWORD" ]; then
    log "ERROR: password for ${ADMIN_USER} cannot be empty."
    exit 1
fi

log "Password for ${ADMIN_USER} received."

if ! read -r -s -p "Password for ${APP_USER}: " APP_PASSWORD </dev/tty; then
    echo
    log "ERROR: failed to read password for ${APP_USER}."
    exit 1
fi

echo

if [ -z "$APP_PASSWORD" ]; then
    log "ERROR: password for ${APP_USER} cannot be empty."
    exit 1
fi

log "Password for ${APP_USER} received."

log "Passwords received. Password values are hidden."

# ------------------------------------------------------------
# Create database objects
# ------------------------------------------------------------

log "Starting PostgreSQL transaction..."

PGPASSWORD="$POSTGRES_ADMIN_PASSWORD" \
psql \
    -h "$POSTGRES_HOST" \
    -p "$POSTGRES_PORT" \
    -U "$POSTGRES_ADMIN_USER" \
    -d "$POSTGRES_DB" \
    -v ON_ERROR_STOP=1 \
    -v schema_name="$SCHEMA_NAME" \
    -v maintenance_role="$MAINTENANCE_ROLE" \
    -v read_write_role="$READ_WRITE_ROLE" \
    -v admin_user="$ADMIN_USER" \
    -v app_user="$APP_USER" \
    -v admin_password="$ADMIN_PASSWORD" \
    -v app_password="$APP_PASSWORD" \
    <<'SQL'

BEGIN;

\echo '[SQL] Creating maintenance role...'

CREATE ROLE :"maintenance_role" NOLOGIN;

\echo '[SQL] Creating read/write role...'

CREATE ROLE :"read_write_role" NOLOGIN;

\echo '[SQL] Creating admin user...'

CREATE ROLE :"admin_user"
    LOGIN
    PASSWORD :'admin_password';

\echo '[SQL] Creating application user...'

CREATE ROLE :"app_user"
    LOGIN
    PASSWORD :'app_password';

\echo '[SQL] Granting maintenance role to admin...'

GRANT :"maintenance_role"
TO :"admin_user";

\echo '[SQL] Granting read/write role to application user...'

GRANT :"read_write_role"
TO :"app_user";

\echo '[SQL] Creating schema...'

CREATE SCHEMA :"schema_name"
    AUTHORIZATION :"admin_user";

\echo '[SQL] Granting maintenance schema privileges...'

GRANT USAGE, CREATE
ON SCHEMA :"schema_name"
TO :"maintenance_role";

GRANT ALL PRIVILEGES
ON ALL TABLES IN SCHEMA :"schema_name"
TO :"maintenance_role";

GRANT ALL PRIVILEGES
ON ALL SEQUENCES IN SCHEMA :"schema_name"
TO :"maintenance_role";

GRANT ALL PRIVILEGES
ON ALL FUNCTIONS IN SCHEMA :"schema_name"
TO :"maintenance_role";

\echo '[SQL] Granting application schema privileges...'

GRANT USAGE
ON SCHEMA :"schema_name"
TO :"read_write_role";

GRANT SELECT, INSERT, UPDATE, DELETE
ON ALL TABLES IN SCHEMA :"schema_name"
TO :"read_write_role";

GRANT USAGE, SELECT, UPDATE
ON ALL SEQUENCES IN SCHEMA :"schema_name"
TO :"read_write_role";

\echo '[SQL] Configuring default table privileges...'

ALTER DEFAULT PRIVILEGES
FOR ROLE :"admin_user"
IN SCHEMA :"schema_name"
GRANT SELECT, INSERT, UPDATE, DELETE
ON TABLES
TO :"read_write_role";

\echo '[SQL] Configuring default sequence privileges...'

ALTER DEFAULT PRIVILEGES
FOR ROLE :"admin_user"
IN SCHEMA :"schema_name"
GRANT USAGE, SELECT, UPDATE
ON SEQUENCES
TO :"read_write_role";

\echo '[SQL] Configuring maintenance default table privileges...'

ALTER DEFAULT PRIVILEGES
FOR ROLE :"admin_user"
IN SCHEMA :"schema_name"
GRANT ALL PRIVILEGES
ON TABLES
TO :"maintenance_role";

\echo '[SQL] Configuring maintenance default sequence privileges...'

ALTER DEFAULT PRIVILEGES
FOR ROLE :"admin_user"
IN SCHEMA :"schema_name"
GRANT ALL PRIVILEGES
ON SEQUENCES
TO :"maintenance_role";

\echo '[SQL] Configuring maintenance default function privileges...'

ALTER DEFAULT PRIVILEGES
FOR ROLE :"admin_user"
IN SCHEMA :"schema_name"
GRANT ALL PRIVILEGES
ON FUNCTIONS
TO :"maintenance_role";

COMMIT;

\echo '[SQL] Transaction committed successfully.'

SQL

log "PostgreSQL transaction completed successfully."

# ------------------------------------------------------------
# Verify result
# ------------------------------------------------------------

log "Verifying created objects..."

PGPASSWORD="$POSTGRES_ADMIN_PASSWORD" \
psql \
    -h "$POSTGRES_HOST" \
    -p "$POSTGRES_PORT" \
    -U "$POSTGRES_ADMIN_USER" \
    -d "$POSTGRES_DB" \
    -v ON_ERROR_STOP=1 \
    -v schema_name="$SCHEMA_NAME" \
    -v admin_user="$ADMIN_USER" \
    -v app_user="$APP_USER" \
    -c "
SELECT
    n.nspname AS schema,
    r.rolname AS schema_owner
FROM pg_namespace n
JOIN pg_roles r
    ON r.oid = n.nspowner
WHERE n.nspname = :'schema_name';

SELECT
    rolname,
    rolcanlogin
FROM pg_roles
WHERE rolname IN (:'admin_user', :'app_user');
"

log "Verification completed."

unset ADMIN_PASSWORD
unset APP_PASSWORD

log "============================================================"
log "Schema '$SCHEMA_NAME' created successfully."
log "============================================================"

log "Schema:"
log "  $SCHEMA_NAME"

log "Administration:"
log "  User:  $ADMIN_USER"
log "  Group: $MAINTENANCE_ROLE"

log "Application:"
log "  User:  $APP_USER"
log "  Group: $READ_WRITE_ROLE"

log "Bootstrap finished."