-- ============================================================================
-- 05_agent.sql - Single Shared Cortex Agent
-- ============================================================================
-- Creates ONE Cortex Agent shared by all tenants.
-- 
-- This is the key simplification vs OPT (Object Per Tenant):
-- - OPT: One agent per tenant, each pointing to tenant-specific views
-- - This approach: One shared agent, RAP filters data per tenant
--
-- Security: The agent can only see data that the RAP allows. Since each
-- tenant's service user has only their database role, the RAP automatically
-- filters to their data.
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE DATABASE MT_AGENT_DEMO;
USE SCHEMA AGENTS;
USE WAREHOUSE COMPUTE_WH;

-- ----------------------------------------------------------------------------
-- Shared Cortex Agent
-- ----------------------------------------------------------------------------

CREATE OR REPLACE AGENT SHARED_AGENT
  COMMENT = 'Shared multi-tenant Cortex Agent - data filtered by RAP based on caller identity'
  FROM SPECIFICATION $$
  {
    "tools": [
      {
        "tool_spec": {
          "type": "cortex_analyst_text_to_sql",
          "name": "sales_analyst",
          "description": "Query sales data including products, quantities, revenue, regions, and salesperson performance. Data is automatically filtered to your organization."
        }
      }
    ],
    "tool_resources": {
      "sales_analyst": {
        "semantic_view": "MT_AGENT_DEMO.AGENTS.SALES_SEMANTIC_VIEW",
        "execution_environment": {
          "type": "warehouse",
          "warehouse": "COMPUTE_WH"
        }
      }
    }
  }
  $$;

-- Verify setup
SELECT 'Shared Cortex Agent created successfully' AS status;
SHOW AGENTS IN SCHEMA AGENTS;

-- Note: Access to this agent is granted per-tenant during onboarding
-- via: GRANT USAGE ON AGENT SHARED_AGENT TO DATABASE ROLE {tenant}_DATA_ROLE
