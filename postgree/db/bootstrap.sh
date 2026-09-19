#!/bin/bash

set -euo pipefail

# ============================================================
# PostgreSQL configuration
# ============================================================

POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-tf-postgres}"
POSTGRES_DB="${POSTGRES_DB:-tf}"
POSTGRES_ADMIN_USER="${POSTGRES_ADMIN_USER:-postgres}"

# ============================================================
# Arguments
# ============================================================

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <schema_name>"
    exit 1
fi

SCHEMA_NAME="$1"

# ============================================================
# Validate schema name
# ============================================================

if [[ ! "$SCHEMA_NAME" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
    echo "ERROR: invalid schema name: $SCHEMA_NAME"
    echo "Allowed characters: letters, numbers and underscore."
    exit 1
fi

# ============================================================
# Role names
# ============================================================

MAINTENANCE_ROLE="${SCHEMA_NAME}_maintenance"
READ_WRITE_ROLE="${SCHEMA_NAME}_read_write"

ADMIN_USER="${SCHEMA_NAME}_admin"
APP_USER="${SCHEMA_NAME}_user"

# ============================================================
# Check PostgreSQL
# ============================================================

echo "Checking PostgreSQL..."

if ! docker exec \
    "$POSTGRES_CONTAINER" \
    pg_isready \
    -U "$POSTGRES_ADMIN_USER" \
    -d "$POSTGRES_DB" \
    >/dev/null 2>&1; then

    echo "ERROR: PostgreSQL is not available."
    echo "Container: $POSTGRES_CONTAINER"
    exit 1
fi

# ============================================================
# Check schema
# ============================================================

SCHEMA_EXISTS=$(
    docker exec \
        "$POSTGRES_CONTAINER" \
        psql \
        -U "$POSTGRES_ADMIN_USER" \
        -d "$POSTGRES_DB" \
        -tAc \
        "SELECT 1 FROM pg_namespace WHERE nspname = '$SCHEMA_NAME';"
)

if [ "$SCHEMA_EXISTS" = "1" ]; then
    echo "Schema '$SCHEMA_NAME' already exists. Skipping."
    exit 0
fi

# ============================================================
# Passwords
# ============================================================

echo
echo "============================================================"
echo "Creating new schema: $SCHEMA_NAME"
echo "============================================================"
echo

read -r -s -p "Password for ${ADMIN_USER}: " ADMIN_PASSWORD
echo

if [ -z "$ADMIN_PASSWORD" ]; then
    echo "ERROR: password for ${ADMIN_USER} cannot be empty."
    exit 1
fi

read -r -s -p "Password for ${APP_USER}: " APP_PASSWORD
echo

if [ -z "$APP_PASSWORD" ]; then
    echo "ERROR: password for ${APP_USER} cannot be empty."
    exit 1
fi

echo
echo "Creating schema and roles..."

# ============================================================
# Create everything
# ============================================================

docker exec -i \
    -e TF_ADMIN_PASSWORD="$ADMIN_PASSWORD" \
    -e TF_APP_PASSWORD="$APP_PASSWORD" \
    "$POSTGRES_CONTAINER" \
    psql \
    -U "$POSTGRES_ADMIN_USER" \
    -d "$POSTGRES_DB" \
    -v ON_ERROR_STOP=1 \
    -v schema_name="$SCHEMA_NAME" \
    -v maintenance_role="$MAINTENANCE_ROLE" \
    -v read_write_role="$READ_WRITE_ROLE" \
    -v admin_user="$ADMIN_USER" \
    -v app_user="$APP_USER" \
    <<'SQL'

BEGIN;

-- ==========================================================
-- Groups
-- ==========================================================

CREATE ROLE :"maintenance_role" NOLOGIN;

CREATE ROLE :"read_write_role" NOLOGIN;


-- ==========================================================
-- Users
-- ==========================================================

CREATE ROLE :"admin_user"
    LOGIN
    PASSWORD :'TF_ADMIN_PASSWORD';

CREATE ROLE :"app_user"
    LOGIN
    PASSWORD :'TF_APP_PASSWORD';


-- ==========================================================
-- Group membership
-- ==========================================================

GRANT :"maintenance_role"
TO :"admin_user";

GRANT :"read_write_role"
TO :"app_user";


-- ==========================================================
-- Schema
-- ==========================================================

CREATE SCHEMA :"schema_name"
    AUTHORIZATION :"admin_user";


-- ==========================================================
-- MAINTENANCE
--
-- Used by database migrations.
--
-- Allows:
--   CREATE TABLE
--   ALTER TABLE
--   DROP TABLE
--   CREATE INDEX
--   CREATE SEQUENCE
--   CREATE FUNCTION
--   etc.
-- ==========================================================

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


-- ==========================================================
-- READ / WRITE
--
-- Used by application.
--
-- CRUD only.
-- ==========================================================

GRANT USAGE
ON SCHEMA :"schema_name"
TO :"read_write_role";

GRANT SELECT, INSERT, UPDATE, DELETE
ON ALL TABLES IN SCHEMA :"schema_name"
TO :"read_write_role";

GRANT USAGE, SELECT, UPDATE
ON ALL SEQUENCES IN SCHEMA :"schema_name"
TO :"read_write_role";


-- ==========================================================
-- DEFAULT PRIVILEGES
--
-- Permissions for future objects created by admin_user.
-- This is important for migrations.
-- ==========================================================

-- Future tables: application CRUD

ALTER DEFAULT PRIVILEGES
FOR ROLE :"admin_user"
IN SCHEMA :"schema_name"
GRANT SELECT, INSERT, UPDATE, DELETE
ON TABLES
TO :"read_write_role";


-- Future sequences: application CRUD

ALTER DEFAULT PRIVILEGES
FOR ROLE :"admin_user"
IN SCHEMA :"schema_name"
GRANT USAGE, SELECT, UPDATE
ON SEQUENCES
TO :"read_write_role";


-- Future tables: maintenance

ALTER DEFAULT PRIVILEGES
FOR ROLE :"admin_user"
IN SCHEMA :"schema_name"
GRANT ALL PRIVILEGES
ON TABLES
TO :"maintenance_role";


-- Future sequences: maintenance

ALTER DEFAULT PRIVILEGES
FOR ROLE :"admin_user"
IN SCHEMA :"schema_name"
GRANT ALL PRIVILEGES
ON SEQUENCES
TO :"maintenance_role";


-- Future functions: maintenance

ALTER DEFAULT PRIVILEGES
FOR ROLE :"admin_user"
IN SCHEMA :"schema_name"
GRANT ALL PRIVILEGES
ON FUNCTIONS
TO :"maintenance_role";

COMMIT;

SQL

# ============================================================
# Cleanup passwords from shell environment
# ============================================================

unset ADMIN_PASSWORD
unset APP_PASSWORD

# ============================================================
# Result
# ============================================================

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