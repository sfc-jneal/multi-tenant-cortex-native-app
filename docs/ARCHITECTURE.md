# Multi-Tenant Cortex Agent Architecture

## Overview

This architecture enables a **single shared Cortex Agent** to serve multiple tenants with:
- **Fully self-service onboarding** (no provider intervention)
- **Complete data isolation** via Row Access Policies
- **Key-pair authentication** (private key never leaves consumer)

## The Problem

When building multi-tenant Cortex Agent solutions with Native Apps:

1. **Cross-account identity**: Consumer users don't exist in provider account
2. **Scalable onboarding**: Can't manually provision every Marketplace install
3. **Credential distribution**: How do consumers authenticate to provider?

## The Solution: Self-Service Key-Pair Registration

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        THE SELF-SERVICE FLOW                                 │
│                                                                              │
│  Consumer                              Provider                              │
│  ────────                              ────────                              │
│                                                                              │
│  1. Install Native App                                                       │
│         │                                                                    │
│         ▼                                                                    │
│  2. App generates RSA key pair                                               │
│     ┌──────────────┐                                                         │
│     │ Private Key  │ ─── stored locally (never transmitted)                 │
│     │ Public Key   │ ─────────────────────────┐                             │
│     └──────────────┘                          │                             │
│                                               ▼                             │
│  3. App sends registration ──────────► REGISTRATION_REQUESTS table          │
│     (public key + account info)               │                             │
│                                               ▼                             │
│                                        STREAM detects new row               │
│                                               │                             │
│                                               ▼                             │
│                                        TASK runs (every 1 min)              │
│                                               │                             │
│                                               ▼                             │
│                                        AUTO_PROVISION_TENANT():             │
│                                        - CREATE USER + public key           │
│                                        - CREATE DATABASE ROLE               │
│                                        - GRANT permissions                  │
│                                        - REBUILD RAP                        │
│                                               │                             │
│  4. App polls status ◄─────────────── Status = ACTIVE                       │
│         │                                                                    │
│         ▼                                                                    │
│  5. App generates JWT (signed with private key)                              │
│         │                                                                    │
│         ▼                                                                    │
│  6. Exchange JWT for OAuth token ────► Snowflake validates signature        │
│         │                              against stored public key             │
│         ▼                                                                    │
│  7. Call Cortex API with OAuth token                                         │
│         │                                                                    │
│         ▼                                                                    │
│  8. Agent runs as tenant's service user                                      │
│     RAP filters data to tenant only                                          │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Why Key-Pair? (Comparison of Auth Methods)

| Method | Initial Credential | Created Via | Automated? | Security |
|--------|-------------------|-------------|------------|----------|
| **Password** | Password string | SQL | ✅ Yes | ⚠️ Transmitted over network |
| **PAT** | PAT token | Snowsight UI only | ❌ No | 🔒 Good, but manual |
| **Key-Pair** | Public key | SQL | ✅ Yes | 🔒 Private key never transmitted |

**Key-pair wins** because:
1. Fully automatable (public key assignment is just SQL)
2. Most secure (private key never leaves consumer)
3. Easy rotation (consumer can regenerate anytime)

## Component Deep Dive

### 1. Registration Table + Stream + Task

```sql
-- Consumers write here
CREATE TABLE REGISTRATION_REQUESTS (
    consumer_account_locator VARCHAR,
    organization_name VARCHAR,
    public_key VARCHAR,        -- RSA public key
    status VARCHAR DEFAULT 'PENDING'
);

-- Detect new registrations
CREATE STREAM REGISTRATION_STREAM ON TABLE REGISTRATION_REQUESTS;

-- Process automatically
CREATE TASK REGISTRATION_PROCESSOR_TASK
    WAREHOUSE = COMPUTE_WH
    SCHEDULE = '1 MINUTE'
    WHEN SYSTEM$STREAM_HAS_DATA('REGISTRATION_STREAM')
AS
    CALL PROCESS_PENDING_REGISTRATIONS();
```

### 2. Auto-Provisioning Procedure

```sql
CREATE PROCEDURE AUTO_PROVISION_TENANT(p_account, p_org, p_public_key)
AS
$$
    -- Generate tenant ID from account locator
    v_tenant_id := 'TENANT_' || UPPER(p_account);
    v_user := v_tenant_id || '_SVC';
    v_role := v_tenant_id || '_DATA_ROLE';
    
    -- Create user with public key (THIS IS THE KEY LINE!)
    CREATE USER {v_user} TYPE = SERVICE RSA_PUBLIC_KEY = '{p_public_key}';
    
    -- Create role and grants
    CREATE DATABASE ROLE {v_role};
    GRANT DATABASE ROLE {v_role} TO USER {v_user};
    GRANT SELECT ON VIEW V_SALES TO DATABASE ROLE {v_role};
    GRANT USAGE ON AGENT SHARED_AGENT TO DATABASE ROLE {v_role};
    
    -- Rebuild RAP to include new tenant
    CALL REBUILD_RAP();
$$
```

