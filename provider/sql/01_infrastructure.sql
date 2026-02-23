-- ============================================================================
-- 01_infrastructure.sql - Database and Schema Setup
-- ============================================================================
-- Creates the core database structure for multi-tenant Cortex Agent demo.
-- Uses per-tenant service users approach (not per-tenant agents).
--
-- Run this first.
-- ============================================================================

USE ROLE ACCOUNTADMIN;

-- Create the main database
CREATE DATABASE IF NOT EXISTS MT_AGENT_DEMO;
USE DATABASE MT_AGENT_DEMO;

-- Create schemas for logical separation
CREATE SCHEMA IF NOT EXISTS CONFIG;      -- Tenant registry, credentials, onboarding
CREATE SCHEMA IF NOT EXISTS DATA;        -- Multi-tenant data tables with RAP
CREATE SCHEMA IF NOT EXISTS AGENTS;      -- Shared Cortex Agent and semantic view

-- Grant schema usage to future tenant roles (they'll need to query data)
-- Individual grants happen during tenant onboarding

-- Verify setup
SELECT 'Infrastructure created successfully' AS status;
SHOW SCHEMAS IN DATABASE MT_AGENT_DEMO;
