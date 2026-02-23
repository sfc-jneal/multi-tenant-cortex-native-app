"""Direct Cortex Agent API client using service user key-pair auth.

This module calls the Cortex Agent API directly using JWT-based authentication.
No SPCS proxy needed - the service user's database role provides tenant isolation.

Flow:
1. Load private key from CORE.KEY_STORE
2. Generate JWT signed with private key
3. Call Cortex Agent API directly with JWT as Bearer token
4. Agent uses service user's database role for RAP filtering

IMPORTANT: No OAuth token exchange needed! Use JWT directly with Bearer auth.
"""
import requests
import json
import time
import base64
import hashlib

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding
from cryptography.hazmat.backends import default_backend

# Configuration - Provider account info
# Format: ORG-ACCOUNT_NAME (hyphen between org and account, underscore within account name)
PROVIDER_ACCOUNT = "YOUR_ORG-YOUR_ACCOUNT"
PROVIDER_DATABASE = "MT_AGENT_SERVICE_USER_DEMO"
PROVIDER_SCHEMA = "DATA"
AGENT_NAME = "SALES_AGENT"

# JWT cache (JWTs are short-lived, regenerate frequently)
_jwt_cache = {"jwt": None, "expires_at": 0}


def generate_jwt(private_key_pem, account, service_user, session):
    """Generate a JWT signed with the service user's private key."""
    # Load the private key
    key = serialization.load_pem_private_key(
        private_key_pem.encode() if isinstance(private_key_pem, str) else private_key_pem,
        password=None,
        backend=default_backend()
    )
    
    # Get public key fingerprint
    pub = key.public_key()
    der = pub.public_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PublicFormat.SubjectPublicKeyInfo
    )
    fingerprint = "SHA256:" + base64.b64encode(hashlib.sha256(der).digest()).decode("utf-8")
    
    # Normalize account and user to uppercase
    # Account format: ORG-ACCOUNT_NAME (e.g., MYORG-MY_ACCOUNT)
    account_upper = account.upper()
    user_upper = service_user.upper()
    
    # Get current timestamp from Snowflake (ensures clock sync)
    ts_result = session.sql(
        "SELECT DATEDIFF('second', '1970-01-01'::TIMESTAMP_NTZ, "
        "CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::TIMESTAMP_NTZ)"
    ).collect()
    now_epoch = ts_result[0][0]
    
    # Build JWT claims
    claims = {
        "iss": f"{account_upper}.{user_upper}.{fingerprint}",
        "sub": f"{account_upper}.{user_upper}",
        "iat": now_epoch,
        "exp": now_epoch + 3540  # JWT valid for ~59 minutes (must be < 1 hour)
    }
    
    # Build JWT header
    header = {"alg": "RS256", "typ": "JWT"}
    
    # Base64url encode header and claims
    header_b64 = base64.urlsafe_b64encode(json.dumps(header).encode()).rstrip(b"=").decode()
    claims_b64 = base64.urlsafe_b64encode(json.dumps(claims).encode()).rstrip(b"=").decode()
    
    # Sign the JWT
    message = f"{header_b64}.{claims_b64}".encode()
    signature = key.sign(message, padding.PKCS1v15(), hashes.SHA256())
    signature_b64 = base64.urlsafe_b64encode(signature).rstrip(b"=").decode()
    
    return f"{header_b64}.{claims_b64}.{signature_b64}"


def get_jwt(private_key_pem, account, service_user, session):
    """Get a JWT, using cache if still valid."""
    global _jwt_cache
    
    # Check cache - use cached JWT if still valid (with 60s buffer)
    if time.time() < (_jwt_cache["expires_at"] - 60) and _jwt_cache["jwt"]:
        return _jwt_cache["jwt"]
    
    # Generate fresh JWT
    jwt = generate_jwt(private_key_pem, account, service_user, session)
    
    # Cache the JWT
    _jwt_cache["jwt"] = jwt
    _jwt_cache["expires_at"] = time.time() + 3540  # ~59 minutes
    
    return jwt


def clear_jwt_cache():
    """Clear the JWT cache."""
    global _jwt_cache
    _jwt_cache = {"jwt": None, "expires_at": 0}


def parse_agent_sse(response_text):
    """Parse SSE response from Cortex Agent API.
    
    Cortex Agent SSE format:
    - event: response.status data: {"status":"planning",...}
    - event: response.thinking.delta data: {"text":"..."}
    - event: response.text.delta data: {"text":"..."}  <-- Final answer content
    - event: response.tool_use data: {...}
    - event: response.tool_result data: {...}
    """
    content_result = ""
    thinking_result = ""
    current_event = None
    
    for line in response_text.split("\n"):
        line = line.strip()
        
        # Track event type
        if line.startswith("event:"):
            current_event = line[6:].strip()
            continue
        
        # Parse data lines
        if not line.startswith("data:"):
            continue
            
        try:
            data = json.loads(line[5:].strip())
            
            # Handle Cortex Agent format - text field directly in data
            if "text" in data:
                # response.text.delta = final answer content
                if current_event == "response.text.delta":
                    content_result += data["text"]
                # response.thinking.delta = agent reasoning
                elif current_event == "response.thinking.delta":
                    thinking_result += data["text"]
                # Also capture response.content.delta (alternative format)
                elif current_event == "response.content.delta":
                    content_result += data["text"]
            
            # Handle "content" field (alternative format)
            elif "content" in data and isinstance(data["content"], str):
                content_result += data["content"]
                        
        except json.JSONDecodeError:
            continue
    
    # Return content if available, otherwise show thinking
    if content_result:
        return content_result
    elif thinking_result:
        return f"[Agent thinking only - no final answer generated]\n\n{thinking_result}"
    return "[No response content found]"


