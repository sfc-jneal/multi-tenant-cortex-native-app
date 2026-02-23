"""JWT-based authentication for Cortex Agent API.

This module handles the self-service registration and authentication flow:
1. Generate RSA key pair on first launch
2. Register with provider (send public key)
3. Generate JWT signed with private key
4. Exchange JWT for OAuth access token
5. Call Cortex API with access token

No manual provider intervention required!
"""
import json
import time
import base64
import hashlib
from datetime import datetime, timedelta
from typing import Tuple, Optional

# These imports are available in Snowflake's Python environment
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa, padding
from cryptography.hazmat.backends import default_backend
import requests

# Cache for OAuth tokens
_token_cache = {"token": None, "expires_at": 0}


def generate_key_pair() -> Tuple[bytes, bytes]:
    """Generate RSA-2048 key pair.
    
    Returns:
        Tuple of (private_key_pem, public_key_pem) as bytes
    """
    private_key = rsa.generate_private_key(
        public_exponent=65537,
        key_size=2048,
        backend=default_backend()
    )
    
    private_key_pem = private_key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption()
    )
    
    public_key = private_key.public_key()
    public_key_pem = public_key.public_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PublicFormat.SubjectPublicKeyInfo
    )
    
    return private_key_pem, public_key_pem


def format_public_key_for_snowflake(public_key_pem: bytes) -> str:
    """Format public key for Snowflake's RSA_PUBLIC_KEY parameter.
    
    Snowflake expects the key without PEM headers and as a single line.
    """
    key_str = public_key_pem.decode('utf-8')
    # Remove PEM headers and newlines
    key_str = key_str.replace('-----BEGIN PUBLIC KEY-----', '')
    key_str = key_str.replace('-----END PUBLIC KEY-----', '')
    key_str = key_str.replace('\n', '').strip()
    return key_str


def generate_jwt(
    private_key_pem: bytes,
    account: str,
    user: str,
    lifetime_seconds: int = 60
) -> str:
    """Generate a JWT for Snowflake key-pair authentication.
    
    Args:
        private_key_pem: Private key in PEM format
        account: Snowflake account identifier (uppercase, with region)
        user: Snowflake username (uppercase)
        lifetime_seconds: Token lifetime (default 60 seconds)
    
    Returns:
        Signed JWT string
    """
    # Load private key
    private_key = serialization.load_pem_private_key(
        private_key_pem,
        password=None,
        backend=default_backend()
    )
    
    # Get public key fingerprint for 'iss' claim
    public_key = private_key.public_key()
    public_key_der = public_key.public_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PublicFormat.SubjectPublicKeyInfo
    )
    sha256_hash = hashlib.sha256(public_key_der).digest()
    public_key_fp = 'SHA256:' + base64.b64encode(sha256_hash).decode('utf-8')
    
    # Normalize account name (uppercase, replace dashes)
    account_upper = account.upper().replace('-', '_').replace('.', '_')
    # Example: MYORG-MY_ACCOUNT becomes MYORG_MY_ACCOUNT
    
    # Build JWT claims
    now = datetime.utcnow()
    claims = {
        "iss": f"{account_upper}.{user.upper()}.{public_key_fp}",
        "sub": f"{account_upper}.{user.upper()}",
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(seconds=lifetime_seconds)).timestamp())
    }
    
    # Encode header and payload
    header = {"alg": "RS256", "typ": "JWT"}
    header_b64 = base64.urlsafe_b64encode(json.dumps(header).encode()).rstrip(b'=').decode()
    payload_b64 = base64.urlsafe_b64encode(json.dumps(claims).encode()).rstrip(b'=').decode()
    
    # Sign
    message = f"{header_b64}.{payload_b64}".encode()
    signature = private_key.sign(message, padding.PKCS1v15(), hashes.SHA256())
    signature_b64 = base64.urlsafe_b64encode(signature).rstrip(b'=').decode()
    
    return f"{header_b64}.{payload_b64}.{signature_b64}"


