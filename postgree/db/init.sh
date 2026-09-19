#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BOOTSTRAP_SCRIPT="$SCRIPT_DIR/bootstrap.sh"
SCHEMAS_FILE="$SCRIPT_DIR/schemas.conf"

if [ ! -f "$SCHEMAS_FILE" ]; then
    echo "ERROR: schemas file not found: $SCHEMAS_FILE"
    exit 1
fi

if [ ! -x "$BOOTSTRAP_SCRIPT" ]; then
    echo "ERROR: bootstrap script is not executable: $BOOTSTRAP_SCRIPT"
    exit 1
fi

echo
echo "============================================================"
echo "TF PostgreSQL schema installer"
echo "============================================================"
echo

while IFS= read -r schema || [ -n "$schema" ]; do

    # Windows CRLF protection
    schema="${schema//$'\r'/}"

    # Trim spaces
    schema="$(echo "$schema" | xargs)"

    # Skip empty lines
    [ -z "$schema" ] && continue

    # Skip comments
    [[ "$schema" == \#* ]] && continue

    echo
    echo "------------------------------------------------------------"
    echo "Processing schema: $schema"
    echo "------------------------------------------------------------"

    "$BOOTSTRAP_SCRIPT" "$schema"

done < "$SCHEMAS_FILE"

echo
echo "============================================================"
echo "PostgreSQL schema installation completed."
echo "============================================================"
echo