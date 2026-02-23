#!/bin/bash
# ============================================================================
# Native App Deployment Script for mt-agent-service-users
# ============================================================================
# Usage:
#   ./deploy.sh upload     - Upload files to stage only
#   ./deploy.sh version    - Create new version V1_0 (first time)
#   ./deploy.sh patch      - Add patch to existing version
#   ./deploy.sh install    - Install app in consumer account
#   ./deploy.sh all        - Full deployment (upload + version + install)
# ============================================================================

set -e

# Configuration
APP_PACKAGE="MT_AGENT_SVC_USER_APP_PKG"
STAGE_PATH="@${APP_PACKAGE}.STAGE.APP_FILES"
PROVIDER_CONNECTION="your_provider_connection"
CONSUMER_CONNECTION="your_consumer_connection"
APP_NAME="MT_AGENT_SVC_USER_APP"
VERSION="V1_0"

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_PACKAGE_DIR="$SCRIPT_DIR/../app-package"

ACTION="${1:-upload}"

echo "============================================"
echo "MT Agent Service User App Deployment"
echo "============================================"
echo "Action:   $ACTION"
echo "Package:  $APP_PACKAGE"
echo "Version:  $VERSION"
echo "============================================"
echo ""

upload_files() {
    echo "Uploading files to stage..."
    echo "----------------------------------------"
    
    # Upload manifest
    snow stage copy "$APP_PACKAGE_DIR/manifest.yml" "$STAGE_PATH/" \
        --overwrite -c $PROVIDER_CONNECTION > /dev/null
    echo "  [OK] manifest.yml"
    
    # Upload setup.sql
    snow stage copy "$APP_PACKAGE_DIR/setup.sql" "$STAGE_PATH/" \
        --overwrite -c $PROVIDER_CONNECTION > /dev/null
    echo "  [OK] setup.sql"
    
    # Upload streamlit
    snow stage copy "$APP_PACKAGE_DIR/streamlit/chatbot.py" "$STAGE_PATH/streamlit/" \
        --overwrite -c $PROVIDER_CONNECTION > /dev/null
    echo "  [OK] streamlit/chatbot.py"
    
    # Upload python files
    snow stage copy "$APP_PACKAGE_DIR/python/chat.py" "$STAGE_PATH/python/" \
        --overwrite -c $PROVIDER_CONNECTION > /dev/null
    echo "  [OK] python/chat.py"
    
    snow stage copy "$APP_PACKAGE_DIR/python/auth.py" "$STAGE_PATH/python/" \
        --overwrite -c $PROVIDER_CONNECTION > /dev/null
    echo "  [OK] python/auth.py"
    
    # Upload environment.yml if exists
    if [ -f "$APP_PACKAGE_DIR/environment.yml" ]; then
        snow stage copy "$APP_PACKAGE_DIR/environment.yml" "$STAGE_PATH/" \
            --overwrite -c $PROVIDER_CONNECTION > /dev/null
        echo "  [OK] environment.yml"
    fi
    
    echo ""
    echo "Verifying uploads..."
    snow sql -q "LIST $STAGE_PATH;" -c $PROVIDER_CONNECTION
    echo ""
}

create_version() {
    echo "Creating version $VERSION..."
    echo "----------------------------------------"
    
    # First ensure package exists
    snow sql -q "CREATE APPLICATION PACKAGE IF NOT EXISTS $APP_PACKAGE COMMENT = 'Multi-tenant Cortex Agent';" \
        -c $PROVIDER_CONNECTION
    
    # Create schema and stage if needed
    snow sql -q "CREATE SCHEMA IF NOT EXISTS $APP_PACKAGE.STAGE;" -c $PROVIDER_CONNECTION
    snow sql -q "CREATE STAGE IF NOT EXISTS $STAGE_PATH DIRECTORY = (ENABLE = TRUE);" \
        -c $PROVIDER_CONNECTION 2>/dev/null || true
    
    # Try to add version (will fail if exists)
    snow sql -q "ALTER APPLICATION PACKAGE $APP_PACKAGE ADD VERSION $VERSION USING '$STAGE_PATH';" \
        -c $PROVIDER_CONNECTION 2>&1 || echo "  (Version may already exist, trying patch...)"
    
    echo ""
}

add_patch() {
    echo "Adding patch to $VERSION..."
    echo "----------------------------------------"
    
    RESULT=$(snow sql -q "ALTER APPLICATION PACKAGE $APP_PACKAGE ADD PATCH FOR VERSION $VERSION USING '$STAGE_PATH';" \
        -c $PROVIDER_CONNECTION 2>&1)
    echo "$RESULT"
    
    # Extract patch number
    PATCH=$(echo "$RESULT" | sed -n 's/.*Patch \([0-9]*\) added.*/\1/p')
    if [ -n "$PATCH" ]; then
        echo ""
        echo "Setting release directive to $VERSION patch $PATCH..."
        snow sql -q "ALTER APPLICATION PACKAGE $APP_PACKAGE SET DEFAULT RELEASE DIRECTIVE VERSION = $VERSION PATCH = $PATCH;" \
            -c $PROVIDER_CONNECTION
    fi
    
    echo ""
}

set_distribution() {
    echo "Setting distribution to EXTERNAL..."
    echo "----------------------------------------"
    
    snow sql -q "ALTER APPLICATION PACKAGE $APP_PACKAGE SET DISTRIBUTION = EXTERNAL;" \
        -c $PROVIDER_CONNECTION
    
    # TODO: Replace YOUR_CONSUMER_ACCOUNT with actual account locator
    snow sql -q "GRANT INSTALL ON APPLICATION PACKAGE $APP_PACKAGE TO ACCOUNT YOUR_CONSUMER_ACCOUNT;" \
        -c $PROVIDER_CONNECTION
    
    echo ""
}

install_consumer() {
    echo "Installing in consumer account..."
    echo "----------------------------------------"
    
    # Drop existing app if present
    snow sql -q "DROP APPLICATION IF EXISTS $APP_NAME;" -c $CONSUMER_CONNECTION 2>/dev/null || true
    
    # Install from package
    snow sql -q "CREATE APPLICATION $APP_NAME FROM APPLICATION PACKAGE $APP_PACKAGE;" \
        -c $CONSUMER_CONNECTION
    
    echo ""
    echo "Verifying installation..."
    snow sql -q "SHOW APPLICATIONS LIKE '$APP_NAME';" -c $CONSUMER_CONNECTION
    echo ""
}

verify() {
    echo "Verification..."
    echo "----------------------------------------"
    
    echo "Package versions:"
    snow sql -q "SHOW VERSIONS IN APPLICATION PACKAGE $APP_PACKAGE;" -c $PROVIDER_CONNECTION
    
    echo ""
    echo "Consumer apps:"
    snow sql -q "SHOW APPLICATIONS LIKE '$APP_NAME';" -c $CONSUMER_CONNECTION 2>/dev/null || echo "  (Not installed yet)"
    echo ""
}

case $ACTION in
    upload)
        upload_files
        ;;
    version)
        create_version
        set_distribution
        ;;
    patch)
        add_patch
        ;;
    install)
        install_consumer
        ;;
    all)
        upload_files
        create_version
        add_patch
        set_distribution
        install_consumer
        verify
        ;;
    verify)
        verify
        ;;
    *)
        echo "Unknown action: $ACTION"
        echo "Usage: $0 {upload|version|patch|install|all|verify}"
        exit 1
        ;;
esac

echo "============================================"
echo "Done!"
echo "============================================"
