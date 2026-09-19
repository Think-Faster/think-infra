#!/bin/bash

set -euo pipefail

POSTGRES_HOST="${POSTGRES_HOST:-tf-postgres}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_DB="${POSTGRES_DB:-tf}"
POSTGRES_ADMIN_USER="${POSTGRES_ADMIN_USER:-tf}"
POSTGRES_ADMIN_PASSWORD="${POSTGRES_ADMIN_PASSWORD:-}"

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <schema_name>"
    exit 1
fi

SCHEMA_NAME="$1"

if [[ ! "$SCHEMA_NAME" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
    echo "ERROR: invalid schema name: $SCHEMA_NAME"
    echo "Allowed characters: letters, numbers and underscore."
    exit 1
fi

if [ -z "$POSTGRES_ADMIN_PASSWORD" ]; then
    echo "ERROR: POSTGRES_ADMIN_PASSWORD is not set."
    exit 1
fi

MAINTENANCE_ROLE="${SCHEMA_NAME}_maintenance"
READ_WRITE_ROLE="${SCHEMA_NAME}_read_write"
ADMIN_USER="${SCHEMA_NAME}_admin"
APP_USER="${SCHEMA_NAME}_user"

export PGPASSWORD="$POSTGRES_ADMIN_PASSWORD"

echo "Checking PostgreSQL..."

if ! pg_isready \
    -h "$POSTGRES_HOST" \
    -p "$POSTGRES_PORT" \
    -U "$POSTGRES_ADMIN_USER" \
    -d "$POSTGRES_DB" \
    >/dev/null 2>&1; then

    echo "ERROR: PostgreSQL is not available."
    echo "Host: $POSTGRES_HOST"
    echo "Port: $POSTGRES_PORT"
    echo "Database: $POSTGRES_DB"
    exit 1
fi

SCHEMA_EXISTS=$(
    psql \
        -h "$POSTGRES_HOST" \
        -p "$POSTGRES_PORT" \
        -U "$POSTGRES_ADMIN_USER" \
        -d "$POSTGRES_DB" \
        -tAc \
        "SELECT 1 FROM pg_namespace WHERE nspname = '$SCHEMA_NAME';"
)

if [ "$SCHEMA_EXISTS" = "1" ]; then
    echo "Schema '$SCHEMA_NAME' already exists. Skipping."
    unset PGPASSWORD
    exit 0
fi

echo
echo "============================================================"
echo "Creating new schema: $SCHEMA_NAME"
echo "============================================================"
echo

read -r -s -p "Password for ${ADMIN_USER}: " ADMIN_PASSWORD
echo

if [ -z "$ADMIN_PASSWORD" ]; then
    echo "ERROR: password for ${ADMIN_USER} cannot be empty."
    unset PGPASSWORD
    exit 1
fi

read -r -s -p "Password for ${APP_USER}: " APP_PASSWORD
echo

if [ -z "$APP_PASSWORD" ]; then
    echo "ERROR: password for ${APP_USER} cannot be empty."
    unset PGPASSWORD
    exit 1
fi

echo
echo "Creating schema and roles..."

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

CREATE ROLE :"maintenance_role" NOLOGIN;

CREATE ROLE :"read_write_role" NOLOGIN;

CREATE ROLE :"admin_user"
    LOGIN
    PASSWORD :'admin_password';

CREATE ROLE :"app_user"
    LOGIN
    PASSWORD :'app_password';

GRANT :"maintenance_role"
TO :"admin_user";

GRANT :"read_write_role"
TO :"app_user";

CREATE SCHEMA :"schema_name"
    AUTHORIZATION :"admin_user";


-- ============================================================
-- MAINTENANCE
-- ============================================================

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


-- ============================================================
-- APPLICATION READ/WRITE
-- ============================================================

GRANT USAGE
ON SCHEMA :"schema_name"
TO :"read_write_role";

GRANT SELECT, INSERT, UPDATE, DELETE
ON ALL TABLES IN SCHEMA :"schema_name"
TO :"read_write_role";

GRANT USAGE, SELECT, UPDATE
ON ALL SEQUENCES IN SCHEMA :"schema_name"
TO :"read_write_role";


-- ============================================================
-- DEFAULT PRIVILEGES FOR FUTURE OBJECTS
-- ============================================================

ALTER DEFAULT PRIVILEGES
FOR ROLE :"admin_user"
IN SCHEMA :"schema_name"
GRANT SELECT, INSERT, UPDATE, DELETE
ON TABLES
TO :"read_write_role";

ALTER DEFAULT PRIVILEGES
FOR ROLE :"admin_user"
IN SCHEMA :"schema_name"
GRANT USAGE, SELECT, UPDATE
ON SEQUENCES
TO :"read_write_role";

ALTER DEFAULT PRIVILEGES
FOR ROLE :"admin_user"
IN SCHEMA :"schema_name"
GRANT ALL PRIVILEGES
ON TABLES
TO :"maintenance_role";

ALTER DEFAULT PRIVILEGES
FOR ROLE :"admin_user"
IN SCHEMA :"schema_name"
GRANT ALL PRIVILEGES
ON SEQUENCES
TO :"maintenance_role";

ALTER DEFAULT PRIVILEGES
FOR ROLE :"admin_user"
IN SCHEMA :"schema_name"
GRANT ALL PRIVILEGES
ON FUNCTIONS
TO :"maintenance_role";

COMMIT;

SQL

unset PGPASSWORD
unset ADMIN_PASSWORD
unset APP_PASSWORD

echo
echo "============================================================"
echo "Schema '$SCHEMA_NAME' created successfully."
echo "============================================================"
echo
echo "Schema:"
echo "  $SCHEMA_NAME"
echo
echo "Administration:"
echo "  User:  $ADMIN_USER"
echo "  Group: $MAINTENANCE_ROLE"
echo
echo "Application:"
echo "  User:  $APP_USER"
echo "  Group: $READ_WRITE_ROLE"
echo