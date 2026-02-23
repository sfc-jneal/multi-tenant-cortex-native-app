-- ============================================================================
-- Native App Setup Script - Key-Pair Self-Service Authentication
-- ============================================================================
-- Calls Cortex Agent API directly using service user key-pair auth.
-- Pattern follows the working api-proxy-demo/native-app-client implementation.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Application Roles
-- ----------------------------------------------------------------------------
CREATE APPLICATION ROLE IF NOT EXISTS APP_PUBLIC;
CREATE APPLICATION ROLE IF NOT EXISTS APP_ADMIN;

-- ----------------------------------------------------------------------------
-- Schemas
-- ----------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS CORE;
GRANT USAGE ON SCHEMA CORE TO APPLICATION ROLE APP_PUBLIC;
GRANT USAGE ON SCHEMA CORE TO APPLICATION ROLE APP_ADMIN;

CREATE OR ALTER VERSIONED SCHEMA CONFIG;
GRANT USAGE ON SCHEMA CONFIG TO APPLICATION ROLE APP_PUBLIC;
GRANT USAGE ON SCHEMA CONFIG TO APPLICATION ROLE APP_ADMIN;

-- ----------------------------------------------------------------------------
-- Internal State Table
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS CONFIG.APP_STATE (
    key VARCHAR(100) PRIMARY KEY,
    value VARCHAR(2000),
    updated_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

GRANT SELECT ON TABLE CONFIG.APP_STATE TO APPLICATION ROLE APP_PUBLIC;
GRANT SELECT, INSERT, UPDATE ON TABLE CONFIG.APP_STATE TO APPLICATION ROLE APP_ADMIN;

-- ----------------------------------------------------------------------------
-- Key Storage Table (in CORE schema - non-versioned so data persists across upgrades)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS CORE.KEY_STORE (
    key_id INT PRIMARY KEY DEFAULT 1,
    private_key VARCHAR(4000),
    public_key VARCHAR(4000),
    service_user VARCHAR(100),
    created_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

GRANT SELECT, INSERT, UPDATE ON TABLE CORE.KEY_STORE TO APPLICATION ROLE APP_PUBLIC;
GRANT SELECT, INSERT, UPDATE ON TABLE CORE.KEY_STORE TO APPLICATION ROLE APP_ADMIN;

-- ----------------------------------------------------------------------------
-- EAI Configuration Callback - Returns network configuration for Snowsight
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE CONFIG.GET_EAI_CONFIGURATION(ref_name STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
    IF (UPPER(ref_name) = 'EXTERNAL_ACCESS') THEN
        RETURN '{
            "type": "CONFIGURATION", 
            "payload": {
                "host_ports": [
                    "*.snowflakecomputing.com:443"
                ],
                "allowed_secrets": "NONE"
            }
        }';
    END IF;
    RETURN '{"type": "ERROR", "payload": {"message": "Unknown reference: ' || ref_name || '"}}';
END;
$$;

GRANT USAGE ON PROCEDURE CONFIG.GET_EAI_CONFIGURATION(STRING) TO APPLICATION ROLE APP_ADMIN;

-- ----------------------------------------------------------------------------
-- EAI Register Callback - Called when consumer binds the EAI reference
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE CONFIG.REGISTER_EAI_CALLBACK(ref_name STRING, operation STRING, ref_or_alias STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
    CASE (operation)
        WHEN 'ADD' THEN
            SELECT SYSTEM$SET_REFERENCE(:ref_name, :ref_or_alias);
            -- Mark EAI as configured
            MERGE INTO CONFIG.APP_STATE t USING (SELECT 'EAI_CONFIGURED' AS key) s ON t.key = s.key
            WHEN MATCHED THEN UPDATE SET value = 'true', updated_at = CURRENT_TIMESTAMP()
            WHEN NOT MATCHED THEN INSERT (key, value) VALUES ('EAI_CONFIGURED', 'true');
            -- Create the EAI-enabled procedures
            CALL CONFIG.SETUP_EAI_FOR_FUNCTIONS();
        WHEN 'REMOVE' THEN
            SELECT SYSTEM$REMOVE_REFERENCE(:ref_name, :ref_or_alias);
            UPDATE CONFIG.APP_STATE SET value = 'false', updated_at = CURRENT_TIMESTAMP() WHERE key = 'EAI_CONFIGURED';
        WHEN 'CLEAR' THEN
            SELECT SYSTEM$REMOVE_ALL_REFERENCES(:ref_name);
            UPDATE CONFIG.APP_STATE SET value = 'false', updated_at = CURRENT_TIMESTAMP() WHERE key = 'EAI_CONFIGURED';
        ELSE
            RETURN 'Unknown operation: ' || operation;
    END CASE;
    RETURN 'Reference ' || ref_name || ' ' || operation || ' completed successfully';
END;
$$;

GRANT USAGE ON PROCEDURE CONFIG.REGISTER_EAI_CALLBACK(STRING, STRING, STRING) TO APPLICATION ROLE APP_ADMIN;

-- ----------------------------------------------------------------------------
-- Generic Reference Callback - For view and table references
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE CONFIG.REGISTER_REFERENCE(ref_name STRING, operation STRING, ref_or_alias STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
    CASE (operation)
        WHEN 'ADD' THEN
            SELECT SYSTEM$SET_REFERENCE(:ref_name, :ref_or_alias);
        WHEN 'REMOVE' THEN
            SELECT SYSTEM$REMOVE_REFERENCE(:ref_name);
        WHEN 'CLEAR' THEN
            SELECT SYSTEM$REMOVE_REFERENCE(:ref_name);
    END CASE;
    RETURN 'SUCCESS';
END;
$$;

GRANT USAGE ON PROCEDURE CONFIG.REGISTER_REFERENCE(STRING, STRING, STRING) TO APPLICATION ROLE APP_PUBLIC;

-- ----------------------------------------------------------------------------
-- Setup EAI-enabled Functions - Creates procedures with external access
-- Uses reference('external_access') to dynamically bind the EAI
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE CONFIG.SETUP_EAI_FOR_FUNCTIONS()
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
    -- Create CHAT_IMPL with EAI - calls Cortex API directly
    CREATE OR REPLACE PROCEDURE CONFIG.CHAT_IMPL(message VARCHAR)
    RETURNS VARIANT
    LANGUAGE PYTHON
    RUNTIME_VERSION = '3.11'
    IMPORTS = ('/python/chat.py')
    EXTERNAL_ACCESS_INTEGRATIONS = (reference('external_access'))
    PACKAGES = ('requests', 'pyjwt', 'cryptography', 'snowflake-snowpark-python')
    HANDLER = 'chat.chat';
    
    GRANT USAGE ON PROCEDURE CONFIG.CHAT_IMPL(VARCHAR) TO APPLICATION ROLE APP_PUBLIC;
    GRANT USAGE ON PROCEDURE CONFIG.CHAT_IMPL(VARCHAR) TO APPLICATION ROLE APP_ADMIN;
    
    RETURN 'EAI-enabled procedures created successfully';
END;
$$;

GRANT USAGE ON PROCEDURE CONFIG.SETUP_EAI_FOR_FUNCTIONS() TO APPLICATION ROLE APP_ADMIN;

-- ----------------------------------------------------------------------------
-- Initialize Keys - Generates RSA key pair
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE CONFIG.INITIALIZE_KEYS()
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('cryptography', 'snowflake-snowpark-python')
HANDLER = 'initialize_keys'
EXECUTE AS OWNER
AS
$$
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.backends import default_backend

def initialize_keys(session):
    existing = session.sql("SELECT private_key FROM CORE.KEY_STORE WHERE key_id = 1").collect()
    if existing and existing[0][0]:
        return {"status": "exists", "message": "Keys already initialized"}
    
    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048, backend=default_backend())
    
    private_key_pem = private_key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption()
    ).decode('utf-8')
    
    public_key_pem = private_key.public_key().public_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PublicFormat.SubjectPublicKeyInfo
    ).decode('utf-8')
    
    session.sql("DELETE FROM CORE.KEY_STORE WHERE key_id = 1").collect()
    session.sql("INSERT INTO CORE.KEY_STORE (key_id, private_key, public_key) VALUES (1, ?, ?)",
        params=[private_key_pem, public_key_pem]).collect()
    
    return {"status": "created", "message": "Key pair generated and stored", "public_key": public_key_pem}
$$;

GRANT USAGE ON PROCEDURE CONFIG.INITIALIZE_KEYS() TO APPLICATION ROLE APP_PUBLIC;

-- ----------------------------------------------------------------------------
-- Get Status - Check registration and setup status
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE CONFIG.GET_STATUS()
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_eai_configured BOOLEAN DEFAULT FALSE;
    v_keys_initialized BOOLEAN DEFAULT FALSE;
    v_service_user VARCHAR DEFAULT NULL;
    v_result VARIANT;
    v_refs VARCHAR;
BEGIN
    -- Check EAI status dynamically using SYSTEM$GET_ALL_REFERENCES
    -- This detects the actual platform binding state, not table state that can be wiped on upgrade
    BEGIN
        SELECT SYSTEM$GET_ALL_REFERENCES('external_access') INTO :v_refs;
        SELECT ARRAY_SIZE(PARSE_JSON(:v_refs)) > 0 INTO :v_eai_configured;
        
        -- If EAI is bound, ensure CHAT_IMPL procedure exists (may be missing after upgrade)
        IF (v_eai_configured) THEN
            CALL CONFIG.SETUP_EAI_FOR_FUNCTIONS();
        END IF;
    EXCEPTION
        WHEN OTHER THEN
            v_eai_configured := FALSE;
    END;
    
    -- Check keys status and service_user (now in CORE schema which persists across upgrades)
    BEGIN
        SELECT private_key IS NOT NULL, service_user 
        INTO :v_keys_initialized, :v_service_user
        FROM CORE.KEY_STORE
        WHERE key_id = 1;
    EXCEPTION
        WHEN OTHER THEN
            v_keys_initialized := FALSE;
            v_service_user := NULL;
    END;
    
    -- If we have EAI + keys + service_user, we're ready to chat (no status_view needed)
    IF (v_eai_configured AND v_keys_initialized AND v_service_user IS NOT NULL) THEN
        -- Try to get additional info from status_view if available, but don't require it
        BEGIN
            SELECT OBJECT_CONSTRUCT(
                'eai_configured', :v_eai_configured,
                'keys_initialized', :v_keys_initialized,
                'service_user', :v_service_user,
                'registration_status', registration_status,
                'tenant_id', tenant_id,
                'ready', TRUE
            ) INTO v_result
            FROM REFERENCE('status_view');
            RETURN v_result;
        EXCEPTION
            WHEN OTHER THEN
                -- status_view not bound, but we're still ready to chat
                RETURN OBJECT_CONSTRUCT(
                    'eai_configured', TRUE,
                    'keys_initialized', TRUE,
                    'service_user', :v_service_user,
                    'registration_status', 'manual_setup',
                    'ready', TRUE
                );
        END;
    END IF;
    
    -- Not ready - return status with next step guidance
    RETURN OBJECT_CONSTRUCT(
        'eai_configured', :v_eai_configured,
        'keys_initialized', :v_keys_initialized,
        'service_user', :v_service_user,
        'registration_status', 'not_registered',
        'ready', FALSE,
        'next_step', CASE
            WHEN NOT :v_eai_configured THEN 'Configure External Access Integration'
            WHEN NOT :v_keys_initialized THEN 'Call CONFIG.INITIALIZE_KEYS()'
            WHEN :v_service_user IS NULL THEN 'Set SERVICE_USER in KEY_STORE or bind status_view'
            ELSE 'Unknown issue'
        END
    );
END;
$$;

GRANT USAGE ON PROCEDURE CONFIG.GET_STATUS() TO APPLICATION ROLE APP_PUBLIC;

-- ----------------------------------------------------------------------------
-- Health Check
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE CORE.HEALTH_CHECK()
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    result VARIANT;
BEGIN
    CALL CONFIG.GET_STATUS() INTO :result;
    RETURN result;
END;
$$;

GRANT USAGE ON PROCEDURE CORE.HEALTH_CHECK() TO APPLICATION ROLE APP_PUBLIC;
GRANT USAGE ON PROCEDURE CORE.HEALTH_CHECK() TO APPLICATION ROLE APP_ADMIN;

-- ----------------------------------------------------------------------------
-- Chat Wrapper - Calls the EAI-enabled implementation
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE CORE.CHAT(message VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
AS
$$
DECLARE
    result VARIANT;
    eai_configured BOOLEAN DEFAULT FALSE;
    v_refs VARCHAR;
BEGIN
    -- Check if EAI is configured using SYSTEM$GET_ALL_REFERENCES
    BEGIN
        SELECT SYSTEM$GET_ALL_REFERENCES('external_access') INTO :v_refs;
        SELECT ARRAY_SIZE(PARSE_JSON(:v_refs)) > 0 INTO :eai_configured;
    EXCEPTION
        WHEN OTHER THEN
            eai_configured := FALSE;
    END;
    
    IF (NOT eai_configured) THEN
        RETURN PARSE_JSON('{"error": "External Access not configured. Approve the Cortex API Access permission in app settings."}');
    END IF;
    
    CALL CONFIG.CHAT_IMPL(:message) INTO :result;
    RETURN result;
EXCEPTION
    WHEN OTHER THEN
        RETURN OBJECT_CONSTRUCT('error', SQLERRM);
END;
$$;

GRANT USAGE ON PROCEDURE CORE.CHAT(VARCHAR) TO APPLICATION ROLE APP_PUBLIC;
GRANT USAGE ON PROCEDURE CORE.CHAT(VARCHAR) TO APPLICATION ROLE APP_ADMIN;

-- ----------------------------------------------------------------------------
-- Streamlit App
-- ----------------------------------------------------------------------------
CREATE STREAMLIT IF NOT EXISTS CORE.CHATBOT
  FROM '/streamlit'
  MAIN_FILE = '/chatbot.py';

GRANT USAGE ON STREAMLIT CORE.CHATBOT TO APPLICATION ROLE APP_PUBLIC;
GRANT USAGE ON STREAMLIT CORE.CHATBOT TO APPLICATION ROLE APP_ADMIN;
