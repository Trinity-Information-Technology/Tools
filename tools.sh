#!/bin/bash
# Combined Security Installation Script
# Installs zip utility and endpoint security suite components
# Supports: Ubuntu, CentOS, Debian, and Amazon Linux
# Script assumes it's being run as root

# Set error handling
set -e
trap 'echo "Error occurred at line $LINENO. Command: $BASH_COMMAND"' ERR

# Function to log messages with timestamps
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

###########################################
# Check for root privileges
###########################################
if [ "$(id -u)" -ne 0 ]; then
    log_message "Error: This script must be run as root. Please use sudo or switch to root user."
    exit 1
fi

###########################################
# 1. Install Zip Utility
###########################################
install_zip() {
    log_message "Starting zip utility installation..."
    
    # Detect OS distribution
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_NAME=$ID
        OS_VERSION=$VERSION_ID
        log_message "Detected OS: $OS_NAME $OS_VERSION"
    else
        log_message "Cannot determine OS distribution. Attempting to detect package manager..."
        if command -v apt-get &>/dev/null; then
            OS_NAME="debian"
        elif command -v yum &>/dev/null; then
            OS_NAME="centos"
        else
            log_message "Error: Unsupported OS distribution or cannot detect package manager."
            return 1
        fi
    fi
    
    # Install zip based on detected OS
    case $OS_NAME in
        ubuntu|debian)
            log_message "Installing zip using apt package manager..."
            apt-get update -y
            apt-get install -y zip unzip
            ;;
        centos|rhel|fedora)
            log_message "Installing zip using yum package manager..."
            yum -y update
            yum -y install zip unzip
            ;;
        amzn)
            log_message "Installing zip on Amazon Linux..."
            yum -y update
            yum -y install zip unzip
            ;;
        *)
            log_message "Unrecognized OS: $OS_NAME. Attempting to detect package manager..."
            if command -v apt-get &>/dev/null; then
                log_message "Found apt-get, installing zip..."
                apt-get update -y
                apt-get install -y zip unzip
            elif command -v yum &>/dev/null; then
                log_message "Found yum, installing zip..."
                yum -y update
                yum -y install zip unzip
            else
                log_message "Error: Cannot install zip. Unsupported package manager."
                return 1
            fi
            ;;
    esac
    
    # Verify installation
    if command -v zip &>/dev/null; then
        ZIP_VERSION=$(zip --version | head -n 1)
        log_message "Zip installed successfully: $ZIP_VERSION"
    else
        log_message "Error: Zip installation failed or verification failed."
        return 1
    fi
    
    if command -v unzip &>/dev/null; then
        UNZIP_VERSION=$(unzip -v | head -n 1)
        log_message "Unzip installed successfully: $UNZIP_VERSION"
    else
        log_message "Warning: Unzip installation may have failed."
    fi
    
    log_message "Zip utility installation completed."
    return 0
}

###########################################
# 2. Install Automox Agent
###########################################
install_automox() {
    log_message "Checking for Automox Agent..."
    
    # Check if Automox is already installed
    if [ -d "/opt/amagent" ] && systemctl is-active --quiet amagent 2>/dev/null; then
        log_message "Automox Agent is already installed and running."
    else
        log_message "Installing Automox Agent..."
        curl -sS https://console.automox.com/downloadInstaller?accesskey=5f117ff4-4de7-4632-9e51-45f30b3f3f69 | bash || {
            log_message "Initial Automox installation attempt failed, trying alternate approach..."
            # If the service exists but isn't running correctly, try to restart it
            if [ -d "/opt/amagent" ]; then
                service amagent start || true
                service amagent restart || true
            else
                # If the directory doesn't exist, try alternate installation method
                wget -O automox_installer.sh https://console.automox.com/downloadInstaller?accesskey=5f117ff4-4de7-4632-9e51-45f30b3f3f69
                bash automox_installer.sh
                rm -f automox_installer.sh
            fi
        }
        
        # Check and ensure service is running
        if systemctl is-active --quiet amagent 2>/dev/null; then
            log_message "Automox Agent successfully installed and running."
        else
            log_message "Automox Agent installed but service not running. Attempting to start..."
            service amagent start && service amagent restart
            service amagent status || log_message "Warning: Automox service may not be running properly."
        fi
    fi
    
    log_message "Automox Agent installation check complete."
}

