#!/bin/bash

set -Eeuo pipefail

# ============================================================
# Configuration
# ============================================================

POSTGRES_HOST="${POSTGRES_HOST:-tf-postgres}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_DB="${POSTGRES_DB:-tf}"
POSTGRES_ADMIN_USER="${POSTGRES_ADMIN_USER:-postgres}"
POSTGRES_ADMIN_PASSWORD="${POSTGRES_ADMIN_PASSWORD:-}"

# ============================================================
# Logging
# ============================================================

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

# ============================================================
# Arguments
# ============================================================

if [ "$#" -ne 1 ]; then
    echo "[BOOTSTRAP] ERROR: expected exactly one argument."
    echo "[BOOTSTRAP] Usage: $0 <schema_name>"
    exit 1
fi

SCHEMA_NAME="$1"

# ============================================================
# Start
# ============================================================

log "============================================================"
log "Starting schema bootstrap"
log "============================================================"

log "Schema:          $SCHEMA_NAME"
log "PostgreSQL host: $POSTGRES_HOST"
log "PostgreSQL port: $POSTGRES_PORT"
log "Database:        $POSTGRES_DB"
log "Admin user:      $POSTGRES_ADMIN_USER"
log "Admin password:  <hidden>"

# ============================================================
# Validate configuration
# ============================================================

log "Validating configuration..."

if [ -z "$POSTGRES_ADMIN_PASSWORD" ]; then
    log "ERROR: POSTGRES_ADMIN_PASSWORD is empty."
    exit 1
fi