### 3. Row Access Policy

```sql
-- RAP must be rebuilt when tenants change (IS_DATABASE_ROLE_IN_SESSION requires literals)
CREATE PROCEDURE REBUILD_RAP()
AS
$$
    -- Generates:
    -- (tenant_id = 'TENANT_ABC' AND IS_DATABASE_ROLE_IN_SESSION('TENANT_ABC_DATA_ROLE'))
    -- OR (tenant_id = 'TENANT_XYZ' AND IS_DATABASE_ROLE_IN_SESSION('TENANT_XYZ_DATA_ROLE'))
    -- OR CURRENT_ROLE() IN ('ACCOUNTADMIN')
$$
```

### 4. JWT Generation (Consumer Side)

```python
def generate_jwt(private_key, account, user):
    # Get public key fingerprint
    public_key_der = private_key.public_key().public_bytes(DER)
    fingerprint = 'SHA256:' + base64(sha256(public_key_der))
    
    claims = {
        "iss": f"{account}.{user}.{fingerprint}",
        "sub": f"{account}.{user}",
        "iat": now,
        "exp": now + 60  # 60 seconds
    }
    
    # Sign with RS256
    return sign(claims, private_key, RS256)
```

### 5. Token Exchange

```python
# Exchange JWT for OAuth token
response = requests.post(
    "https://account.snowflakecomputing.com/oauth/token",
    data={
        "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion": jwt,
        "scope": "account.snowflakecomputing.com"
    }
)
access_token = response.text
```

## Security Model

### Data Isolation

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Query: SELECT * FROM V_SALES                                                │
│                                                                              │
│  Running as: TENANT_ABC_SVC                                                  │
│  Active roles: TENANT_ABC_DATA_ROLE                                          │
│                                                                              │
│  RAP evaluates:                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ (tenant_id = 'TENANT_ABC'                                           │    │
│  │   AND IS_DATABASE_ROLE_IN_SESSION('TENANT_ABC_DATA_ROLE')) → TRUE  │    │
│  │ OR                                                                  │    │
│  │ (tenant_id = 'TENANT_XYZ'                                           │    │
│  │   AND IS_DATABASE_ROLE_IN_SESSION('TENANT_XYZ_DATA_ROLE')) → FALSE │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  Result: Only TENANT_ABC rows returned                                       │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Credential Security

| Credential | Where Stored | Who Can Access | Lifetime |
|------------|--------------|----------------|----------|
| Private Key | Consumer app table | Consumer only | Until rotated |
| Public Key | Provider user record | Provider (read-only) | Until rotated |
| JWT | Generated on demand | Consumer only | 60 seconds |
| OAuth Token | Memory cache | Consumer only | ~1 hour |

## Comparison to Alternatives

### vs. Object Per Tenant (OPT)

| Aspect | OPT | This Architecture |
|--------|-----|-------------------|
| Objects per tenant | ~4 (view, semantic view, agent, routing) | ~2 (user, role) |
| Shared agent | No | Yes |
| Onboarding | Manual | Automated |
| Maintenance | Higher | Lower |

### vs. Chuck's OAuth (Single Account)

| Aspect | Chuck's OAuth | This Architecture |
|--------|---------------|-------------------|
| Account setup | Single account | Cross-account (Native App) |
| User management | Users exist in account | Service users created per tenant |
| Authentication | User's OAuth login | Key-pair → JWT → OAuth |
| Self-service | Yes (users exist) | Yes (auto-provisioned) |

## Operational Considerations

### Monitoring

```sql
-- Check task status
SHOW TASKS LIKE 'REGISTRATION_PROCESSOR_TASK';

-- View pending registrations
SELECT * FROM CONFIG.REGISTRATION_REQUESTS WHERE status = 'PENDING';

-- View tenant status
SELECT * FROM CONFIG.V_TENANT_STATUS;
```

### Troubleshooting

| Issue | Cause | Solution |
|-------|-------|----------|
| Registration stuck PENDING | Task not running | `ALTER TASK ... RESUME` |
| JWT exchange fails | Wrong account format | Check account identifier format |
| No data returned | RAP not rebuilt | `CALL REBUILD_RAP()` |
| 401 on API call | Token expired | Token cache auto-refreshes |

### Cost

| Component | Cost |
|-----------|------|
| Registration TASK | ~$0.01/day (runs when stream has data) |
| API calls | Standard Cortex pricing |
| Storage | Minimal (key storage, registry) |

## Limitations

1. **RAP rebuild required** when adding tenants (IS_DATABASE_ROLE_IN_SESSION requires literals)
2. **Single agent** means all tenants share same model/behavior
3. **No tenant-specific customization** of prompts or tools
4. **Key rotation** requires consumer to re-register

## Future Improvements

- [ ] Key rotation without re-registration
- [ ] Tenant-specific system prompts
- [ ] Usage metering per tenant
- [ ] Admin dashboard for provider
