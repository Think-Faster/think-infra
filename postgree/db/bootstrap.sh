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

# Пароли пользователей схемы — из Vault (secrets.conf), передаёт scripts/deploy.sh:
#   auth -> TF_PG_AUTH_ADMIN_PASSWORD, TF_PG_AUTH_USER_PASSWORD

ADMIN_PASSWORD_VAR="TF_PG_${SCHEMA_NAME^^}_ADMIN_PASSWORD"
APP_PASSWORD_VAR="TF_PG_${SCHEMA_NAME^^}_USER_PASSWORD"

ADMIN_PASSWORD="${!ADMIN_PASSWORD_VAR:-}"
APP_PASSWORD="${!APP_PASSWORD_VAR:-}"

if [ -z "$ADMIN_PASSWORD" ] || [ -z "$APP_PASSWORD" ]; then
    log "ERROR: $ADMIN_PASSWORD_VAR or $APP_PASSWORD_VAR is empty."
    log "Add them to secrets.conf and run scripts/secrets.sh init postgree."
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
# Apply schema, roles and permissions
# ============================================================
#
# Выполняется при КАЖДОМ запуске и приводит схему к эталону — идемпотентно:
#   - роли и пользователи создаются, если их нет; пароли — из Vault;
#   - search_path пользователей = своя схема (миграции и запросы без явной схемы);
#   - все объекты схемы принадлежат <schema>_admin (если кто-то создал таблицу
#     под другой ролью — например tf или через SET ROLE — владелец исправляется);
#   - права на все существующие объекты выдаются заново;
#   - права по умолчанию на будущие объекты <schema>_admin.
#
# Миграции должны выполняться под <schema>_admin. Приложение работает под <schema>_user
# и не может менять структуру (CREATE/ALTER/DROP).
# ============================================================

log "============================================================"
log "Applying schema: $SCHEMA_NAME"
log "============================================================"

PGPASSWORD="$POSTGRES_ADMIN_PASSWORD" \
psql \
    -h "$POSTGRES_HOST" \
    -p "$POSTGRES_PORT" \
    -U "$POSTGRES_ADMIN_USER" \
    -d "$POSTGRES_DB" \
    -q \
    -v ON_ERROR_STOP=1 \
    -v db_name="$POSTGRES_DB" \
    -v schema_name="$SCHEMA_NAME" \
    -v maintenance_role="$MAINTENANCE_ROLE" \
    -v read_write_role="$READ_WRITE_ROLE" \
    -v admin_user="$ADMIN_USER" \
    -v app_user="$APP_USER" \
    -v admin_password="$ADMIN_PASSWORD" \
    -v app_password="$APP_PASSWORD" \
    <<'SQL'

BEGIN;

-- Без NOTICE "already exists" / "already been granted" при повторных запусках.
SET LOCAL client_min_messages = warning;

\echo '[SQL] Roles and users...'

SELECT format('CREATE ROLE %I NOLOGIN', :'maintenance_role')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'maintenance_role') \gexec

SELECT format('CREATE ROLE %I NOLOGIN', :'read_write_role')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'read_write_role') \gexec