if [[ ! "$SCHEMA_NAME" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
    log "ERROR: invalid schema name: $SCHEMA_NAME"
    log "Allowed characters: letters, numbers and underscore."
    exit 1
fi

log "Configuration is valid."

# ============================================================
# Build PostgreSQL object names
# ============================================================

MAINTENANCE_ROLE="${SCHEMA_NAME}_maintenance"
READ_WRITE_ROLE="${SCHEMA_NAME}_read_write"

ADMIN_USER="${SCHEMA_NAME}_admin"
APP_USER="${SCHEMA_NAME}_user"

log "PostgreSQL objects:"
log "  Schema:           $SCHEMA_NAME"
log "  Maintenance role: $MAINTENANCE_ROLE"
log "  Read/write role:  $READ_WRITE_ROLE"
log "  Admin user:       $ADMIN_USER"
log "  Application user: $APP_USER"

# ============================================================
# PostgreSQL connectivity
# ============================================================

log "Checking PostgreSQL connectivity..."

if ! pg_isready \
    -h "$POSTGRES_HOST" \
    -p "$POSTGRES_PORT" \
    -U "$POSTGRES_ADMIN_USER" \
    -d "$POSTGRES_DB" \
    >/dev/null 2>&1; then

    log "ERROR: PostgreSQL is not available."
    log "Host:     $POSTGRES_HOST"
    log "Port:     $POSTGRES_PORT"
    log "Database: $POSTGRES_DB"
    log "User:     $POSTGRES_ADMIN_USER"

    log "DNS resolution:"

    if getent hosts "$POSTGRES_HOST"; then
        log "DNS resolution successful."
    else
        log "ERROR: cannot resolve '$POSTGRES_HOST'."
    fi

    log "Trying TCP connection..."

    if command -v nc >/dev/null 2>&1; then
        nc -vz "$POSTGRES_HOST" "$POSTGRES_PORT" || true
    else
        log "nc is not installed. Skipping TCP check."
    fi

    exit 1
fi

log "PostgreSQL is reachable."

# ============================================================
# PostgreSQL authentication
# ============================================================

log "Testing PostgreSQL authentication..."

CONNECTION_TEST_FILE="/tmp/bootstrap_connection_test.log"

if ! PGPASSWORD="$POSTGRES_ADMIN_PASSWORD" \
    psql \
        -h "$POSTGRES_HOST" \
        -p "$POSTGRES_PORT" \
        -U "$POSTGRES_ADMIN_USER" \
        -d "$POSTGRES_DB" \
        -v ON_ERROR_STOP=1 \
        -c "SELECT current_database(), current_user;" \
        >"$CONNECTION_TEST_FILE" 2>&1; then

    log "ERROR: PostgreSQL authentication failed."

    log "psql output:"
    cat "$CONNECTION_TEST_FILE"

    rm -f "$CONNECTION_TEST_FILE"

    unset POSTGRES_ADMIN_PASSWORD

    exit 1
fi

log "PostgreSQL authentication successful."

log "Connection result:"
sed 's/^/[PSQL] /' "$CONNECTION_TEST_FILE"

rm -f "$CONNECTION_TEST_FILE"

# ============================================================
# Check schema existence
# ============================================================

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
    log "Existing schema will NOT be modified."
    log "Existing roles and permissions will NOT be modified."
    log "Skipping."

    unset POSTGRES_ADMIN_PASSWORD

    exit 0
fi

log "Schema '$SCHEMA_NAME' does not exist."
log "Proceeding with creation."

# ============================================================
# Initial passwords for new users
# ============================================================

log "============================================================"
log "Preparing passwords for new users"
log "============================================================"

# Initial passwords are intentionally equal to usernames.
#
# Example:
#
#   auth_admin -> password "auth_admin"
#   auth_user  -> password "auth_user"
#
# These passwords should be changed after initial deployment.

ADMIN_PASSWORD="$ADMIN_USER"
APP_PASSWORD="$APP_USER"

log "Initial password for '$ADMIN_USER' = username."
log "Initial password for '$APP_USER' = username."

# ============================================================
# Create PostgreSQL objects
# ============================================================

log "============================================================"
log "Creating new schema: $SCHEMA_NAME"
log "============================================================"

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

\echo ''
\echo '[SQL] Creating maintenance role...'

CREATE ROLE :"maintenance_role"
    NOLOGIN;

\echo '[SQL] Creating read/write role...'

CREATE ROLE :"read_write_role"
    NOLOGIN;

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

\echo '[SQL] Granting maintenance table privileges...'

GRANT ALL PRIVILEGES
ON ALL TABLES IN SCHEMA :"schema_name"
TO :"maintenance_role";

\echo '[SQL] Granting maintenance sequence privileges...'

GRANT ALL PRIVILEGES
ON ALL SEQUENCES IN SCHEMA :"schema_name"
TO :"maintenance_role";

\echo '[SQL] Granting maintenance function privileges...'

GRANT ALL PRIVILEGES
ON ALL FUNCTIONS IN SCHEMA :"schema_name"
TO :"maintenance_role";

\echo '[SQL] Granting application schema usage...'

GRANT USAGE
ON SCHEMA :"schema_name"
TO :"read_write_role";

\echo '[SQL] Granting application table privileges...'

GRANT SELECT, INSERT, UPDATE, DELETE
ON ALL TABLES IN SCHEMA :"schema_name"
TO :"read_write_role";

\echo '[SQL] Granting application sequence privileges...'

GRANT USAGE, SELECT, UPDATE
ON ALL SEQUENCES IN SCHEMA :"schema_name"
TO :"read_write_role";

\echo '[SQL] Configuring default table privileges for application...'

ALTER DEFAULT PRIVILEGES
FOR ROLE :"admin_user"
IN SCHEMA :"schema_name"
GRANT SELECT, INSERT, UPDATE, DELETE
ON TABLES
TO :"read_write_role";

\echo '[SQL] Configuring default sequence privileges for application...'

ALTER DEFAULT PRIVILEGES
FOR ROLE :"admin_user"
IN SCHEMA :"schema_name"
GRANT USAGE, SELECT, UPDATE
ON SEQUENCES
TO :"read_write_role";

\echo '[SQL] Configuring default table privileges for maintenance...'

ALTER DEFAULT PRIVILEGES
FOR ROLE :"admin_user"
IN SCHEMA :"schema_name"
GRANT ALL PRIVILEGES
ON TABLES
TO :"maintenance_role";

\echo '[SQL] Configuring default sequence privileges for maintenance...'

ALTER DEFAULT PRIVILEGES
FOR ROLE :"admin_user"
IN SCHEMA :"schema_name"
GRANT ALL PRIVILEGES
ON SEQUENCES
TO :"maintenance_role";

\echo '[SQL] Configuring default function privileges for maintenance...'

ALTER DEFAULT PRIVILEGES
FOR ROLE :"admin_user"
IN SCHEMA :"schema_name"
GRANT ALL PRIVILEGES
ON FUNCTIONS
TO :"maintenance_role";

\echo '[SQL] Committing transaction...'

COMMIT;

\echo '[SQL] Transaction committed successfully.'

SQL

log "PostgreSQL transaction completed successfully."

# ============================================================
# Verify result
# ============================================================

log "============================================================"
log "Verifying created objects"
log "============================================================"

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
    <<'SQL'

\echo '[VERIFY] Schema:'

SELECT
    n.nspname AS schema,
    r.rolname AS owner
FROM pg_namespace n
JOIN pg_roles r
    ON r.oid = n.nspowner
WHERE n.nspname = :'schema_name';

\echo '[VERIFY] Roles:'

SELECT
    rolname,
    rolcanlogin
FROM pg_roles
WHERE rolname IN (
    :'maintenance_role',
    :'read_write_role',
    :'admin_user',
    :'app_user'
)
ORDER BY rolname;

\echo '[VERIFY] Role memberships:'

SELECT
    member.rolname AS member,
    role.rolname AS granted_role
FROM pg_auth_members m
JOIN pg_roles role
    ON role.oid = m.roleid
JOIN pg_roles member
    ON member.oid = m.member
WHERE member.rolname IN (
    :'admin_user',
    :'app_user'
)
ORDER BY member.rolname, role.rolname;

SQL

log "Verification completed successfully."

# ============================================================
# Cleanup
# ============================================================

unset POSTGRES_ADMIN_PASSWORD
unset ADMIN_PASSWORD
unset APP_PASSWORD

# ============================================================
# Done
# ============================================================

log "============================================================"
log "Schema '$SCHEMA_NAME' created successfully."
log "============================================================"

log "Created objects:"
log "  Schema:           $SCHEMA_NAME"
log "  Admin user:       $ADMIN_USER"
log "  Maintenance role: $MAINTENANCE_ROLE"
log "  App user:         $APP_USER"
log "  Read/write role:  $READ_WRITE_ROLE"

log "Initial passwords are equal to usernames."
log "CHANGE THEM after initial deployment."

log "Bootstrap finished successfully."