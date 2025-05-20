#!/bin/bash

echo "Installing Automox Agent Now"
# Install Automox agent
curl -sS https://console.automox.com/downloadInstaller?accesskey=5f117ff4-4de7-4632-9e51-45f30b3f3f69 | sudo bash

# Check the status of the Automox agent service
sudo service amagent status

# Start and restart the Automox agent service
sudo service amagent start && sudo service amagent restart

echo "Automox agent installation and service management complete."


####### Install Splunk forwarder
echo "Installing Splunk forwarder now"

# Install ACL module
echo "Installing ACL..."
sudo apt install -y acl

# Define installation directory
INSTALL_DIR="/opt/splunkforwarder"

# Download the appropriate Splunk Universal Forwarder package
echo "Downloading Splunk Universal Forwarder..."
if [[ "$(grep -i ubuntu /etc/os-release)" ]]; then
    wget -O splunkforwarder-9.3.2-d8bb32809498-Linux-x86_64.tgz "https://download.splunk.com/products/universalforwarder/releases/9.3.2/linux/splunkforwarder-9.3.2-d8bb32809498-Linux-x86_64.tgz"
    PACKAGE="splunkforwarder-9.3.2-d8bb32809498-Linux-x86_64.tgz"
elif [[ "$(grep -i amzn /etc/os-release)" ]]; then
    wget -O splunkforwarder-9.4.0-6b4ebe426ca6.x86_64.rpm "https://download.splunk.com/products/universalforwarder/releases/9.4.0/linux/splunkforwarder-9.4.0-6b4ebe426ca6.x86_64.rpm"
    PACKAGE="splunkforwarder-9.4.0-6b4ebe426ca6.x86_64.rpm"
else
    wget -O splunkforwarder-9.1.3-d95b3299fa65-Linux-x86_64.tgz "https://download.splunk.com/products/universalforwarder/releases/9.1.3/linux/splunkforwarder-9.1.3-d95b3299fa65-Linux-x86_64.tgz"
    PACKAGE="splunkforwarder-9.1.3-d95b3299fa65-Linux-x86_64.tgz"
fi

# Install the package based on OS type
echo "Installing Splunk Universal Forwarder..."
if [[ "$PACKAGE" == *.tgz ]]; then
    sudo tar -xzvf "$PACKAGE" -C /opt
elif [[ "$PACKAGE" == *.rpm ]]; then
    sudo rpm -ivh "$PACKAGE"
fi

# Clean up downloaded file
rm -f "$PACKAGE"

# Ensure Splunk user and group exist
sudo groupadd -r splunk 2>/dev/null
sudo useradd -r -m -g splunk splunk 2>/dev/null
sudo chown -R splunk:splunk /opt/splunkforwarder

# Grant Splunk user read access to /var/log
sudo setfacl -R -m u:splunk:rX /var/log
sudo setfacl -d -R -m u:splunk:rX /var/log

# Create deploymentclient.conf with deployment server info
DEPLOYMENT_CONF="${INSTALL_DIR}/etc/system/local/deploymentclient.conf"
sudo -u splunk mkdir -p "$(dirname "${DEPLOYMENT_CONF}")"
sudo -u splunk bash -c "cat <<EOF > ${DEPLOYMENT_CONF}
[deployment-client]
[target-broker:deploymentServer]
targetUri=74.235.207.51:8089
EOF"

# Set correct ownership for deployment configuration
sudo chown splunk:splunk "${DEPLOYMENT_CONF}"

# Start Splunk Universal Forwarder
echo "Starting Splunk Universal Forwarder..."
sudo -u splunk "${INSTALL_DIR}/bin/splunk" start --accept-license --answer-yes --no-prompt

# Enable auto-start at boot
sudo -u splunk "${INSTALL_DIR}/bin/splunk" enable boot-start

echo "Splunk Universal Forwarder installation and setup completed!"

# Verify installation
sudo /opt/splunkforwarder/bin/splunk status

# Monitor logs for 1 minute, then terminate
echo "Monitoring logs for 1 minute..."
timeout 60 sudo tail -f /opt/splunkforwarder/var/log/splunk/splunkd.log
echo "Log monitoring complete."




#### Install Sentinel One Agent

echo "Installing Sentinel One Agent now"

# Variables
REPO_URL="https://github.com/chukstrinity/Tools/blob/main/SentinelAgent_linux.zip"
FILE_NAME="SentinelAgent_linux.zip"
TOKEN="eyJ1cmwiOiAiaHR0cHM6Ly91c2VhMS1zMXN5LnNlbnRpbmVsb25lLm5ldCIsICJzaXRlX2tleSI6ICI2Mjk4YmIxNzI5YmQ0MDY1In0="

# Download the package
echo "Downloading SentinelOne agent..."
wget -O $FILE_NAME $REPO_URL

# Unzip the package
echo "Extracting package..."
unzip $FILE_NAME
rm -f $FILE_NAME

# Detect OS and install the package
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ "$ID" == "ubuntu" || "$ID" == "debian" ]]; then
        echo "Installing SentinelOne agent on Ubuntu/Debian..."
        sudo dpkg -i SentinelAgent_linux_v23_1_2_9.deb
    elif [[ "$ID" == "rhel" || "$ID" == "centos" || "$ID" == "fedora" ]]; then
        echo "Installing SentinelOne agent on RHEL/CentOS/Fedora..."
        sudo rpm -ivh SentinelAgent_linux_aarch64_v25_1_2_17.rpm
    else
        echo "Unsupported OS detected: $ID"
        exit 1
    fi
else
    echo "Cannot determine OS version."
    exit 1
fi

# Configure SentinelOne agent
echo "Setting up SentinelOne agent..."
sudo /opt/sentinelone/bin/sentinelctl management token set "$TOKEN"

# Clean up unnecessary files
rm -rf SentinelAgent_linux_*.deb SentinelAgent_linux*.rpm

# Start and verify SentinelOne agent
echo "Starting SentinelOne agent..."
sudo /opt/sentinelone/bin/sentinelctl control start

echo "Checking agent status..."
sudo /opt/sentinelone/bin/sentinelctl control status

echo "Checking agent version..."
sudo /opt/sentinelone/bin/sentinelctl version

echo "SentinelOne agent installation and configuration complete!"


