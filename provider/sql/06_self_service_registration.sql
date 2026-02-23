-- ============================================================================
-- 06_self_service_registration.sql - Automated Tenant Registration
-- ============================================================================
-- Replaces manual credential sharing with self-service key-pair registration.
--
-- Flow:
-- 1. Consumer Native App generates RSA key pair
-- 2. App writes public key + account info to REGISTRATION_REQUESTS (shared)
-- 3. STREAM detects new registration
-- 4. TASK auto-provisions: user, role, grants, RAP rebuild
-- 5. Consumer polls V_MY_STATUS until ACTIVE
-- 6. App uses private key to generate JWT → OAuth token
--
-- NO MANUAL PROVIDER STEPS REQUIRED!
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE DATABASE MT_AGENT_DEMO;
USE SCHEMA CONFIG;

-- ----------------------------------------------------------------------------
-- Registration Requests Table
-- ----------------------------------------------------------------------------
-- Consumers write to this table to request access.
-- This table will be shared via the Native App for write access.

CREATE TABLE IF NOT EXISTS REGISTRATION_REQUESTS (
    request_id VARCHAR(50) DEFAULT UUID_STRING() PRIMARY KEY,
    consumer_account_locator VARCHAR(50) NOT NULL,
    organization_name VARCHAR(255) NOT NULL,
    contact_email VARCHAR(255),
    public_key VARCHAR(4000) NOT NULL,          -- RSA public key in PEM format
    status VARCHAR(20) DEFAULT 'PENDING',       -- PENDING, PROCESSING, ACTIVE, FAILED
    error_message VARCHAR(1000),
    requested_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    processed_at TIMESTAMP_NTZ,
    
    -- Prevent duplicate registrations per account
    UNIQUE (consumer_account_locator)
);

-- ----------------------------------------------------------------------------
-- Stream on Registration Requests
-- ----------------------------------------------------------------------------
-- Detects new registration requests for processing

CREATE OR REPLACE STREAM REGISTRATION_STREAM 
    ON TABLE REGISTRATION_REQUESTS
    APPEND_ONLY = TRUE;

-- ----------------------------------------------------------------------------
-- Auto-Provisioning Procedure
-- ----------------------------------------------------------------------------
-- Called by TASK to provision new tenants automatically

CREATE OR REPLACE PROCEDURE AUTO_PROVISION_TENANT(
    p_request_id VARCHAR,
    p_consumer_account_locator VARCHAR,
    p_organization_name VARCHAR,
    p_public_key VARCHAR
)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    v_tenant_id VARCHAR;
    v_db_role VARCHAR;
    v_svc_user VARCHAR;
