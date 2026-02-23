#!/bin/bash
# ============================================================================
# setup_provider.sh - Run all provider SQL scripts in order
# ============================================================================
# Usage: ./scripts/setup_provider.sh
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SQL_DIR="$SCRIPT_DIR/../provider/sql"

echo "=============================================="
echo "Multi-Tenant Cortex Agent - Provider Setup"
echo "(Self-Service Key-Pair Architecture)"
echo "=============================================="
echo ""

if ! command -v snow &> /dev/null; then
    echo "Error: 'snow' CLI not found. Install with: pip install snowflake-cli-labs"
    exit 1
fi

SCRIPTS=(
    "01_infrastructure.sql"
    "02_data_model.sql"
    "03_row_access_policy.sql"
    "04_semantic_view.sql"
    "05_agent.sql"
    "06_self_service_registration.sql"
    "07_tenant_onboarding.sql"
    "08_seed_demo_data.sql"
)

for script in "${SCRIPTS[@]}"; do
    echo "Running: $script"
    snow sql -f "$SQL_DIR/$script"
    echo "Complete"
    echo ""
done

echo "=============================================="
echo "Provider setup complete!"
echo ""
echo "The REGISTRATION_PROCESSOR_TASK is now running."
echo "It will auto-provision tenants every 1 minute."
echo ""
echo "Next steps:"
echo "1. Deploy Native App: cd consumer/native-app && snow app run"
echo "2. Install app in consumer account"
echo "3. Register with your organization name"
echo "4. Wait 1-2 minutes - that's it!"
echo ""
echo "No manual tenant onboarding required!"
echo "=============================================="
