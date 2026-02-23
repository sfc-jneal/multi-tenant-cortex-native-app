-- ============================================================================
-- 03_row_access_policy.sql - Row Access Policy with Database Role Checks
-- ============================================================================
-- Creates the Row Access Policy that enforces tenant isolation using
-- IS_DATABASE_ROLE_IN_SESSION() checks.
--
-- IMPORTANT: Because IS_DATABASE_ROLE_IN_SESSION() requires literal strings,
-- the RAP must be rebuilt when adding new tenants. The REBUILD_RAP() procedure
-- automates this.
--
-- The security model:
-- - Each tenant has a database role: {TENANT_ID}_DATA_ROLE
-- - Each tenant's service user has ONLY their role granted
-- - RAP checks if the caller's role matches the data's tenant_id
-- - Result: Tenant A's service user can only see Tenant A's data
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE DATABASE MT_AGENT_DEMO;

-- ----------------------------------------------------------------------------
-- Tenant Registry Table (for RAP rebuild)
-- ----------------------------------------------------------------------------
-- This table tracks all tenants. REBUILD_RAP() reads from here.

CREATE TABLE IF NOT EXISTS CONFIG.TENANT_REGISTRY (
    tenant_id VARCHAR(50) PRIMARY KEY,
    tenant_name VARCHAR(255) NOT NULL,
    consumer_account_locator VARCHAR(50),
    service_user VARCHAR(100),
    database_role VARCHAR(100),
    status VARCHAR(20) DEFAULT 'ACTIVE',
    created_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    updated_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- ----------------------------------------------------------------------------
-- Initial Row Access Policy (empty - will be rebuilt)
-- ----------------------------------------------------------------------------
-- Start with a policy that only allows admin access.
-- REBUILD_RAP() will add tenant-specific clauses.

CREATE OR REPLACE ROW ACCESS POLICY DATA.TENANT_ISOLATION_RAP
AS (tenant_id_col VARCHAR) RETURNS BOOLEAN ->
    -- Only admin roles until tenants are added
    CURRENT_ROLE() IN ('ACCOUNTADMIN', 'SYSADMIN');

-- Apply RAP to SALES table
ALTER TABLE DATA.SALES ADD ROW ACCESS POLICY DATA.TENANT_ISOLATION_RAP ON (tenant_id);

-- ----------------------------------------------------------------------------
-- REBUILD_RAP Procedure
-- ----------------------------------------------------------------------------
-- Regenerates the Row Access Policy to include all active tenants.
-- Call this after adding or removing tenants.
--
-- The generated RAP looks like:
--   (tenant_id_col = 'TENANT_A' AND IS_DATABASE_ROLE_IN_SESSION('...TENANT_A_DATA_ROLE'))
--   OR (tenant_id_col = 'TENANT_B' AND IS_DATABASE_ROLE_IN_SESSION('...TENANT_B_DATA_ROLE'))
--   OR CURRENT_ROLE() IN ('ACCOUNTADMIN', 'SYSADMIN')

CREATE OR REPLACE PROCEDURE CONFIG.REBUILD_RAP()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    v_rap_body VARCHAR;
    v_tenant_clause VARCHAR;
    v_tenant_id VARCHAR;
    v_db_role VARCHAR;
    c_tenants CURSOR FOR 
        SELECT tenant_id, database_role 
        FROM CONFIG.TENANT_REGISTRY 
        WHERE status = 'ACTIVE';
BEGIN
    -- Start building the RAP body
    v_rap_body := '';
    
    -- Add clause for each active tenant
    OPEN c_tenants;
    LOOP
        FETCH c_tenants INTO v_tenant_id, v_db_role;
        IF (NOT FOUND) THEN
            LEAVE;
        END IF;
        
        -- Build tenant-specific clause
        v_tenant_clause := '(tenant_id_col = ''' || v_tenant_id || ''' AND IS_DATABASE_ROLE_IN_SESSION(''MT_AGENT_DEMO.' || v_db_role || '''))';
        
        IF (v_rap_body != '') THEN
            v_rap_body := v_rap_body || ' OR ';
        END IF;
        v_rap_body := v_rap_body || v_tenant_clause;
    END LOOP;
    CLOSE c_tenants;
    
    -- Add admin bypass
    IF (v_rap_body != '') THEN
        v_rap_body := v_rap_body || ' OR ';
    END IF;
    v_rap_body := v_rap_body || 'CURRENT_ROLE() IN (''ACCOUNTADMIN'', ''SYSADMIN'')';
    
    -- Drop existing RAP from table
    ALTER TABLE DATA.SALES DROP ROW ACCESS POLICY IF EXISTS DATA.TENANT_ISOLATION_RAP;
    
    -- Create new RAP with updated body
    EXECUTE IMMEDIATE 'CREATE OR REPLACE ROW ACCESS POLICY DATA.TENANT_ISOLATION_RAP AS (tenant_id_col VARCHAR) RETURNS BOOLEAN -> ' || v_rap_body;
    
    -- Re-apply RAP to table
    ALTER TABLE DATA.SALES ADD ROW ACCESS POLICY DATA.TENANT_ISOLATION_RAP ON (tenant_id);
    
    RETURN 'RAP rebuilt successfully with ' || (SELECT COUNT(*) FROM CONFIG.TENANT_REGISTRY WHERE status = 'ACTIVE') || ' tenant(s)';
END;
$$;

-- ----------------------------------------------------------------------------
-- Helper: View Current RAP Definition
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW CONFIG.V_RAP_DEFINITION AS
SELECT 
    policy_name,
    policy_body
FROM TABLE(INFORMATION_SCHEMA.POLICY_REFERENCES(
    policy_name => 'MT_AGENT_DEMO.DATA.TENANT_ISOLATION_RAP'
));

-- Verify setup
SELECT 'Row Access Policy infrastructure created' AS status;
SELECT 'Run CALL CONFIG.REBUILD_RAP() after adding tenants' AS next_step;