BEGIN
    -- Generate tenant ID from account locator (sanitized)
    v_tenant_id := 'TENANT_' || UPPER(REGEXP_REPLACE(p_consumer_account_locator, '[^A-Za-z0-9]', '_'));
    v_db_role := v_tenant_id || '_DATA_ROLE';
    v_svc_user := v_tenant_id || '_SVC';

    -- Update status to PROCESSING
    UPDATE CONFIG.REGISTRATION_REQUESTS 
    SET status = 'PROCESSING' 
    WHERE request_id = p_request_id;

    -- Step 1: Create database role
    EXECUTE IMMEDIATE 'CREATE DATABASE ROLE IF NOT EXISTS MT_AGENT_DEMO.' || v_db_role;

    -- Step 2: Create service user with public key
    EXECUTE IMMEDIATE 'CREATE USER IF NOT EXISTS ' || v_svc_user || ' TYPE = SERVICE RSA_PUBLIC_KEY = ''' || p_public_key || '''';
    
    -- If user already exists, update the public key
    EXECUTE IMMEDIATE 'ALTER USER ' || v_svc_user || ' SET RSA_PUBLIC_KEY = ''' || p_public_key || '''';

    -- Step 3: Grant database role to service user
    EXECUTE IMMEDIATE 'GRANT DATABASE ROLE MT_AGENT_DEMO.' || v_db_role || ' TO USER ' || v_svc_user;

    -- Step 4: Grant schema and view access to database role
    EXECUTE IMMEDIATE 'GRANT USAGE ON DATABASE MT_AGENT_DEMO TO DATABASE ROLE MT_AGENT_DEMO.' || v_db_role;
    EXECUTE IMMEDIATE 'GRANT USAGE ON SCHEMA MT_AGENT_DEMO.DATA TO DATABASE ROLE MT_AGENT_DEMO.' || v_db_role;
    EXECUTE IMMEDIATE 'GRANT USAGE ON SCHEMA MT_AGENT_DEMO.AGENTS TO DATABASE ROLE MT_AGENT_DEMO.' || v_db_role;
    EXECUTE IMMEDIATE 'GRANT SELECT ON VIEW MT_AGENT_DEMO.DATA.V_SALES TO DATABASE ROLE MT_AGENT_DEMO.' || v_db_role;
    
    -- Step 5: Grant semantic view access
    EXECUTE IMMEDIATE 'GRANT SELECT ON SEMANTIC VIEW MT_AGENT_DEMO.AGENTS.SALES_SEMANTIC_VIEW TO DATABASE ROLE MT_AGENT_DEMO.' || v_db_role;
    EXECUTE IMMEDIATE 'GRANT REFERENCES ON SEMANTIC VIEW MT_AGENT_DEMO.AGENTS.SALES_SEMANTIC_VIEW TO DATABASE ROLE MT_AGENT_DEMO.' || v_db_role;
    
    -- Step 6: Grant agent usage
    EXECUTE IMMEDIATE 'GRANT USAGE ON AGENT MT_AGENT_DEMO.AGENTS.SHARED_AGENT TO DATABASE ROLE MT_AGENT_DEMO.' || v_db_role;
    
    -- Step 7: Grant warehouse usage
    EXECUTE IMMEDIATE 'GRANT USAGE ON WAREHOUSE COMPUTE_WH TO DATABASE ROLE MT_AGENT_DEMO.' || v_db_role;

    -- Step 8: Register tenant in registry
    MERGE INTO CONFIG.TENANT_REGISTRY t
    USING (SELECT v_tenant_id AS tenant_id) s
    ON t.tenant_id = s.tenant_id
    WHEN MATCHED THEN UPDATE SET
        tenant_name = p_organization_name,
        consumer_account_locator = p_consumer_account_locator,
        service_user = v_svc_user,
        database_role = v_db_role,
        status = 'ACTIVE',
        updated_at = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT 
        (tenant_id, tenant_name, consumer_account_locator, service_user, database_role, status)
    VALUES 
        (v_tenant_id, p_organization_name, p_consumer_account_locator, v_svc_user, v_db_role, 'ACTIVE');

    -- Step 9: Rebuild RAP to include new tenant
    CALL CONFIG.REBUILD_RAP();

    -- Step 10: Update registration status to ACTIVE
    UPDATE CONFIG.REGISTRATION_REQUESTS 
    SET status = 'ACTIVE', processed_at = CURRENT_TIMESTAMP()
    WHERE request_id = p_request_id;

    RETURN OBJECT_CONSTRUCT(
        'status', 'success',
        'tenant_id', v_tenant_id,
        'service_user', v_svc_user,
        'database_role', v_db_role
    );

EXCEPTION
    WHEN OTHER THEN
        -- Update registration with error
        UPDATE CONFIG.REGISTRATION_REQUESTS 
        SET status = 'FAILED', 
            error_message = SQLERRM,
            processed_at = CURRENT_TIMESTAMP()
        WHERE request_id = p_request_id;
        
        RETURN OBJECT_CONSTRUCT('status', 'error', 'message', SQLERRM);
END;
$$;

-- ----------------------------------------------------------------------------
-- Process Registrations Procedure
-- ----------------------------------------------------------------------------
-- Processes all pending registrations from the stream

CREATE OR REPLACE PROCEDURE PROCESS_PENDING_REGISTRATIONS()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    v_count INT DEFAULT 0;
    v_request_id VARCHAR;
    v_account VARCHAR;
    v_org VARCHAR;
    v_key VARCHAR;
    c_pending CURSOR FOR 
        SELECT request_id, consumer_account_locator, organization_name, public_key
        FROM REGISTRATION_STREAM
        WHERE status = 'PENDING';
BEGIN
    OPEN c_pending;
    LOOP
        FETCH c_pending INTO v_request_id, v_account, v_org, v_key;
        IF (NOT FOUND) THEN LEAVE; END IF;
        
        CALL AUTO_PROVISION_TENANT(v_request_id, v_account, v_org, v_key);
        v_count := v_count + 1;
    END LOOP;
    CLOSE c_pending;
    
    RETURN 'Processed ' || v_count || ' registration(s)';
END;
$$;

-- ----------------------------------------------------------------------------
-- Task: Auto-Provision
-- ----------------------------------------------------------------------------
-- Runs every minute to process new registrations

CREATE OR REPLACE TASK REGISTRATION_PROCESSOR_TASK
    WAREHOUSE = COMPUTE_WH
    SCHEDULE = '1 MINUTE'
    WHEN SYSTEM$STREAM_HAS_DATA('CONFIG.REGISTRATION_STREAM')
AS
    CALL CONFIG.PROCESS_PENDING_REGISTRATIONS();

-- Start the task
ALTER TASK REGISTRATION_PROCESSOR_TASK RESUME;

-- ----------------------------------------------------------------------------
-- Status View for Consumers
-- ----------------------------------------------------------------------------
-- Consumers poll this to check their registration status

CREATE OR REPLACE SECURE VIEW V_MY_STATUS AS
SELECT 
    r.status AS registration_status,
    r.error_message,
    r.requested_at,
    r.processed_at,
    t.tenant_id,
    t.tenant_name,
    t.service_user,
    CASE WHEN t.status = 'ACTIVE' THEN TRUE ELSE FALSE END AS ready
FROM REGISTRATION_REQUESTS r
LEFT JOIN TENANT_REGISTRY t 
    ON r.consumer_account_locator = t.consumer_account_locator
WHERE r.consumer_account_locator = CURRENT_ACCOUNT();

-- ----------------------------------------------------------------------------
-- App Config View (no secrets)
-- ----------------------------------------------------------------------------

CREATE OR REPLACE SECURE VIEW V_APP_CONFIG AS
SELECT 
    'YOUR_ORG-YOUR_ACCOUNT' AS provider_account,
    'MT_AGENT_DEMO.AGENTS.SHARED_AGENT' AS agent_name;

-- ----------------------------------------------------------------------------
-- Verify Setup
-- ----------------------------------------------------------------------------

SELECT 'Self-service registration infrastructure created' AS status;
SELECT 'TASK is running every 1 minute to process registrations' AS note;

-- Show task status
SHOW TASKS LIKE 'REGISTRATION_PROCESSOR_TASK' IN SCHEMA CONFIG;
