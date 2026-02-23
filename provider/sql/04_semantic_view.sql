-- ============================================================================
-- 04_semantic_view.sql - Single Shared Semantic View
-- ============================================================================
-- Creates ONE semantic view used by the shared Cortex Agent.
-- Data filtering happens via RAP, not via separate views per tenant.
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE DATABASE MT_AGENT_DEMO;
USE SCHEMA AGENTS;

-- ----------------------------------------------------------------------------
-- Shared Semantic View
-- ----------------------------------------------------------------------------
-- Points to V_SALES which has RAP applied. The RAP filters data based on
-- the caller's database role, so each tenant only sees their own data.

CREATE OR REPLACE SEMANTIC VIEW SALES_SEMANTIC_VIEW
  TABLES (
    sales AS MT_AGENT_DEMO.DATA.V_SALES
      PRIMARY KEY (sale_id)
      COMMENT = 'Sales transactions - automatically filtered by tenant via Row Access Policy'
  )
  DIMENSIONS (
    sales.sale_id AS sale_id
      COMMENT = 'Unique identifier for the sale',
    sales.product_name AS product_name
      COMMENT = 'Name of the product sold',
    sales.category AS category
      COMMENT = 'Product category (Electronics, Software, Hardware, Services)',
    sales.region AS region
      COMMENT = 'Sales region (North, South, East, West)',
    sales.salesperson AS salesperson
      COMMENT = 'Name of the salesperson who made the sale',
    sales.sale_date AS sale_date
      COMMENT = 'Date when the sale occurred'
  )
  METRICS (
    sales.total_quantity AS SUM(quantity)
      COMMENT = 'Total quantity of items sold',
    sales.avg_unit_price AS AVG(unit_price)
      COMMENT = 'Average price per unit',
    sales.total_revenue AS SUM(total_amount)
      COMMENT = 'Total sales revenue in dollars',
    sales.sale_count AS COUNT(sale_id)
      COMMENT = 'Number of sales transactions'
  )
  COMMENT = 'Shared semantic view for multi-tenant sales analytics. Data is automatically filtered by tenant via Row Access Policy.';

-- Verify setup
SELECT 'Semantic view created successfully' AS status;
SHOW SEMANTIC VIEWS IN SCHEMA AGENTS;