SELECT format('CREATE ROLE %I LOGIN', :'admin_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'admin_user') \gexec

SELECT format('CREATE ROLE %I LOGIN', :'app_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app_user') \gexec

ALTER ROLE :"admin_user" WITH LOGIN PASSWORD :'admin_password';
ALTER ROLE :"app_user"   WITH LOGIN PASSWORD :'app_password';

GRANT :"maintenance_role" TO :"admin_user";
GRANT :"read_write_role"  TO :"app_user";

\echo '[SQL] search_path...'

-- Без этого search_path = "$user", public: CREATE TABLE users под admin падает
-- (нет прав на public), а SELECT FROM users под приложением не находит таблицу.
ALTER ROLE :"admin_user" IN DATABASE :"db_name" SET search_path = :"schema_name";
ALTER ROLE :"app_user"   IN DATABASE :"db_name" SET search_path = :"schema_name";

\echo '[SQL] Schema...'

CREATE SCHEMA IF NOT EXISTS :"schema_name" AUTHORIZATION :"admin_user";
ALTER SCHEMA :"schema_name" OWNER TO :"admin_user";

REVOKE ALL ON SCHEMA :"schema_name" FROM PUBLIC;
GRANT USAGE, CREATE ON SCHEMA :"schema_name" TO :"maintenance_role";
GRANT USAGE         ON SCHEMA :"schema_name" TO :"read_write_role";

\echo '[SQL] Ownership of existing objects...'

-- Таблицы, представления, отдельные последовательности.
-- Последовательности serial/identity принадлежат таблице и меняют владельца вместе с ней.
SELECT format(
           'ALTER %s %I.%I OWNER TO %I',
           CASE c.relkind
               WHEN 'v' THEN 'VIEW'
               WHEN 'm' THEN 'MATERIALIZED VIEW'
               WHEN 'S' THEN 'SEQUENCE'
               WHEN 'f' THEN 'FOREIGN TABLE'
               ELSE 'TABLE'
           END,
           n.nspname, c.relname, :'admin_user')
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = :'schema_name'
  AND c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f')
  AND c.relowner <> :'admin_user'::regrole
  AND NOT (c.relkind = 'S' AND EXISTS (
          SELECT 1 FROM pg_depend d
          WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype IN ('a', 'i')))
  AND NOT EXISTS (
          SELECT 1 FROM pg_depend d
          WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'e')
\gexec

-- Функции и процедуры (объекты расширений не трогаем).
SELECT format('ALTER ROUTINE %I.%I(%s) OWNER TO %I',
              n.nspname, p.proname, pg_get_function_identity_arguments(p.oid), :'admin_user')
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = :'schema_name'
  AND p.prokind IN ('f', 'p')
  AND p.proowner <> :'admin_user'::regrole
  AND NOT EXISTS (
          SELECT 1 FROM pg_depend d
          WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')
\gexec

-- Типы: enum, domain, range. Типы строк таблиц и массивов меняются вместе с таблицей/типом.
SELECT format('ALTER %s %I.%I OWNER TO %I',
              CASE t.typtype WHEN 'd' THEN 'DOMAIN' ELSE 'TYPE' END,
              n.nspname, t.typname, :'admin_user')
FROM pg_type t
JOIN pg_namespace n ON n.oid = t.typnamespace
WHERE n.nspname = :'schema_name'
  AND t.typowner <> :'admin_user'::regrole
  AND t.typtype IN ('e', 'd', 'r')
  AND NOT EXISTS (
          SELECT 1 FROM pg_depend d
          WHERE d.classid = 'pg_type'::regclass AND d.objid = t.oid AND d.deptype = 'e')
\gexec

\echo '[SQL] Privileges on existing objects...'

GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA :"schema_name" TO :"maintenance_role";
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA :"schema_name" TO :"maintenance_role";
GRANT ALL PRIVILEGES ON ALL ROUTINES  IN SCHEMA :"schema_name" TO :"maintenance_role";

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA :"schema_name" TO :"read_write_role";
GRANT USAGE, SELECT, UPDATE          ON ALL SEQUENCES IN SCHEMA :"schema_name" TO :"read_write_role";
GRANT EXECUTE                        ON ALL ROUTINES  IN SCHEMA :"schema_name" TO :"read_write_role";

\echo '[SQL] Default privileges for future objects of admin...'

ALTER DEFAULT PRIVILEGES FOR ROLE :"admin_user" IN SCHEMA :"schema_name"
    GRANT ALL PRIVILEGES ON TABLES    TO :"maintenance_role";
ALTER DEFAULT PRIVILEGES FOR ROLE :"admin_user" IN SCHEMA :"schema_name"
    GRANT ALL PRIVILEGES ON SEQUENCES TO :"maintenance_role";
ALTER DEFAULT PRIVILEGES FOR ROLE :"admin_user" IN SCHEMA :"schema_name"
    GRANT ALL PRIVILEGES ON FUNCTIONS TO :"maintenance_role";

ALTER DEFAULT PRIVILEGES FOR ROLE :"admin_user" IN SCHEMA :"schema_name"
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"read_write_role";
ALTER DEFAULT PRIVILEGES FOR ROLE :"admin_user" IN SCHEMA :"schema_name"
    GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO :"read_write_role";
ALTER DEFAULT PRIVILEGES FOR ROLE :"admin_user" IN SCHEMA :"schema_name"
    GRANT EXECUTE ON FUNCTIONS TO :"read_write_role";

-- Объекты, созданные через SET ROLE <schema>_maintenance: приложение получает права сразу,
-- владелец исправится на <schema>_admin при следующей выкатке.
ALTER DEFAULT PRIVILEGES FOR ROLE :"maintenance_role" IN SCHEMA :"schema_name"
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"read_write_role";
ALTER DEFAULT PRIVILEGES FOR ROLE :"maintenance_role" IN SCHEMA :"schema_name"
    GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO :"read_write_role";
ALTER DEFAULT PRIVILEGES FOR ROLE :"maintenance_role" IN SCHEMA :"schema_name"
    GRANT EXECUTE ON FUNCTIONS TO :"read_write_role";

\echo '[SQL] Committing transaction...'

COMMIT;

SQL

log "Schema, roles and permissions applied."

# ============================================================
# Verify result
# ============================================================

log "============================================================"
log "Verifying"
log "============================================================"

VERIFY_FILE="/tmp/bootstrap_verify.log"

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
    <<'SQL'

\echo '[VERIFY] Schema:'

SELECT n.nspname AS schema, r.rolname AS owner
FROM pg_namespace n
JOIN pg_roles r ON r.oid = n.nspowner
WHERE n.nspname = :'schema_name';

\echo '[VERIFY] Users (search_path):'

SELECT r.rolname, r.rolcanlogin, s.setconfig AS settings
FROM pg_roles r
LEFT JOIN pg_db_role_setting s
    ON s.setrole = r.oid AND s.setdatabase = (SELECT oid FROM pg_database WHERE datname = current_database())
WHERE r.rolname IN (:'admin_user', :'app_user')
ORDER BY r.rolname;

\echo '[VERIFY] Objects in schema:'

SELECT c.relname AS object, c.relkind AS kind, pg_get_userbyid(c.relowner) AS owner
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = :'schema_name' AND c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f')
ORDER BY c.relname;

SQL

# Объекты, к которым у приложения нет прав. Должно быть пусто.
PGPASSWORD="$POSTGRES_ADMIN_PASSWORD" \
psql \
    -h "$POSTGRES_HOST" \
    -p "$POSTGRES_PORT" \
    -U "$POSTGRES_ADMIN_USER" \
    -d "$POSTGRES_DB" \
    -v ON_ERROR_STOP=1 \
    -tA \
    -v schema_name="$SCHEMA_NAME" \
    -v admin_user="$ADMIN_USER" \
    -v app_user="$APP_USER" \
    >"$VERIFY_FILE" \
    <<'SQL'
SELECT c.relname || ' (owner ' || pg_get_userbyid(c.relowner) || ')'
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = :'schema_name'
  AND (
        -- has_*_privilege со списком прав истинна, если есть ХОТЯ БЫ одно, поэтому по одному.
        (c.relkind IN ('r', 'p', 'f')
         AND NOT (    has_table_privilege(:'app_user', c.oid, 'SELECT')
                  AND has_table_privilege(:'app_user', c.oid, 'INSERT')
                  AND has_table_privilege(:'app_user', c.oid, 'UPDATE')
                  AND has_table_privilege(:'app_user', c.oid, 'DELETE')))
     OR (c.relkind IN ('v', 'm')
         AND NOT has_table_privilege(:'app_user', c.oid, 'SELECT'))
     OR (c.relkind = 'S'
         AND NOT (    has_sequence_privilege(:'app_user', c.oid, 'USAGE')
                  AND has_sequence_privilege(:'app_user', c.oid, 'SELECT')
                  AND has_sequence_privilege(:'app_user', c.oid, 'UPDATE')))
     OR c.relowner <> :'admin_user'::regrole
  );
SQL

if [ -s "$VERIFY_FILE" ]; then
    log "ERROR: objects with wrong owner or without privileges for '$APP_USER':"
    sed 's/^/[VERIFY]   /' "$VERIFY_FILE"
    rm -f "$VERIFY_FILE"
    exit 1
fi

rm -f "$VERIFY_FILE"

log "All objects are owned by '$ADMIN_USER' and accessible to '$APP_USER'."

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
log "Schema '$SCHEMA_NAME' is ready."
log "============================================================"

log "  Schema:           $SCHEMA_NAME (owner $ADMIN_USER)"
log "  Migrations:       $ADMIN_USER (search_path = $SCHEMA_NAME)"
log "  Application:      $APP_USER (search_path = $SCHEMA_NAME, read/write data only)"
log "  Passwords:        Vault, secret/tf/postgres/$SCHEMA_NAME"

log "Bootstrap finished successfully."
