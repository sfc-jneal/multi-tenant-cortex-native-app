-- Test RAP by checking what different roles see
-- Run this in Snowsight or via snow sql -f
-- TODO: Replace TENANT_EXAMPLE with your actual tenant name and database

-- 1. Check current role and if db role is in session  
SELECT 'Current Role' as test, CURRENT_ROLE() as result;
SELECT 'Has TENANT_EXAMPLE_DATA_ROLE' as test, 
       IS_DATABASE_ROLE_IN_SESSION('MT_AGENT_SERVICE_USER_DEMO.TENANT_EXAMPLE_DATA_ROLE') as result;

-- 2. Check what data is visible
SELECT 'Rows by Tenant' as test, tenant_id, COUNT(*) as cnt 
FROM MT_AGENT_SERVICE_USER_DEMO.DATA.SALES 
GROUP BY tenant_id;

-- 3. Total visible rows
SELECT 'Total Visible Rows' as test, COUNT(*) as result 
FROM MT_AGENT_SERVICE_USER_DEMO.DATA.SALES;