def exchange_jwt_for_token(jwt: str, account: str) -> str:
    """Exchange JWT for OAuth access token.
    
    Args:
        jwt: Signed JWT
        account: Snowflake account identifier
    
    Returns:
        OAuth access token
    """
    token_url = f"https://{account}.snowflakecomputing.com/oauth/token"
    
    data = {
        "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "scope": f"{account}.snowflakecomputing.com",
        "assertion": jwt
    }
    
    response = requests.post(token_url, data=data, timeout=30)
    
    if response.status_code != 200:
        raise Exception(f"JWT exchange failed: {response.status_code} - {response.text[:300]}")
    
    # Response is the token directly (not JSON)
    return response.text.strip()


def get_access_token(
    private_key_pem: bytes,
    account: str,
    user: str
) -> str:
    """Get OAuth access token using key-pair auth, with caching.
    
    Args:
        private_key_pem: Private key in PEM format
        account: Snowflake account identifier
        user: Service user name
    
    Returns:
        OAuth access token (cached for 45 minutes)
    """
    global _token_cache
    
    # Return cached token if still valid
    if time.time() < _token_cache["expires_at"] and _token_cache["token"]:
        return _token_cache["token"]
    
    # Generate new JWT and exchange for token
    jwt = generate_jwt(private_key_pem, account, user)
    token = exchange_jwt_for_token(jwt, account)
    
    # Cache for 45 minutes (tokens typically valid for 1 hour)
    _token_cache["token"] = token
    _token_cache["expires_at"] = time.time() + 2700
    
    return token


def clear_token_cache():
    """Clear the token cache."""
    global _token_cache
    _token_cache = {"token": None, "expires_at": 0}


def parse_sse_response(text: str) -> str:
    """Parse Server-Sent Events response from Cortex API."""
    result_text = ""
    
    for line in text.split("\n"):
        line = line.strip()
        if not line.startswith("data:"):
            continue
            
        try:
            data = json.loads(line[5:].strip())
            
            if "delta" in data:
                delta = data["delta"]
                if "content" in delta:
                    for item in delta["content"]:
                        if item.get("type") == "text":
                            result_text += item.get("text", "")
                elif "text" in delta:
                    result_text += delta["text"]
            elif "message" in data:
                msg = data["message"]
                if "content" in msg:
                    for item in msg["content"]:
                        if item.get("type") == "text":
                            result_text += item.get("text", "")
        except json.JSONDecodeError:
            continue
    
    return result_text


def call_cortex_agent(
    private_key_pem: bytes,
    account: str,
    user: str,
    agent_name: str,
    message: str
) -> dict:
    """Call Cortex Agent API using key-pair authentication.
    
    Args:
        private_key_pem: Private key in PEM format
        account: Provider account identifier
        user: Service user name
        agent_name: Fully-qualified agent name
        message: User's chat message
    
    Returns:
        dict with 'response' on success, 'error' on failure
    """
    try:
        # Get access token (uses cache)
        access_token = get_access_token(private_key_pem, account, user)
        
        # Call Cortex API
        api_url = f"https://{account}.snowflakecomputing.app/api/v2/cortex/agent:run"
        
        headers = {
            "Authorization": f'Snowflake Token="{access_token}"',
            "Content-Type": "application/json",
            "Accept": "text/event-stream"
        }
        
        payload = {
            "agent_name": agent_name,
            "messages": [{"role": "user", "content": message}],
            "response_instruction": "Be concise and helpful. Format numbers and currency nicely."
        }
        
        response = requests.post(api_url, headers=headers, json=payload, timeout=120)
        
        if response.status_code == 200:
            response_text = parse_sse_response(response.text)
            if response_text:
                return {"response": response_text}
            return {"response": response.text[:1000], "raw": True}
            
        elif response.status_code == 401:
            # Token might be expired, clear cache and retry
            clear_token_cache()
            access_token = get_access_token(private_key_pem, account, user)
            headers["Authorization"] = f'Snowflake Token="{access_token}"'
            
            response = requests.post(api_url, headers=headers, json=payload, timeout=120)
            if response.status_code == 200:
                return {"response": parse_sse_response(response.text)}
            return {"error": f"Auth failed after retry: {response.status_code}"}
        else:
            return {"error": f"API returned {response.status_code}", "details": response.text[:500]}
            
    except Exception as e:
        return {"error": str(e)}