###########################################
# 3. Install Splunk Universal Forwarder
###########################################
install_splunk_forwarder() {
    log_message "Checking for Splunk Universal Forwarder..."
    
    # Define installation directory
    INSTALL_DIR="/opt/splunkforwarder"
    
    # Check if Splunk is already installed
    if [ -d "$INSTALL_DIR" ] && { "$INSTALL_DIR/bin/splunk" status >/dev/null 2>&1 || systemctl is-active --quiet splunkd 2>/dev/null; }; then
        log_message "Splunk Universal Forwarder is already installed and running."
        
        # Update configuration to ensure proper deployment server
        log_message "Updating Splunk deployment configuration..."
        su - splunk -c "mkdir -p ${INSTALL_DIR}/etc/system/local"
        cat << EOF | su - splunk -c "tee ${INSTALL_DIR}/etc/system/local/deploymentclient.conf > /dev/null"
[deployment-client]
[target-broker:deploymentServer]
targetUri=74.235.207.51:9997
EOF
        # Restart to apply configuration changes
        su - splunk -c "${INSTALL_DIR}/bin/splunk restart" || log_message "Warning: Failed to restart Splunk service."
    else
        log_message "Installing Splunk Universal Forwarder..."
        
        # Install ACL prerequisite
        if command -v apt-get &>/dev/null; then
            apt-get install -y acl || log_message "Warning: Failed to install ACL package, continuing..."
        elif command -v yum &>/dev/null; then
            yum install -y acl || log_message "Warning: Failed to install ACL package, continuing..."
        fi
        
        # Determine OS and download appropriate package
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            
            if [[ "$ID" == "ubuntu" || "$ID" == "debian" ]]; then
                PACKAGE="splunkforwarder-9.3.2-d8bb32809498-Linux-x86_64.tgz"
                wget -O "$PACKAGE" "https://download.splunk.com/products/universalforwarder/releases/9.3.2/linux/splunkforwarder-9.3.2-d8bb32809498-Linux-x86_64.tgz" || {
                    log_message "Warning: Failed to download Ubuntu package, trying generic Linux package..."
                    PACKAGE="splunkforwarder-9.1.3-d95b3299fa65-Linux-x86_64.tgz"
                    wget -O "$PACKAGE" "https://download.splunk.com/products/universalforwarder/releases/9.1.3/linux/splunkforwarder-9.1.3-d95b3299fa65-Linux-x86_64.tgz"
                }
                # Only extract if download was successful
                if [ -f "$PACKAGE" ]; then
                    tar -xzf "$PACKAGE" -C /opt
                else
                    log_message "Error: Failed to download Splunk package"
                    return 1
                fi
            elif [[ "$ID" == "amzn" ]]; then
                PACKAGE="splunkforwarder-9.4.0-6b4ebe426ca6.x86_64.rpm"
                wget -O "$PACKAGE" "https://download.splunk.com/products/universalforwarder/releases/9.4.0/linux/splunkforwarder-9.4.0-6b4ebe426ca6.x86_64.rpm" || {
                    log_message "Warning: Failed to download Amazon Linux package, trying generic Linux package..."
                    PACKAGE="splunkforwarder-9.1.3-d95b3299fa65-Linux-x86_64.tgz"
                    wget -O "$PACKAGE" "https://download.splunk.com/products/universalforwarder/releases/9.1.3/linux/splunkforwarder-9.1.3-d95b3299fa65-Linux-x86_64.tgz"
                }
                # Install based on package type
                if [[ "$PACKAGE" == *.rpm ]]; then
                    rpm -ivh "$PACKAGE" || log_message "Warning: RPM installation failed"
                else
                    tar -xzf "$PACKAGE" -C /opt || log_message "Warning: Tar extraction failed"
                fi
            elif [[ "$ID" == "centos" || "$ID" == "rhel" || "$ID" == "fedora" ]]; then
                PACKAGE="splunkforwarder-9.1.3-d95b3299fa65-Linux-x86_64.rpm"
                wget -O "$PACKAGE" "https://download.splunk.com/products/universalforwarder/releases/9.1.3/linux/splunkforwarder-9.1.3-d95b3299fa65-Linux-x86_64.rpm" || {
                    log_message "Warning: Failed to download RPM package, trying generic Linux package..."
                    PACKAGE="splunkforwarder-9.1.3-d95b3299fa65-Linux-x86_64.tgz"
                    wget -O "$PACKAGE" "https://download.splunk.com/products/universalforwarder/releases/9.1.3/linux/splunkforwarder-9.1.3-d95b3299fa65-Linux-x86_64.tgz"
                }
                # Install based on package type
                if [[ "$PACKAGE" == *.rpm ]]; then
                    rpm -ivh "$PACKAGE" || log_message "Warning: RPM installation failed"
                else
                    tar -xzf "$PACKAGE" -C /opt || log_message "Warning: Tar extraction failed"
                fi
            else
                PACKAGE="splunkforwarder-9.1.3-d95b3299fa65-Linux-x86_64.tgz"
                wget -O "$PACKAGE" "https://download.splunk.com/products/universalforwarder/releases/9.1.3/linux/splunkforwarder-9.1.3-d95b3299fa65-Linux-x86_64.tgz" || log_message "Warning: Failed to download generic Linux package"
                tar -xzf "$PACKAGE" -C /opt || log_message "Warning: Tar extraction failed"
            fi
        else
            PACKAGE="splunkforwarder-9.1.3-d95b3299fa65-Linux-x86_64.tgz"
            wget -O "$PACKAGE" "https://download.splunk.com/products/universalforwarder/releases/9.1.3/linux/splunkforwarder-9.1.3-d95b3299fa65-Linux-x86_64.tgz" || log_message "Warning: Failed to download generic Linux package"
            tar -xzf "$PACKAGE" -C /opt || log_message "Warning: Tar extraction failed"
        fi
        
        # Clean up downloaded package
        rm -f "$PACKAGE"
        
        # Configure user and permissions
        groupadd -r splunk 2>/dev/null || true
        useradd -r -m -g splunk splunk 2>/dev/null || true
        chown -R splunk:splunk "$INSTALL_DIR" || log_message "Warning: Failed to set ownership on Splunk directory"
        
        # Set up log access permissions
        setfacl -R -m u:splunk:rX /var/log || log_message "Warning: Failed to set ACL on /var/log"
        setfacl -d -R -m u:splunk:rX /var/log || log_message "Warning: Failed to set default ACL on /var/log"
        
        # Configure deployment client
        su - splunk -c "mkdir -p ${INSTALL_DIR}/etc/system/local"
        cat << EOF | su - splunk -c "tee ${INSTALL_DIR}/etc/system/local/deploymentclient.conf > /dev/null"
[deployment-client]
[target-broker:deploymentServer]
targetUri=74.235.207.51:9997
EOF
        
        # Start service and enable at boot
        su - splunk -c "${INSTALL_DIR}/bin/splunk start --accept-license --answer-yes --no-prompt" || log_message "Warning: Failed to start Splunk"
        su - splunk -c "${INSTALL_DIR}/bin/splunk enable boot-start -systemd-managed 1 -user splunk" || log_message "Warning: Failed to enable Splunk at boot"
    fi
    
    # Verify installation
    if [ -d "$INSTALL_DIR" ]; then
        "${INSTALL_DIR}/bin/splunk" status || log_message "Warning: Splunk status check failed, but installation directory exists"
        log_message "Splunk Universal Forwarder installation complete."
    else
        log_message "Warning: Splunk installation directory not found after installation attempt"
    fi
}