def chat(session, message):
    """Send message to Cortex Agent API using key-pair auth.
    
    Args:
        session: Snowpark session
        message: User's chat message
        
    Returns:
        dict with 'response' on success, 'error' on failure
    """
    try:
        # Get private key from KEY_STORE
        key_result = session.sql(
            "SELECT private_key, service_user FROM CORE.KEY_STORE WHERE key_id = 1"
        ).collect()
        
        if not key_result:
            return {"error": "Keys not initialized. Call CONFIG.INITIALIZE_KEYS() first."}
        
        private_key = key_result[0][0]
        service_user = key_result[0][1]
        
        if not private_key:
            return {"error": "Private key is missing."}
        
        # If service_user not in KEY_STORE, try to get from status_view
        if not service_user:
            try:
                svc_result = session.sql(
                    "SELECT service_user FROM REFERENCE('status_view')"
                ).collect()
                if svc_result and svc_result[0][0]:
                    service_user = svc_result[0][0]
                    # Update KEY_STORE with the service user
                    session.sql(
                        f"UPDATE CORE.KEY_STORE SET service_user = '{service_user}' WHERE key_id = 1"
                    ).collect()
            except:
                pass
        
        if not service_user:
            return {"error": "Service user not configured. Complete registration with provider."}
        
        # Debug mode
        if message == "__DEBUG__":
            return {
                "service_user": service_user,
                "account": PROVIDER_ACCOUNT,
                "agent": f"{PROVIDER_DATABASE}.{PROVIDER_SCHEMA}.{AGENT_NAME}",
                "private_key_length": len(private_key) if private_key else 0
            }
        
        # Generate JWT (no OAuth exchange needed!)
        jwt_token = get_jwt(private_key, PROVIDER_ACCOUNT, service_user, session)
        
        # Debug JWT
        if message == "__DEBUG_JWT__":
            return {
                "jwt_length": len(jwt_token),
                "jwt_preview": jwt_token[:50] + "...",
                "service_user": service_user
            }
        
        # Test RAP - call provider's test procedure via REST API
        if message.upper() == "/TESTRAP":
            # Build test URL to call the test procedure
            account_for_url = PROVIDER_ACCOUNT.lower().replace("_", "-")
            test_url = f"https://{account_for_url}.snowflakecomputing.com/api/v2/statements"
            
            test_response = requests.post(
                test_url,
                headers={
                    "Authorization": f"Bearer {jwt_token}",
                    "Content-Type": "application/json",
                    "X-Snowflake-Authorization-Token-Type": "KEYPAIR_JWT"
                },
                json={
                    "statement": "CALL MT_AGENT_SERVICE_USER_DEMO.DATA.TEST_RAP_DETAILED()",
                    "timeout": 60,
                    "warehouse": "COMPUTE_WH"
                },
                timeout=60
            )
            
            return {
                "status_code": test_response.status_code,
                "response": test_response.text[:1000]
            }
        
        # Build Agent API URL (underscores -> hyphens for DNS hostname)
        account_for_url = PROVIDER_ACCOUNT.lower().replace("_", "-")
        agent_url = (
            f"https://{account_for_url}.snowflakecomputing.com"
            f"/api/v2/databases/{PROVIDER_DATABASE}/schemas/{PROVIDER_SCHEMA}"
            f"/agents/{AGENT_NAME}:run"
        )
        
        # Build request payload
        payload = {
            "messages": [
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "text",
                            "text": message
                        }
                    ]
                }
            ]
        }
        
        # Call Agent API directly with JWT as Bearer token
        # NO OAuth exchange needed - use JWT directly!
        response = requests.post(
            agent_url,
            headers={
                "Authorization": f"Bearer {jwt_token}",
                "Content-Type": "application/json",
                "Accept": "text/event-stream",
                "X-Snowflake-Authorization-Token-Type": "KEYPAIR_JWT"
            },
            json=payload,
            timeout=120
        )
        
        if response.status_code == 200:
            text_response = parse_agent_sse(response.text)
            
            if text_response:
                return {"response": text_response, "status": "success"}
            else:
                # Show more raw response for debugging (2000 chars)
                return {"response": f"[Raw SSE - parsing returned empty]\n\n{response.text[:2000]}", "raw": True, "status": "success"}
        
        elif response.status_code == 401:
            # JWT expired or invalid - retry once with fresh JWT
            clear_jwt_cache()
            jwt_token = get_jwt(private_key, PROVIDER_ACCOUNT, service_user, session)
            
            response = requests.post(
                agent_url,
                headers={
                    "Authorization": f"Bearer {jwt_token}",
                    "Content-Type": "application/json",
                    "Accept": "text/event-stream",
                    "X-Snowflake-Authorization-Token-Type": "KEYPAIR_JWT"
                },
                json=payload,
                timeout=120
            )
            
            if response.status_code == 200:
                return {"response": parse_agent_sse(response.text), "status": "success"}
        
        return {
            "error": f"Agent API returned {response.status_code}",
            "details": response.text[:500],
            "url": agent_url
        }
        
    except Exception as e:
        import traceback
        return {
            "error": str(e),
            "traceback": traceback.format_exc()
        }
