#!/bin/bash
# Combined Security Installation Script
# Installs wget, Automox, Splunk Forwarder, and SentinelOne
# Supports: Ubuntu, CentOS, Debian, and Amazon Linux
# Must be run as root

# Set error handling
set +e
trap 'echo "Error occurred at line $LINENO. Command: $BASH_COMMAND"' ERR

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
# 1. Install wget Utility
###########################################
install_wget() {
    log_message "Installing wget..."

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_NAME=$ID
        log_message "Detected OS: $OS_NAME"
    else
        log_message "Cannot detect OS. Trying common package managers."
        if command -v apt-get &>/dev/null; then OS_NAME="debian"
        elif command -v yum &>/dev/null; then OS_NAME="centos"
        else log_message "Unsupported OS." && return 1
        fi
    fi

    case $OS_NAME in
        ubuntu|debian)
            apt-get update -y && apt-get install -y wget
            ;;
        centos|rhel|fedora|amzn)
            yum update -y && yum install -y wget 
            ;;
        *)
            log_message "Unknown OS: $OS_NAME"
            return 1
            ;;
    esac

    if command -v wget &>/dev/null; then
        log_message "wget installed: $(wget --version | head -n1)"
    else
        log_message "wget installation failed."
        return 1
    fi
}

###########################################
# 2. Install Automox Agent
###########################################
install_automox() {
    log_message "Installing Automox Agent..."

    if [ -d "/opt/amagent" ] && systemctl is-active --quiet amagent; then
        log_message "Automox already installed and running."
    else
        curl -sS https://console.automox.com/downloadInstaller?accesskey=5f117ff4-4de7-4632-9e51-45f30b3f3f69 | bash || {
            wget -O automox_installer.sh https://console.automox.com/downloadInstaller?accesskey=5f117ff4-4de7-4632-9e51-45f30b3f3f69
            bash automox_installer.sh && rm -f automox_installer.sh
        }
        systemctl start amagent || true
    fi

    if systemctl is-active --quiet amagent; then
        log_message "Automox agent running."
    else
        log_message "Warning: Automox agent not active."
    fi
}

###########################################
# 3. Install Splunk Universal Forwarder
###########################################
install_splunk_forwarder() {
    INSTALL_DIR="/opt/splunkforwarder"
    log_message "Installing Splunk Forwarder..."

    if [ -d "$INSTALL_DIR" ] && "$INSTALL_DIR/bin/splunk" status >/dev/null 2>&1; then
        log_message "Splunk Forwarder already installed."
    else
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

        groupadd -r splunk 2>/dev/null || true
        useradd -r -m -g splunk splunk 2>/dev/null || true
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
    fi

    if "$INSTALL_DIR/bin/splunk" status >/dev/null 2>&1; then
        log_message "Splunk Forwarder installed and running."
    else
        log_message "Warning: Splunk Forwarder status unknown."
    fi
}

###########################################
# 4. Install SentinelOne Agent
###########################################
install_sentinelone() {
    log_message "Installing SentinelOne..."

    TOKEN="eyJ1cmwiOiAiaHR0cHM6Ly91c2VhMS1zMXN5LnNlbnRpbmVsb25lLm5ldCIsICJzaXRlX2tleSI6ICI2Mjk4YmIxNzI5YmQ0MDY1In0="
    FILE_NAME="SentinelAgent_linux.tar.gz"

    if [ -d "/opt/sentinelone" ]; then
        /opt/sentinelone/bin/sentinelctl management token set "$TOKEN"
        /opt/sentinelone/bin/sentinelctl control status
    else
        tar -xzf "$FILE_NAME" || {
            log_message "Extraction failed."
            return 1
        }

        . /etc/os-release
        INSTALL_SUCCESS=false

        if [[ "$ID" == "ubuntu" || "$ID" == "debian" ]]; then
            dpkg -i SentinelAgent_linux_v23_1_2_9.deb && INSTALL_SUCCESS=true
        elif [[ "$ID" == "rhel" || "$ID" == "centos" || "$ID" == "fedora" || "$ID" == "amzn" ]]; then
            rpm -ivh --nodigest --nofiledigest SentinelAgent_linux_v23_1_2_9.rpm && INSTALL_SUCCESS=true
        fi

        if [ "$INSTALL_SUCCESS" = true ]; then
            /opt/sentinelone/bin/sentinelctl management token set "$TOKEN" || log_message "Warning: Failed to set SentinelOne token"
            /opt/sentinelone/bin/sentinelctl control start || log_message "Warning: Failed to start SentinelOne service"
	    /opt/sentinelone/bin/sentinelctl control status || log_message "Warning: SentinelOne service status check failed"
	    /opt/sentinelone/bin/sentinelctl version || log_message "Warning: Failed to get SentinelOne version"
        else
            log_message "Warning: SentinelOne install failed."
        fi

        rm -f SentinelAgent_linux_*.{deb,rpm}
    fi
}

###########################################
# Main
###########################################
main() {
    log_message "Starting installation process..."

    install_wget || exit 1
    install_automox
    install_splunk_forwarder
    install_sentinelone

    log_message "------- Final Status Report -------"
    log_message "wget: $(command -v wget >/dev/null && echo "installed" || echo "missing")"
    log_message "Automox: $(systemctl is-active amagent 2>/dev/null || echo "unknown")"
    log_message "Splunk: $(/opt/splunkforwarder/bin/splunk status 2>/dev/null || echo "unknown")"
    log_message "SentinelOne: $(systemctl is-active sentinelone 2>/dev/null || echo "unknown")"
}

# Run main
main
