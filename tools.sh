#!/bin/bash
# Combined Security Installation Script
# Installs: wget, Automox, Splunk Forwarder, SentinelOne, Rapid7 Insight Agent
# Supports: Ubuntu, CentOS, Debian, and Amazon Linux
# Must be run as root

# Stop on first error
set -e
trap 'echo "Error occurred at line $LINENO. Command: $BASH_COMMAND"' ERR

# Optional: write output to a log file
exec > >(tee -a /var/log/security_install.log) 2>&1

# Log with timestamp
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Ensure script is run as root
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
# 3. Install Splunk Universal Forwarder
###########################################
install_splunk_forwarder() {
    INSTALL_DIR="/opt/splunkforwarder"
    log_message "Installing Splunk Forwarder..."

    if [ -d "$INSTALL_DIR" ]; then
        log_message "Splunk Forwarder already installed."
        return
    fi

    if command -v apt-get &>/dev/null; then
        apt-get install -y acl
    elif command -v yum &>/dev/null; then
        yum install -y acl
    fi

    . /etc/os-release
    if [[ "$ID" == "ubuntu" || "$ID" == "debian" ]]; then
        PACKAGE="splunkforwarder-9.4.2-e9664af3d956-linux-amd64.deb"
        wget -O "$PACKAGE" "https://download.splunk.com/products/universalforwarder/releases/9.4.2/linux/$PACKAGE"
        dpkg -i "$PACKAGE"
    else
        PACKAGE="splunkforwarder-9.4.2-e9664af3d956.x86_64.rpm"
        wget -O "$PACKAGE" "https://download.splunk.com/products/universalforwarder/releases/9.4.2/linux/$PACKAGE"
        rpm -ivh "$PACKAGE"
    fi
    rm -f "$PACKAGE"

    groupadd -r splunk || true
    useradd -r -m -g splunk splunk || true
    chown -R splunk:splunk "$INSTALL_DIR"

    setfacl -R -m u:splunk:rX /var/log || true
    setfacl -d -R -m u:splunk:rX /var/log || true

    su - splunk -c "mkdir -p ${INSTALL_DIR}/etc/system/local"
    su - splunk -c "tee ${INSTALL_DIR}/etc/system/local/deploymentclient.conf > /dev/null" <<EOF
[deployment-client]
[target-broker:deploymentServer]
targetUri=74.235.207.51:9997
EOF

    su - splunk -c "${INSTALL_DIR}/bin/splunk start --accept-license --answer-yes --no-prompt"
    su - splunk -c "${INSTALL_DIR}/bin/splunk enable boot-start -systemd-managed 1 -user splunk"
}

###########################################
# 4. Install SentinelOne Agent
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
# 5. Install Rapid7 Insight Agent
###########################################
install_rapid7_agent() {
    log_message "Installing Rapid7 Insight Agent..."

    REGION="${RAPID7_REGION:-us}"
    ACTIVATION_KEY="${RAPID7_KEY:-us2:5876cba8-81ee-4d81-9374-8a32809b8363}"

    curl -s -O https://downloads.r7insight.com/agent/InsightAgentInstaller_Linux.sh && chmod +x InsightAgentInstaller_Linux.sh

    ./InsightAgentInstaller_Linux.sh -r "$REGION" -k "$ACTIVATION_KEY"

    if systemctl is-active --quiet ir_agent; then
        log_message "Rapid7 Insight Agent installed and running."
    fi
}

###########################################
# Main
###########################################
main() {
    log_message "Starting full installation..."

    install_wget
    install_automox
    install_splunk_forwarder
    install_sentinelone
    install_rapid7_agent

    log_message "------- Final Status Report -------"
    log_message "wget: $(command -v wget >/dev/null && echo "installed" || echo "missing")"
    log_message "Automox: $(systemctl is-active amagent || echo "unknown")"
    log_message "Splunk: $(/opt/splunkforwarder/bin/splunk status || echo "unknown")"
    log_message "SentinelOne: $(systemctl is-active sentinelone || echo "unknown")"
    log_message "Rapid7: $(systemctl is-active ir_agent || echo "unknown")"
}

main

