#!/bin/bash
# Combined Security Installation Script
# Installs: wget, Automox, Splunk Forwarder, Rapid7 Insight Agent, SentinelOne
# Supports: Ubuntu, CentOS, RHEL, Debian, and Amazon Linux
# Must be run as root

set -e
trap 'echo "Error occurred at line $LINENO. Command: $BASH_COMMAND"' ERR
exec > >(tee -a /var/log/security_install.log) 2>&1

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

if [ "$(id -u)" -ne 0 ]; then
    log_message "Error: Run this script as root or with sudo."
    exit 1
fi

###########################################
# 1. Install wget
###########################################
install_wget() {
    log_message "Installing wget..."

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_NAME=$ID
        log_message "Detected OS: $OS_NAME"
    else
        log_message "Cannot detect OS."
        exit 1
    fi

    case $OS_NAME in
        ubuntu|debian)
            apt-get update -y && apt-get install -y wget
            ;;
        centos|rhel|fedora|amzn)
            yum update -y && yum install -y wget
            ;;
        *)
            log_message "Unsupported OS: $OS_NAME"
            exit 1
            ;;
    esac
}

###########################################
# 2. Install Automox Agent
###########################################
install_automox() {
    log_message "Installing Automox Agent..."

    if [ -d "/opt/amagent" ] && systemctl is-active --quiet amagent; then
        log_message "Automox already running."
        return
    fi

    curl -sS https://console.automox.com/downloadInstaller?accesskey=5f117ff4-4de7-4632-9e51-45f30b3f3f69 | bash || {
        wget -O automox_installer.sh https://console.automox.com/downloadInstaller?accesskey=5f117ff4-4de7-4632-9e51-45f30b3f3f69
        bash automox_installer.sh && rm -f automox_installer.sh
    }

    systemctl start amagent || true
}

