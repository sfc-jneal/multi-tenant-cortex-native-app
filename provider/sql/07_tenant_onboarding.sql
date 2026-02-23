-- ============================================================================
-- 07_tenant_onboarding.sql - Manual Onboarding (Optional)
-- ============================================================================
-- These procedures are for MANUAL onboarding if needed.
-- With the self-service flow (06_self_service_registration.sql), these
-- are typically not needed - tenants auto-register via key-pair.
--
-- Use cases for manual onboarding:
-- - Pre-provisioning known tenants before they install
-- - Migrating existing tenants
-- - Testing without Native App
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE DATABASE MT_AGENT_DEMO;
USE SCHEMA CONFIG;

-- ----------------------------------------------------------------------------
-- Manual Onboarding (with password - for testing)
-- ----------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE ONBOARD_TENANT_MANUAL(
    p_tenant_id VARCHAR,
    p_consumer_account_locator VARCHAR,
    p_tenant_name VARCHAR,
    p_password VARCHAR DEFAULT NULL
)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    v_db_role VARCHAR;
    v_svc_user VARCHAR;
    v_password VARCHAR;
BEGIN
    -- Validate tenant_id format
    IF NOT REGEXP_LIKE(p_tenant_id, '^[A-Z][A-Z0-9_]*$') THEN
        RETURN OBJECT_CONSTRUCT(
            'status', 'error',
            'message', 'Invalid tenant_id format. Must be uppercase alphanumeric starting with a letter.'
        );
    END IF;

    v_db_role := p_tenant_id || '_DATA_ROLE';
    v_svc_user := p_tenant_id || '_SVC';
    v_password := COALESCE(p_password, UUID_STRING());  -- Generate random if not provided

    -- Create database role
    EXECUTE IMMEDIATE 'CREATE DATABASE ROLE IF NOT EXISTS MT_AGENT_DEMO.' || v_db_role;

    -- Create user with password (for testing without key-pair)
    EXECUTE IMMEDIATE 'CREATE USER IF NOT EXISTS ' || v_svc_user || ' PASSWORD = ''' || v_password || ''' TYPE = SERVICE';

    -- Grant database role to user
    EXECUTE IMMEDIATE 'GRANT DATABASE ROLE MT_AGENT_DEMO.' || v_db_role || ' TO USER ' || v_svc_user;

    -- Grant permissions
    EXECUTE IMMEDIATE 'GRANT USAGE ON DATABASE MT_AGENT_DEMO TO DATABASE ROLE MT_AGENT_DEMO.' || v_db_role;
    EXECUTE IMMEDIATE 'GRANT USAGE ON SCHEMA MT_AGENT_DEMO.DATA TO DATABASE ROLE MT_AGENT_DEMO.' || v_db_role;
    EXECUTE IMMEDIATE 'GRANT USAGE ON SCHEMA MT_AGENT_DEMO.AGENTS TO DATABASE ROLE MT_AGENT_DEMO.' || v_db_role;
    EXECUTE IMMEDIATE 'GRANT SELECT ON VIEW MT_AGENT_DEMO.DATA.V_SALES TO DATABASE ROLE MT_AGENT_DEMO.' || v_db_role;
    EXECUTE IMMEDIATE 'GRANT SELECT ON SEMANTIC VIEW MT_AGENT_DEMO.AGENTS.SALES_SEMANTIC_VIEW TO DATABASE ROLE MT_AGENT_DEMO.' || v_db_role;
    EXECUTE IMMEDIATE 'GRANT REFERENCES ON SEMANTIC VIEW MT_AGENT_DEMO.AGENTS.SALES_SEMANTIC_VIEW TO DATABASE ROLE MT_AGENT_DEMO.' || v_db_role;
    EXECUTE IMMEDIATE 'GRANT USAGE ON AGENT MT_AGENT_DEMO.AGENTS.SHARED_AGENT TO DATABASE ROLE MT_AGENT_DEMO.' || v_db_role;
    EXECUTE IMMEDIATE 'GRANT USAGE ON WAREHOUSE COMPUTE_WH TO DATABASE ROLE MT_AGENT_DEMO.' || v_db_role;

    -- Register tenant
    MERGE INTO CONFIG.TENANT_REGISTRY t
    USING (SELECT p_tenant_id AS tenant_id) s
    ON t.tenant_id = s.tenant_id
    WHEN MATCHED THEN UPDATE SET
        tenant_name = p_tenant_name,
        consumer_account_locator = p_consumer_account_locator,
        service_user = v_svc_user,
        database_role = v_db_role,
        status = 'ACTIVE',
        updated_at = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT 
        (tenant_id, tenant_name, consumer_account_locator, service_user, database_role, status)
    VALUES 
        (p_tenant_id, p_tenant_name, p_consumer_account_locator, v_svc_user, v_db_role, 'ACTIVE');

    -- Rebuild RAP
    CALL CONFIG.REBUILD_RAP();

    RETURN OBJECT_CONSTRUCT(
        'status', 'success',
        'tenant_id', p_tenant_id,
        'service_user', v_svc_user,
        'password', v_password,
        'note', 'Use this password for testing. For production, use key-pair auth via self-service registration.'
    );
END;
$$;

-- ----------------------------------------------------------------------------
-- Deactivate / Reactivate (same as before)
-- ----------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE DEACTIVATE_TENANT(p_tenant_id VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
AS
$$
BEGIN
    UPDATE CONFIG.TENANT_REGISTRY
    SET status = 'INACTIVE', updated_at = CURRENT_TIMESTAMP()
    WHERE tenant_id = p_tenant_id;
    
    CALL CONFIG.REBUILD_RAP();
    
    RETURN OBJECT_CONSTRUCT('status', 'success', 'message', 'Tenant deactivated');
END;
$$;

CREATE OR REPLACE PROCEDURE REACTIVATE_TENANT(p_tenant_id VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
AS
$$
BEGIN
    UPDATE CONFIG.TENANT_REGISTRY
    SET status = 'ACTIVE', updated_at = CURRENT_TIMESTAMP()
    WHERE tenant_id = p_tenant_id;
    
    CALL CONFIG.REBUILD_RAP();
    
    RETURN OBJECT_CONSTRUCT('status', 'success', 'message', 'Tenant reactivated');
END;
$$;

-- ----------------------------------------------------------------------------
-- View: Tenant Status
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW V_TENANT_STATUS AS
SELECT 
    tenant_id,
    tenant_name,
    consumer_account_locator,
    service_user,
    database_role,
    status,
    created_at,
    updated_at
FROM TENANT_REGISTRY
ORDER BY created_at DESC;

SELECT 'Manual onboarding procedures created (optional - use self-service flow instead)' AS status;
