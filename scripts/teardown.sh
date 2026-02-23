#!/bin/bash
# ============================================================================
# teardown.sh - Complete cleanup of provider resources
# ============================================================================
# WARNING: This is destructive and cannot be undone!
#
# Usage: ./scripts/teardown.sh
# ============================================================================

set -e

echo "=============================================="
echo "Multi-Tenant Cortex Agent - TEARDOWN"
echo "=============================================="
echo ""
echo "WARNING: This will delete ALL resources including:"
echo "  - Database MT_AGENT_DEMO"
echo "  - All tenant service users"
echo "  - All data"
echo ""
read -p "Are you sure? Type 'yes' to confirm: " confirm

if [ "$confirm" != "yes" ]; then
    echo "Aborted."
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SQL_DIR="$SCRIPT_DIR/../provider/sql"

echo ""
echo "Running teardown..."
snow sql -f "$SQL_DIR/teardown.sql"

echo ""
echo "=============================================="
echo "Teardown complete."
echo "=============================================="
