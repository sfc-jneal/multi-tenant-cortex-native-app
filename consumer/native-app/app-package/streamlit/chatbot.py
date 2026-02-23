"""Sales Analytics Assistant - Multi-Tenant Native App with Key-Pair Auth.

This Streamlit app calls Cortex Agent API directly using service user key-pair auth.
No SPCS proxy needed - authentication and tenant isolation handled via database roles.
"""
import streamlit as st
import json
import time
from snowflake.snowpark.context import get_active_session


def initialize_keys():
    """Generate and store RSA key pair."""
    try:
        session = get_active_session()
        result = session.sql("CALL CONFIG.INITIALIZE_KEYS()").collect()
        if result and result[0][0]:
            val = result[0][0]
            return json.loads(val) if isinstance(val, str) else val
        return {"status": "error", "error": "No result"}
    except Exception as e:
        return {"status": "error", "error": str(e)}


def get_status():
    """Get setup status."""
    try:
        session = get_active_session()
        result = session.sql("CALL CONFIG.GET_STATUS()").collect()
        if result and result[0][0]:
            val = result[0][0]
            return json.loads(val) if isinstance(val, str) else val
        return {"status": "unknown"}
    except Exception as e:
        return {"status": "error", "error": str(e)}


def health_check():
    """Check overall health."""
    try:
        session = get_active_session()
        result = session.sql("CALL CORE.HEALTH_CHECK()").collect()
        if result and result[0][0]:
            val = result[0][0]
            return json.loads(val) if isinstance(val, str) else val
        return {"status": "error"}
    except Exception as e:
        return {"status": "error", "error": str(e)}


def chat(message: str):
    """Send chat message."""
    try:
        session = get_active_session()
        safe_message = message.replace("'", "''")
        result = session.sql(f"CALL CORE.CHAT('{safe_message}')").collect()
        if result and result[0][0]:
            val = result[0][0]
            return json.loads(val) if isinstance(val, str) else val
        return {"error": "No response"}
    except Exception as e:
        return {"error": str(e)}


def show_setup_required(status: dict):
    """Show setup instructions."""
    st.warning("**Setup Required**")
    
    eai_configured = status.get("eai_configured", False)
    keys_initialized = status.get("keys_initialized", False)
    
    st.markdown("### Setup Status")
    
    col1, col2 = st.columns(2)
    with col1:
        if eai_configured:
            st.success("External Access: OK")
        else:
            st.error("External Access: Needed")
    
    with col2:
        if keys_initialized:
            st.success("Keys: Initialized")
        else:
            st.error("Keys: Not Set")
    
    st.divider()
    
    # Show next step
    next_step = status.get("next_step", "")
    if next_step:
        st.info(f"**Next:** {next_step}")
    
    if not eai_configured:
        st.markdown("""
        ### Step 1: Approve External Access
        
        This app needs permission to call Snowflake APIs.
        
        **To approve:**
        1. Go to **Snowsight** -> **Data Products** -> **Apps**
        2. Click on this application
        3. Find **"Cortex API Access"** under Security
        4. Click **Review** then **Approve**
        """)
    
    elif not keys_initialized:
        st.markdown("""
        ### Step 2: Initialize Keys
        
        Generate your authentication key pair:
        """)
        
        if st.button("Initialize Keys", use_container_width=True):
            with st.spinner("Generating key pair..."):
                result = initialize_keys()
                if result.get("status") == "created":
                    st.success("Keys generated!")
                    st.code(result.get("public_key", ""), language="text")
                    st.markdown("""
                    **Important:** Copy the public key above and give it to the provider 
                    to register with your service user.
                    """)
                    time.sleep(2)
                    st.rerun()
                elif result.get("status") == "exists":
                    st.info("Keys already exist.")
                    st.rerun()
                else:
                    st.error(f"Error: {result.get('error', 'Unknown')}")
    
    else:
        st.markdown("""
        ### Step 3: Complete Registration
        
        Keys are initialized. Now the provider needs to:
        1. Create a service user for your tenant
        2. Register your public key with the service user
        3. Grant the service user access to the agent
        
        Once complete, bind the **status_view** reference to see your registration status.
        """)
    
    if status.get("error"):
        with st.expander("Technical Details"):
            st.code(status.get("error"))
    
    st.divider()
    
    if st.button("Refresh Status", use_container_width=True):
        st.rerun()


def show_chat_interface():
    """Show the main chat interface."""
    # Sidebar
    with st.sidebar:
        st.header("Connection")
        
        health = health_check()
        if health.get("ready"):
            st.success("Connected")
            if health.get("service_user"):
                st.caption(f"User: {health.get('service_user')}")
        else:
            st.warning(health.get("status", "Unknown"))
        
        st.divider()
        
        if st.button("New Conversation", use_container_width=True):
            st.session_state.messages = []
            st.rerun()
        
        st.divider()
        st.caption("**Sample questions:**")
        st.markdown("""
        - What were our total sales?
        - Which product has highest revenue?
        - Show me sales by region
        - Who is our top salesperson?
        """)
        
        st.divider()
        st.caption("**Architecture:**")
        st.markdown("""
        - Direct Cortex Agent API
        - Key-pair authentication
        - Database role isolation
        - Row Access Policy filtering
        """)
    
    # Chat history
    if "messages" not in st.session_state:
        st.session_state.messages = []
    
    for message in st.session_state.messages:
        with st.chat_message(message["role"]):
            st.markdown(message["content"])
    
    # Chat input
    if prompt := st.chat_input("Ask about your sales data..."):
        st.session_state.messages.append({"role": "user", "content": prompt})
        with st.chat_message("user"):
            st.markdown(prompt)
        
        with st.chat_message("assistant"):
            with st.spinner("Analyzing..."):
                result = chat(prompt)
                
                if "error" in result:
                    response = f"Error: {result['error']}"
                    if result.get("details"):
                        response += f"\n\n{result['details'][:200]}"
                else:
                    response = result.get("response", "No response received.")
                
            st.markdown(response)
        
        st.session_state.messages.append({"role": "assistant", "content": response})


def main():
    st.set_page_config(
        page_title="Sales Analytics Assistant",
        page_icon="📊",
        layout="wide"
    )
    
    st.title("Sales Analytics Assistant")
    st.caption("Powered by Snowflake Cortex Agent | Direct API | Key-Pair Auth")
    
    # Check status
    status = get_status()
    
    # Determine what to show
    if status.get("ready"):
        show_chat_interface()
    else:
        show_setup_required(status)


if __name__ == "__main__":
    main()