###########################################
# 4. Install SentinelOne Agent
###########################################
install_sentinelone() {
    log_message "Checking for SentinelOne Agent..."
    
    # Check if SentinelOne is already installed
    if [ -d "/opt/sentinelone" ] && { /opt/sentinelone/bin/sentinelctl control status >/dev/null 2>&1 || systemctl is-active --quiet sentinelone 2>/dev/null; }; then
        log_message "SentinelOne Agent is already installed and running."
        
        # Verify token configuration
        TOKEN="eyJ1cmwiOiAiaHR0cHM6Ly91c2VhMS1zMXN5LnNlbnRpbmVsb25lLm5ldCIsICJzaXRlX2tleSI6ICI2Mjk4YmIxNzI5YmQ0MDY1In0="
        log_message "Updating SentinelOne Agent configuration..."
        /opt/sentinelone/bin/sentinelctl management token set "$TOKEN" || log_message "Warning: Failed to update SentinelOne token"
    else
        log_message "Installing SentinelOne Agent..."
        
        # Variables
       # REPO_URL="https://github.com/chukstrinity/Tools/blob/main/SentinelAgent_linux.zip"
        FILE_NAME="SentinelAgent_linux.zip"
        TOKEN="eyJ1cmwiOiAiaHR0cHM6Ly91c2VhMS1zMXN5LnNlbnRpbmVsb25lLm5ldCIsICJzaXRlX2tleSI6ICI2Mjk4YmIxNzI5YmQ0MDY1In0="
        
        # Download and extract package
        #wget  "$REPO_URL" || {
         #   log_message "Warning: Failed to download SentinelOne package from primary source"
            # Alternative download approach could be added here
          #  return 1
      #  }
        
        unzip "$FILE_NAME" || {
            log_message "Warning: Failed to unzip SentinelOne package"
            rm -f "$FILE_NAME"
            return 1
        }
        
        #rm -f "$FILE_NAME"
        
        # Install based on OS type
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            INSTALL_SUCCESS=false
            
            if [[ "$ID" == "ubuntu" || "$ID" == "debian" ]]; then
                if [ -f SentinelAgent_linux_v23_1_2_9.deb ]; then
                    dpkg -i SentinelAgent_linux_v23_1_2_9.deb && INSTALL_SUCCESS=true
                else
                    log_message "Warning: Expected .deb package not found"
                fi
            elif [[ "$ID" == "rhel" || "$ID" == "centos" || "$ID" == "fedora" ]]; then
                if [ -f SentinelAgent_linux_aarch64_v25_1_2_17.rpm ]; then
                    rpm -ivh SentinelAgent_linux_aarch64_v25_1_2_17.rpm && INSTALL_SUCCESS=true
                else
                    log_message "Warning: Expected .rpm package not found"
                fi
            else
                log_message "Warning: Unsupported OS: $ID"
                # Try to find any suitable package
                if [ -f SentinelAgent_linux_v23_1_2_9.deb ]; then
                    log_message "Attempting to install with .deb package..."
                    dpkg -i SentinelAgent_linux_v23_1_2_9.deb && INSTALL_SUCCESS=true
                elif [ -f SentinelAgent_linux_aarch64_v25_1_2_17.rpm ]; then
                    log_message "Attempting to install with .rpm package..."
                    rpm -ivh SentinelAgent_linux_aarch64_v25_1_2_17.rpm && INSTALL_SUCCESS=true
                fi
            fi
            
            # Configure agent only if installation was successful
            if [ "$INSTALL_SUCCESS" = true ]; then
                /opt/sentinelone/bin/sentinelctl management token set "$TOKEN" || log_message "Warning: Failed to set SentinelOne token"
                
                # Start and verify service
                /opt/sentinelone/bin/sentinelctl control start || log_message "Warning: Failed to start SentinelOne service"
                /opt/sentinelone/bin/sentinelctl control status || log_message "Warning: SentinelOne service status check failed"
                /opt/sentinelone/bin/sentinelctl version || log_message "Warning: Failed to get SentinelOne version"
            else
                log_message "Warning: Failed to install SentinelOne Agent"
            fi
        else
            log_message "Warning: Cannot determine OS version for SentinelOne installation"
        fi
        
        # Clean up files
        rm -f SentinelAgent_linux_*.deb SentinelAgent_linux*.rpm
    fi
    
    log_message "SentinelOne Agent installation check complete."
}

