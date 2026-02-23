-- ============================================================================
-- 02_data_model.sql - Data Tables and Secure Views
-- ============================================================================
-- Creates the multi-tenant data model. Every table that needs tenant isolation
-- MUST have a tenant_id column.
--
-- The Row Access Policy is created in 03_row_access_policy.sql
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE DATABASE MT_AGENT_DEMO;
USE SCHEMA DATA;

-- ----------------------------------------------------------------------------
-- Multi-tenant SALES table
-- ----------------------------------------------------------------------------
-- IMPORTANT: tenant_id column is REQUIRED for Row Access Policy

CREATE TABLE IF NOT EXISTS SALES (
    sale_id VARCHAR(50) DEFAULT UUID_STRING() PRIMARY KEY,
    tenant_id VARCHAR(50) NOT NULL,          -- REQUIRED: Used by RAP for isolation
    sale_date DATE NOT NULL,
    product_name VARCHAR(255) NOT NULL,
    category VARCHAR(100),
    quantity INT NOT NULL,
    unit_price DECIMAL(10,2) NOT NULL,
    total_amount DECIMAL(12,2) NOT NULL,
    region VARCHAR(50),
    salesperson VARCHAR(100),
    created_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Note: Snowflake uses micro-partitioning instead of indexes
-- Clustering could be added for large tables: ALTER TABLE SALES CLUSTER BY (tenant_id);

-- ----------------------------------------------------------------------------
-- Secure View for Cortex Agent
-- ----------------------------------------------------------------------------
-- Semantic views require a view (not direct table access).
-- RAP automatically applies when querying through this view.

CREATE OR REPLACE SECURE VIEW V_SALES AS
SELECT 
    sale_id,
    tenant_id,
    sale_date,
    product_name,
    category,
    quantity,
    unit_price,
    total_amount,
    region,
    salesperson
FROM SALES;

-- Verify setup
SELECT 'Data model created successfully' AS status;
SHOW TABLES IN SCHEMA DATA;
SHOW VIEWS IN SCHEMA DATA;
