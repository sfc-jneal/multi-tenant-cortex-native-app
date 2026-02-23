#!/bin/bash
# ============================================================================
# Toggle between local config (your account) and public config (placeholders)
# ============================================================================
# Usage:
#   ./configure.sh local   - Apply your account values from .local/config.env
#   ./configure.sh public  - Apply placeholder values for public repo
#   ./configure.sh status  - Show current config state
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$PROJECT_ROOT/.local/config.env"

# Placeholder values for public repo
PUBLIC_PROVIDER_ACCOUNT="YOUR_ORG-YOUR_ACCOUNT"
PUBLIC_PROVIDER_CONNECTION="your_provider_connection"
PUBLIC_CONSUMER_CONNECTION="your_consumer_connection"
PUBLIC_CONSUMER_ACCOUNT="YOUR_CONSUMER_ACCOUNT"

# Files that need config updates
CHAT_PY="$PROJECT_ROOT/consumer/native-app/app-package/python/chat.py"
DEPLOY_SH="$PROJECT_ROOT/consumer/native-app/scripts/deploy.sh"
DEPLOY_SQL="$PROJECT_ROOT/consumer/native-app/scripts/deploy.sql"
REGISTRATION_SQL="$PROJECT_ROOT/provider/sql/06_self_service_registration.sql"

show_status() {
    echo "Current configuration:"
    echo "======================"
    
    if grep -q "YOUR_ORG-YOUR_ACCOUNT" "$CHAT_PY" 2>/dev/null; then
        echo "  chat.py:              PUBLIC (placeholder)"
    else
        local current=$(grep "PROVIDER_ACCOUNT = " "$CHAT_PY" | head -1)
        echo "  chat.py:              LOCAL ($current)"
    fi
    
    if grep -q "your_provider_connection" "$DEPLOY_SH" 2>/dev/null; then
        echo "  deploy.sh:            PUBLIC (placeholder)"
    else
        local current=$(grep "PROVIDER_CONNECTION=" "$DEPLOY_SH" | head -1)
        echo "  deploy.sh:            LOCAL ($current)"
    fi
}

apply_local() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "Error: $CONFIG_FILE not found"
        echo "Create it with your account values first."
        exit 1
    fi
    
    source "$CONFIG_FILE"
    
    echo "Applying LOCAL config..."
    
    # chat.py
    sed -i '' "s/PROVIDER_ACCOUNT = \".*\"/PROVIDER_ACCOUNT = \"$PROVIDER_ACCOUNT\"/" "$CHAT_PY"
    
    # deploy.sh
    sed -i '' "s/PROVIDER_CONNECTION=\".*\"/PROVIDER_CONNECTION=\"$PROVIDER_CONNECTION\"/" "$DEPLOY_SH"
    sed -i '' "s/CONSUMER_CONNECTION=\".*\"/CONSUMER_CONNECTION=\"$CONSUMER_CONNECTION\"/" "$DEPLOY_SH"
    
    # deploy.sql
    sed -i '' "s/TO ACCOUNT .*/TO ACCOUNT $CONSUMER_ACCOUNT;/" "$DEPLOY_SQL"
    
    # 06_self_service_registration.sql
    sed -i '' "s/'YOUR_ORG-YOUR_ACCOUNT'/'$PROVIDER_ACCOUNT'/" "$REGISTRATION_SQL"
    sed -i '' "s/'[A-Z_-]*' AS provider_account/'$PROVIDER_ACCOUNT' AS provider_account/" "$REGISTRATION_SQL" 2>/dev/null || true
    
    echo "Done! Local config applied."
    show_status
}

apply_public() {
    echo "Applying PUBLIC config (placeholders)..."
    
    # chat.py
    sed -i '' "s/PROVIDER_ACCOUNT = \".*\"/PROVIDER_ACCOUNT = \"$PUBLIC_PROVIDER_ACCOUNT\"/" "$CHAT_PY"
    
    # deploy.sh  
    sed -i '' "s/PROVIDER_CONNECTION=\".*\"/PROVIDER_CONNECTION=\"$PUBLIC_PROVIDER_CONNECTION\"/" "$DEPLOY_SH"
    sed -i '' "s/CONSUMER_CONNECTION=\".*\"/CONSUMER_CONNECTION=\"$PUBLIC_CONSUMER_CONNECTION\"/" "$DEPLOY_SH"
    
    # deploy.sql
    sed -i '' "s/TO ACCOUNT .*/TO ACCOUNT $PUBLIC_CONSUMER_ACCOUNT;/" "$DEPLOY_SQL"
    
    # 06_self_service_registration.sql  
    sed -i '' "s/'[A-Z_-]*' AS provider_account/'$PUBLIC_PROVIDER_ACCOUNT' AS provider_account/" "$REGISTRATION_SQL"
    
    echo "Done! Public config applied (safe to commit)."
    show_status
}

case "${1:-status}" in
    local)
        apply_local
        ;;
    public)
        apply_public
        ;;
    status)
        show_status
        ;;
    *)
        echo "Usage: $0 {local|public|status}"
        exit 1
        ;;
esac