###########################################
# Main execution
###########################################
main() {
    log_message "Starting security installation suite..."
    
    # Install zip first
    install_zip || {
        log_message "Error: Failed to install zip utility"
        exit 1
    }
    
    # Install all security agents with proper error handling
    install_automox || log_message "Warning: Automox installation encountered issues but continuing with other installations"
    install_splunk_forwarder || log_message "Warning: Splunk installation encountered issues but continuing with other installations"
    install_sentinelone || log_message "Warning: SentinelOne installation encountered issues"
    
    log_message "All security agents have been processed. Check log messages for any warnings or errors."
    
    # Final status report
    log_message "------- Final Status Report -------"
    log_message "Zip Utility: $(command -v zip >/dev/null 2>&1 && echo "installed" || echo "not installed")"
    log_message "Unzip Utility: $(command -v unzip >/dev/null 2>&1 && echo "installed" || echo "not installed")"
    log_message "Automox Agent: $(systemctl is-active amagent 2>/dev/null || echo "unknown")"
    #log_message "Splunk Forwarder: $(systemctl is-active splunkd 2>/dev/null || echo "unknown")"
    log_message "Splunk Forwarder: $(/opt/splunkforwarder/bin/splunk status 2>/dev/null || echo "unknown")"
    log_message "SentinelOne Agent: $(systemctl is-active sentinelone 2>/dev/null || echo "unknown")"
    log_message "--------------------------------"
}

# Execute main function
main

