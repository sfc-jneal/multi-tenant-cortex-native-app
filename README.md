# Multi-Tenant Cortex Agent with Self-Service Onboarding

A fully automated multi-tenant architecture for Snowflake Cortex Agents using **per-tenant service users** with **key-pair authentication**. 

## What This Solves

When multiple tenants share a Cortex Agent, each tenant should only see their own data in responses. This repo implements tenant isolation using:

- Per-tenant service users for identity
- Row Access Policy that filters data by `CURRENT_USER()`
- Self-service onboarding via Native App

Single agent, single data model, many tenants - each seeing only their rows.

## Architecture Overview

```
Consumer Account                              Provider Account
┌─────────────────────────────────────┐      ┌─────────────────────────────────────────┐
│  Native App                         │      │                                         │
│                                     │      │  REGISTRATION_REQUESTS table            │
│  1. Generate RSA key pair           │      │         │                               │
│  2. Store private key locally       │      │         ▼                               │
│  3. Send public key ─────────────────────► │  STREAM + TASK (every 1 min)           │
│                                     │      │         │                               │
│     [Wait 1-2 minutes]              │      │         ▼                               │
│                                     │      │  AUTO-PROVISION:                        │
│  4. Poll status ◄──────────────────────────│  - CREATE USER + RSA_PUBLIC_KEY        │
│  5. Generate JWT with private key   │      │  - CREATE DATABASE ROLE                │
│  6. Exchange JWT → OAuth token      │      │  - GRANT permissions                   │
│  7. Call Cortex API                 │      │  - REBUILD RAP                         │
│                                     │      │         │                               │
│                                     │      │         ▼                               │
│                                     │      │  SHARED_AGENT (single agent)           │
│                                     │      │         │                               │
│  8. Get response (tenant data only) ◄──────│  RAP filters by tenant                 │
└─────────────────────────────────────┘      └─────────────────────────────────────────┘
```

## Why This Approach?

| Feature | This Architecture |
|---------|-------------------|
| **Self-service** | Yes |
| **Onboarding time** | Minutes |
| **Provider effort per tenant** | Minimal |
| **Scales to many tenants** | Yes |
| **Security** | Private key never leaves consumer |

## Quick Start

### 1. Provider Account Setup

```bash
cd provider/sql

# Run scripts in order
snow sql -f 01_infrastructure.sql
snow sql -f 02_data_model.sql
snow sql -f 03_row_access_policy.sql
snow sql -f 04_semantic_view.sql
snow sql -f 05_agent.sql
snow sql -f 06_self_service_registration.sql
snow sql -f 07_tenant_onboarding.sql      # Optional manual procedures
snow sql -f 08_seed_demo_data.sql         # Sample data
```

### 2. Deploy Native App

```bash
cd consumer/native-app
snow app run
```

### 3. Consumer Experience

1. Install Native App from Marketplace
2. Enter organization name
3. Wait 1-2 minutes (automatic provisioning)
4. Start chatting!

**That's it. No provider interaction required.**

## Configuration

Before deploying, update the placeholder values in these files:

| File | What to Change |
|------|----------------|
| `consumer/native-app/app-package/python/chat.py` | `PROVIDER_ACCOUNT` |
| `consumer/native-app/scripts/deploy.sh` | `PROVIDER_CONNECTION`, `CONSUMER_CONNECTION` |
| `consumer/native-app/scripts/deploy.sql` | `YOUR_CONSUMER_ACCOUNT` |
| `provider/sql/06_self_service_registration.sql` | `YOUR_ORG-YOUR_ACCOUNT` |

Or use the config script:
```bash
# Create .local/config.env with your values, then:
bash scripts/configure.sh local   # Apply your config
bash scripts/configure.sh public  # Reset to placeholders
```

## Key Files

| File | Purpose |
|------|---------|
| `provider/sql/06_self_service_registration.sql` | STREAM + TASK for auto-provisioning |
| `consumer/native-app/app-package/setup.sql` | Key generation, JWT auth |
| `consumer/native-app/app-package/streamlit/chatbot.py` | Self-service UI |

## Security Model

| Aspect | Implementation |
|--------|----------------|
| **Private key** | Generated and stored only in consumer account |
| **Public key** | Safe to share (it's public!) |
| **JWT lifetime** | 60 seconds (short-lived) |
| **OAuth token** | ~1 hour, cached 45 min |
| **Data isolation** | Row Access Policy with `CURRENT_USER()` |
| **Tenant identity** | Service user per tenant with single database role |

## Documentation

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for detailed architecture documentation.
