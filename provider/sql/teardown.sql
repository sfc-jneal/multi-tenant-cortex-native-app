-- ============================================================================
-- teardown.sql - Complete Cleanup
-- ============================================================================
-- Removes all objects created by this demo.
-- Run this to completely clean up the provider account.
--
-- WARNING: This is destructive and cannot be undone!
-- ============================================================================

USE ROLE ACCOUNTADMIN;

-- ----------------------------------------------------------------------------
-- Drop Service Users
-- ----------------------------------------------------------------------------
-- Query tenant registry to find all service users

DECLARE
    v_user VARCHAR;
    c_users CURSOR FOR 
        SELECT service_user FROM MT_AGENT_DEMO.CONFIG.TENANT_REGISTRY;
BEGIN
    OPEN c_users;
    LOOP
        FETCH c_users INTO v_user;
        IF (NOT FOUND) THEN LEAVE; END IF;
        EXECUTE IMMEDIATE 'DROP USER IF EXISTS ' || v_user;
    END LOOP;
    CLOSE c_users;
END;

-- Alternative if cursor doesn't work in your context:
-- DROP USER IF EXISTS TENANT_A_SVC;
-- DROP USER IF EXISTS TENANT_B_SVC;
-- DROP USER IF EXISTS TENANT_C_SVC;

-- ----------------------------------------------------------------------------
-- Drop Database (includes all roles, schemas, tables, etc.)
-- ----------------------------------------------------------------------------

DROP DATABASE IF EXISTS MT_AGENT_DEMO;

-- Verify cleanup
SELECT 'Teardown complete' AS status;
SHOW DATABASES LIKE 'MT_AGENT_DEMO';
