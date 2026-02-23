-- ============================================================================
-- deploy.sql - Application Package Deployment Script
-- ============================================================================
-- Run this in the provider account to create/update the Native App package.
-- 
-- Prerequisites:
-- 1. Run provider/sql/01_infrastructure.sql through 05_agent.sql first
-- 2. Upload files via: ./scripts/deploy.sh upload
--
-- App Package: MT_AGENT_SVC_USER_APP_PKG
-- ============================================================================

USE ROLE ACCOUNTADMIN;

-- ----------------------------------------------------------------------------
-- Step 1: Create Application Package (if not exists)
-- ----------------------------------------------------------------------------

CREATE APPLICATION PACKAGE IF NOT EXISTS MT_AGENT_SVC_USER_APP_PKG
    COMMENT = 'Multi-tenant Cortex Agent - Direct API with Key-Pair Auth';

-- ----------------------------------------------------------------------------
-- Step 2: Create Stage for App Files
-- ----------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS MT_AGENT_SVC_USER_APP_PKG.STAGE;
CREATE STAGE IF NOT EXISTS MT_AGENT_SVC_USER_APP_PKG.STAGE.APP_FILES
    DIRECTORY = (ENABLE = TRUE);

-- ----------------------------------------------------------------------------
-- Step 3: Verify files are uploaded (run after snow stage copy)
-- ----------------------------------------------------------------------------

-- LIST @MT_AGENT_SVC_USER_APP_PKG.STAGE.APP_FILES;

-- ----------------------------------------------------------------------------
-- Step 4: Add Version or Patch
-- 
-- For first deployment:
--   ALTER APPLICATION PACKAGE MT_AGENT_SVC_USER_APP_PKG
--       ADD VERSION V1_0 USING '@MT_AGENT_SVC_USER_APP_PKG.STAGE.APP_FILES';
--
-- For updates (add patch):
--   ALTER APPLICATION PACKAGE MT_AGENT_SVC_USER_APP_PKG
--       ADD PATCH FOR VERSION V1_0 USING '@MT_AGENT_SVC_USER_APP_PKG.STAGE.APP_FILES';
-- ----------------------------------------------------------------------------

-- ----------------------------------------------------------------------------
-- Step 5: Set Release Directive
-- ----------------------------------------------------------------------------

-- ALTER APPLICATION PACKAGE MT_AGENT_SVC_USER_APP_PKG
--     SET DEFAULT RELEASE DIRECTIVE VERSION = V1_0 PATCH = 0;

-- ----------------------------------------------------------------------------
-- Step 6: Share with Consumer Account
-- ----------------------------------------------------------------------------

ALTER APPLICATION PACKAGE MT_AGENT_SVC_USER_APP_PKG SET DISTRIBUTION = EXTERNAL;

GRANT INSTALL ON APPLICATION PACKAGE MT_AGENT_SVC_USER_APP_PKG
    TO ACCOUNT YOUR_CONSUMER_ACCOUNT;

-- ----------------------------------------------------------------------------
-- Verify
-- ----------------------------------------------------------------------------

SELECT 'Application package ready: MT_AGENT_SVC_USER_APP_PKG' AS status;
SHOW APPLICATION PACKAGES LIKE 'MT_AGENT_SVC_USER_APP_PKG';
SHOW VERSIONS IN APPLICATION PACKAGE MT_AGENT_SVC_USER_APP_PKG;