###########################################
# 3. Install Splunk Universal Forwarder (Updated)
###########################################
install_splunk_forwarder() {
    log_message "Installing Splunk Universal Forwarder..."

    # Define variables
    SPLUNK_INSTALL_PATH="/opt/splunkforwarder"
    SPLUNK_ADMIN_USER="admin"
    SPLUNK_ADMIN_PASSWORD="jATCjcRdgV32"
    DEPLOYMENT_SERVER="74.235.207.51"
    FORWARD_SERVER_PORT="9997"
    DEPLOYMENT_SERVER_PORT="8089"

    # Check if already installed
    if [ -d "$SPLUNK_INSTALL_PATH" ] && [ -f "$SPLUNK_INSTALL_PATH/bin/splunk" ]; then
        log_message "Splunk Forwarder already installed at $SPLUNK_INSTALL_PATH"
        return
    fi

    # Detect OS
    . /etc/os-release
    
    # Download and install based on OS
    if [[ "$ID" == "ubuntu" || "$ID" == "debian" ]]; then
        log_message "Installing Splunk for Ubuntu/Debian..."
        SPLUNK_FORWARDER_URL="https://download.splunk.com/products/universalforwarder/releases/9.4.2/linux/splunkforwarder-9.4.2-e9664af3d956-linux-amd64.deb"
        SPLUNK_FORWARDER_PATH="/tmp/splunkforwarder-9.4.2-e9664af3d956-linux-amd64.deb"
        
        wget -O "$SPLUNK_FORWARDER_PATH" "$SPLUNK_FORWARDER_URL"
        dpkg -i "$SPLUNK_FORWARDER_PATH"
        rm -f "$SPLUNK_FORWARDER_PATH"
        
    elif [[ "$ID" == "rhel" || "$ID" == "centos" || "$ID" == "fedora" || "$ID" == "amzn" ]]; then
        log_message "Installing Splunk for RHEL/CentOS/Amazon Linux..."
        SPLUNK_FORWARDER_URL="https://download.splunk.com/products/universalforwarder/releases/9.4.2/linux/splunkforwarder-9.4.2-e9664af3d956.x86_64.rpm"
        SPLUNK_FORWARDER_PATH="/tmp/splunkforwarder.rpm"
        
        wget -O "$SPLUNK_FORWARDER_PATH" "$SPLUNK_FORWARDER_URL"
        rpm -i "$SPLUNK_FORWARDER_PATH"
        rm -f "$SPLUNK_FORWARDER_PATH"
    else
        log_message "Unsupported OS for Splunk installation: $ID"
        return 1
    fi

    # Create splunkfwd user and group if not exists
    if id "splunkfwd" &>/dev/null; then
        log_message "User splunkfwd already exists."
    else
        useradd -r -s /bin/false splunkfwd
        log_message "User splunkfwd created."
    fi

    # Generate hashed password
    log_message "Generating admin password hash..."
    HASHED_PASSWORD=$(openssl passwd -1 "$SPLUNK_ADMIN_PASSWORD")

    # Create necessary config directories
    mkdir -p "$SPLUNK_INSTALL_PATH/etc/system/local"

    # Write user-seed.conf
    log_message "Creating user-seed.conf..."
    cat > "$SPLUNK_INSTALL_PATH/etc/system/local/user-seed.conf" <<EOF
[user_info]
USERNAME = $SPLUNK_ADMIN_USER
HASHED_PASSWORD = $HASHED_PASSWORD
EOF

    # Write inputs.conf
    log_message "Creating inputs.conf..."
    cat > "$SPLUNK_INSTALL_PATH/etc/system/local/inputs.conf" <<EOF
[monitor:///var/log/syslog]
disabled = false
index = main
EOF

    # Write outputs.conf
    log_message "Creating outputs.conf..."
    cat > "$SPLUNK_INSTALL_PATH/etc/system/local/outputs.conf" <<EOF
[tcpout]
defaultGroup = default-autolb-group

[tcpout:default-autolb-group]
server = $DEPLOYMENT_SERVER:$FORWARD_SERVER_PORT

[tcpout-server://$DEPLOYMENT_SERVER:$FORWARD_SERVER_PORT]
EOF

    # Set ownership
    log_message "Setting ownership to splunkfwd..."
    chown -R splunkfwd:splunkfwd "$SPLUNK_INSTALL_PATH"

    # Stop Splunk if running
    if pgrep -f splunkd > /dev/null; then
        log_message "Stopping existing Splunk process..."
        "$SPLUNK_INSTALL_PATH/bin/splunk" stop
    fi

    # Start Splunk and enable boot-start
    log_message "Starting Splunk Universal Forwarder..."
    "$SPLUNK_INSTALL_PATH/bin/splunk" start --accept-license --answer-yes --no-prompt
    
    log_message "Enabling boot-start..."
    "$SPLUNK_INSTALL_PATH/bin/splunk" enable boot-start -user splunkfwd --accept-license --answer-yes --no-prompt

    # Configure deployment server
    log_message "Configuring deployment server..."
    "$SPLUNK_INSTALL_PATH/bin/splunk" set deploy-poll "$DEPLOYMENT_SERVER:$DEPLOYMENT_SERVER_PORT" -auth "$SPLUNK_ADMIN_USER:$SPLUNK_ADMIN_PASSWORD"

    # Restart Splunk to apply changes
    log_message "Restarting Splunk to apply configuration..."
    "$SPLUNK_INSTALL_PATH/bin/splunk" restart

    log_message "Splunk Universal Forwarder installation completed successfully."
}

###########################################
# 4. Install Rapid7 Insight Agent (Updated)
###########################################
arch_type=$(uname -p)

check_service() {
    service_name="$1"
   
    if ! systemctl status "$service_name" &>/dev/null; then
        echo "Service '$service_name' not found."
        return 1
    fi
   
    if systemctl is-active --quiet "$service_name"; then
        echo "$service_name is running."
        return 0
    else
        echo "$service_name is not running."
        return 1
    fi
}

install_rapid7_insight_agent() {
    # Replace with your actual token from Rapid7 console
    rapid7_token="${RAPID7_TOKEN:-us2:5876cba8-81ee-4d81-9374-8a32809b8363}"
   
    # This will check that the Rapid7 User Token was provided when created the policy. If the token is not added, this worklet will exit.
    if [[ -z "$rapid7_token" ]]; then
        log_message "A secret key, named rapid7_token was not found. For this worklet to work, please add your Rapid7 user token to the policy for this worklet. Worklet exiting..."
        return 1
    fi
   
    # This will check for the existence of the Rapid7 Agent and install it if it is missing:
    if check_service ir_agent; then
        log_message "Rapid7 Insight Agent is already installed. No changes required."
        return 0
    else
        if [[ -d "/opt/rapid7/ir_agent" ]]; then
            log_message "Rapid7 Insight Agent is installed, but not active. This worklet will not reinstall the agent. Exiting..."
            return 0
        else
            log_message "Rapid7 Insight Agent is not installed. Attempting to install it now..."
           
            if [[ "$arch_type" == "x86_64" ]]; then
                curl -L https://us.storage.endpoint.ingress.rapid7.com/com.rapid7.razor.public/endpoint/agent/1697643903/linux/x86_64/agent_control_1697643903_x64.sh -o agent_installer-x86_64.sh
                rapid7_install_file="agent_installer-x86_64.sh"
            else
                curl -L https://us.storage.endpoint.ingress.rapid7.com/com.rapid7.razor.public/endpoint/agent/1697643903/linux/arm64/agent_control_1697643903_arm64.sh -o agent_installer-arm64.sh
                rapid7_install_file="agent_installer-arm64.sh"
            fi
           
            chmod +x "$rapid7_install_file"
            ./"$rapid7_install_file" install_start --token "$rapid7_token"
           
            if check_service ir_agent; then
                rapid7_installed="true"
                return 0
            else
                rapid7_installed="false"
                return 1
            fi
        fi
    fi
   
    # Final Evaluation
    if [[ "$rapid7_installed" == "false" ]]; then
        log_message "Rapid7 Insight Agent failed to install. Please check the Automox Activity Log for more information."
        return 1
    elif [[ -f "/opt/rapid7/ir_agent/ir_agent" ]]; then
        log_message "Rapid7 was installed - The agent can be found at /opt/rapid7/ir_agent/ir_agent."
        return 0
    else
        log_message "Rapid7 installation finished, but the agent could not be found. Please read the full activity log to confirm the installation finished."
        return 1
    fi
}

###########################################
# 5. Install SentinelOne Agent
###########################################
install_sentinelone() {
    log_message "Installing SentinelOne..."

    TOKEN="${SENTINELONE_TOKEN:-eyJ1cmwiOiAiaHR0cHM6Ly91c2VhMS1zMXN5LnNlbnRpbmVsb25lLm5ldCIsICJzaXRlX2tleSI6ICI2Mjk4YmIxNzI5YmQ0MDY1In0=}"
    FILE_NAME="SentinelAgent_linux.tar.gz"

    if [ -d "/opt/sentinelone" ]; then
        /opt/sentinelone/bin/sentinelctl management token set "$TOKEN"
        /opt/sentinelone/bin/sentinelctl control status
        return
    fi

    tar -xzf "$FILE_NAME"

    . /etc/os-release
    INSTALL_SUCCESS=false

    if [[ "$ID" == "ubuntu" || "$ID" == "debian" ]]; then
        dpkg -i SentinelAgent_linux_v23_1_2_9.deb && INSTALL_SUCCESS=true
    elif [[ "$ID" == "rhel" || "$ID" == "centos" || "$ID" == "fedora" || "$ID" == "amzn" ]]; then
        rpm -ivh --nodigest --nofiledigest SentinelAgent_linux_v23_1_2_9.rpm && INSTALL_SUCCESS=true
    fi

    if [ "$INSTALL_SUCCESS" = true ]; then
        /opt/sentinelone/bin/sentinelctl management token set "$TOKEN"
        /opt/sentinelone/bin/sentinelctl control start
    fi

    rm -f SentinelAgent_linux_*.{deb,rpm}
}

###########################################
# Main
###########################################
main() {
    log_message "Starting full installation..."

    install_wget
    install_automox
    install_splunk_forwarder
    install_rapid7_insight_agent
    install_sentinelone

    log_message "------- Final Status Report -------"
    log_message "wget: $(command -v wget >/dev/null && echo "installed" || echo "missing")"
    log_message "Automox: $(systemctl is-active amagent || echo "unknown")"
    log_message "Splunk: $(/opt/splunkforwarder/bin/splunk status 2>/dev/null || echo "unknown")"
    log_message "Rapid7: $(systemctl is-active ir_agent || echo "unknown")"
    log_message "SentinelOne: $(systemctl is-active sentinelone || echo "unknown")"
}

main

