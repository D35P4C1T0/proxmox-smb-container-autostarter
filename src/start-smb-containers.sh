#!/bin/bash

# Configuration
TRUENAS_VMID=110
TRUENAS_IP="192.168.1.100"          # Replace with your TrueNAS IP
SMB_SHARE_NAME="media"              # Replace with your share name
CREDENTIALS_FILE="/root/.smbcredentials"
MEDIA_MOUNT="/mnt/pve/media"
CONTAINER_CONFIG_DIR="/etc/pve/lxc"
MAX_WAIT=300                       # 5 minutes maximum wait time
SLEEP_INTERVAL=5

# Check for required smbclient utility
verify_dependencies() {
    if ! command -v smbclient &> /dev/null; then
        echo "Error: smbclient not found. Install with 'apt install smbclient'"
        exit 1
    fi
}

# Validate credentials file
check_credentials() {
    if [ ! -f "$CREDENTIALS_FILE" ]; then
        echo "Error: Credentials file $CREDENTIALS_FILE not found"
        exit 1
    fi

    if [ ! -r "$CREDENTIALS_FILE" ]; then
        echo "Error: Insufficient permissions to read credentials file"
        exit 1
    fi

    if ! grep -q "^username" "$CREDENTIALS_FILE" || ! grep -q "^password" "$CREDENTIALS_FILE"; then
        echo "Error: Credentials file missing username or password entry"
        exit 1
    fi
}

# Wait for TrueNAS VM to reach running state
wait_for_truenas() {
    local waited=0
    while :; do
        vm_status=$(qm status $TRUENAS_VMID 2>/dev/null | awk '{print $2}')
        if [[ "$vm_status" == "running" ]]; then
            echo "TrueNAS VM (${TRUENAS_VMID}) is running"
            return 0
        fi
        
        if (( waited >= MAX_WAIT )); then
            echo "Timeout reached waiting for TrueNAS VM"
            return 1
        fi
        
        echo "Waiting for TrueNAS VM (${TRUENAS_VMID}) to start... (${waited}/${MAX_WAIT}s)"
        (( waited += SLEEP_INTERVAL ))
        sleep $SLEEP_INTERVAL
    done
}

# Wait for SMB shares to become available
wait_for_smb_shares() {
    local waited=0
    
    while :; do
        if smbclient -L "$TRUENAS_IP" \
            --authentication-file="$CREDENTIALS_FILE" \
            --machine-pass 2>/dev/null | grep -q "$SMB_SHARE_NAME"; then
            echo "SMB share '${SMB_SHARE_NAME}' is available"
            return 0
        fi
        
        if (( waited >= MAX_WAIT )); then
            echo "Timeout reached waiting for SMB shares"
            return 1
        fi
        
        echo "Waiting for SMB shares (${TRUENAS_IP}/${SMB_SHARE_NAME})... (${waited}/${MAX_WAIT}s)"
        (( waited += SLEEP_INTERVAL ))
        sleep $SLEEP_INTERVAL
    done
}

# Main execution
{
    echo "Starting SMB container autostart sequence"
    
    # Preliminary checks
    verify_dependencies
    check_credentials
    
    # Wait for TrueNAS VM first
    if ! wait_for_truenas; then
        echo "Error: TrueNAS VM did not start properly"
        exit 1
    fi
    
    # Wait for SMB shares to become available
    if ! wait_for_smb_shares; then
        echo "Error: SMB shares did not become available"
        exit 1
    fi
    
    # Start SMB containers
    for config in "${CONTAINER_CONFIG_DIR}"/*.conf; do
        vmid=$(basename "${config}" .conf)
        if grep -q -E '^tags:\s.*\bsmb\b' "${config}"; then
            if [[ $(pct status $vmid 2>/dev/null) == "status: stopped" ]]; then
                echo "Starting container ${vmid}"
                pct start "${vmid}"
                echo "Container ${vmid} start command issued"
                # Wait for container network
                until pct exec $vmid -- ping -c1 -W1 8.8.8.8 &>/dev/null; do
                    sleep 1
                done
            else
                echo "Container ${vmid} already running"
            fi
        fi
    done
    
    echo "Autostart sequence completed"
} | tee -a /var/log/smb-autostart.log
