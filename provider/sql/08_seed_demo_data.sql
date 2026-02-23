-- ============================================================================
-- 08_seed_demo_data.sql - Demo Sales Data
-- ============================================================================
-- Inserts sample sales data for testing.
-- 
-- With self-service registration, tenants are created dynamically.
-- This script creates some test data for pre-provisioned tenants.
-- ============================================================================

USE ROLE ACCOUNTADMIN;
USE DATABASE MT_AGENT_DEMO;
USE SCHEMA DATA;

-- ----------------------------------------------------------------------------
-- Sample Data (will be filtered by RAP based on tenant)
-- ----------------------------------------------------------------------------
-- Note: tenant_id must match the format created by AUTO_PROVISION_TENANT:
-- TENANT_{ACCOUNT_LOCATOR} with non-alphanumeric chars replaced by _

-- For testing, we'll create data for a few hypothetical tenants
-- Real data would be created after tenants register

-- Demo tenant: ACME Corp (example provider tenant)
INSERT INTO SALES (tenant_id, sale_date, product_name, category, quantity, unit_price, total_amount, region, salesperson)
SELECT * FROM VALUES
    ('TENANT_ACME', '2024-10-15', 'Laptop Pro 15', 'Electronics', 10, 1299.99, 12999.90, 'West', 'Alice Johnson'),
    ('TENANT_ACME', '2024-10-22', 'Wireless Mouse', 'Electronics', 50, 29.99, 1499.50, 'West', 'Alice Johnson'),
    ('TENANT_ACME', '2024-11-05', 'Laptop Pro 15', 'Electronics', 15, 1299.99, 19499.85, 'East', 'Bob Smith'),
    ('TENANT_ACME', '2024-11-18', '4K Monitor', 'Electronics', 8, 449.99, 3599.92, 'East', 'Bob Smith'),
    ('TENANT_ACME', '2024-12-01', 'Mechanical Keyboard', 'Electronics', 25, 149.99, 3749.75, 'North', 'Carol Davis'),
    ('TENANT_ACME', '2024-12-12', 'Laptop Pro 15', 'Electronics', 20, 1299.99, 25999.80, 'South', 'Dan Wilson'),
    ('TENANT_ACME', '2025-01-08', 'Laptop Pro 17', 'Electronics', 5, 1799.99, 8999.95, 'West', 'Alice Johnson'),
    ('TENANT_ACME', '2025-01-15', 'Wireless Earbuds', 'Electronics', 40, 199.99, 7999.60, 'East', 'Bob Smith')
WHERE NOT EXISTS (SELECT 1 FROM SALES WHERE tenant_id = 'TENANT_ACME');

-- Demo tenant: Globex Inc (example consumer tenant)
INSERT INTO SALES (tenant_id, sale_date, product_name, category, quantity, unit_price, total_amount, region, salesperson)
SELECT * FROM VALUES
    ('TENANT_GLOBEX', '2024-10-10', 'Enterprise License', 'Software', 5, 4999.99, 24999.95, 'East', 'Emma White'),
    ('TENANT_GLOBEX', '2024-10-25', 'Support Plan Basic', 'Services', 10, 999.99, 9999.90, 'East', 'Emma White'),
    ('TENANT_GLOBEX', '2024-11-12', 'Cloud Storage 10TB', 'Software', 20, 199.99, 3999.80, 'West', 'Frank Brown'),
    ('TENANT_GLOBEX', '2024-11-28', 'Enterprise License', 'Software', 3, 4999.99, 14999.97, 'North', 'Grace Lee'),
    ('TENANT_GLOBEX', '2024-12-05', 'Support Plan Premium', 'Services', 8, 2499.99, 19999.92, 'South', 'Henry Chen'),
    ('TENANT_GLOBEX', '2025-01-10', 'Enterprise License', 'Software', 7, 4999.99, 34999.93, 'West', 'Frank Brown'),
    ('TENANT_GLOBEX', '2025-01-22', 'Training Workshop', 'Services', 4, 1999.99, 7999.96, 'North', 'Grace Lee')
WHERE NOT EXISTS (SELECT 1 FROM SALES WHERE tenant_id = 'TENANT_GLOBEX');

-- ----------------------------------------------------------------------------
-- Verify Data
-- ----------------------------------------------------------------------------

SELECT 'Demo data inserted' AS status;

-- Summary by tenant (run as ACCOUNTADMIN to see all)
SELECT 
    tenant_id,
    COUNT(*) AS num_sales,
    SUM(total_amount) AS total_revenue
FROM SALES
GROUP BY tenant_id
ORDER BY tenant_id;
