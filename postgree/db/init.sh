#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BOOTSTRAP_SCRIPT="$SCRIPT_DIR/bootstrap.sh"
SCHEMAS_FILE="$SCRIPT_DIR/schemas.conf"

# ============================================================
# Check files
# ============================================================

if [ ! -f "$SCHEMAS_FILE" ]; then
    echo "ERROR: schemas file not found:"
    echo "  $SCHEMAS_FILE"
    exit 1
fi

if [ ! -x "$BOOTSTRAP_SCRIPT" ]; then
    echo "ERROR: bootstrap.sh is not executable:"
    echo "  $BOOTSTRAP_SCRIPT"
    echo
    echo "Run:"
    echo "  chmod +x $BOOTSTRAP_SCRIPT"
    exit 1
fi

# ============================================================
# Process schemas
# ============================================================

echo
echo "============================================================"
echo "TF PostgreSQL initialization"
echo "============================================================"
echo

while IFS= read -r schema || [ -n "$schema" ]; do

    # Remove leading/trailing whitespace
    schema="$(echo "$schema" | xargs)"

    # Skip empty lines
    if [ -z "$schema" ]; then
        continue
    fi

    # Skip comments
    if [[ "$schema" == \#* ]]; then
        continue
    fi

    echo
    echo "------------------------------------------------------------"
    echo "Processing schema: $schema"
    echo "------------------------------------------------------------"

    "$BOOTSTRAP_SCRIPT" "$schema"

done < "$SCHEMAS_FILE"

echo
echo "============================================================"
echo "PostgreSQL initialization completed."
echo "============================================================"