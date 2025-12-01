#!/bin/bash

# Enable strict error handling
set -euo pipefail

# Configuration defaults
TRUENAS_VMID="${TRUENAS_VMID:-110}"
TRUENAS_IP="${TRUENAS_IP:-192.168.1.100}"
SMB_SHARE_NAME="${SMB_SHARE_NAME:-media}"
CREDENTIALS_FILE="${CREDENTIALS_FILE:-/root/.smbcredentials}"
CONTAINER_CONFIG_DIR="${CONTAINER_CONFIG_DIR:-/etc/pve/lxc}"
VM_MAX_WAIT="${VM_MAX_WAIT:-300}"              # 5 minutes for VM
SMB_MAX_WAIT="${SMB_MAX_WAIT:-300}"            # 5 minutes for SMB
NETWORK_MAX_WAIT="${NETWORK_MAX_WAIT:-60}"     # 1 minute for network
SLEEP_INTERVAL="${SLEEP_INTERVAL:-5}"
NETWORK_CHECK_TARGET="${NETWORK_CHECK_TARGET:-8.8.8.8}"
LOG_FILE="${LOG_FILE:-/var/log/smb-autostart.log}"

# Load configuration from file if it exists
CONFIG_FILE="${CONFIG_FILE:-/etc/smb-autostart.conf}"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# Logging function with timestamp
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

log_info() {
    log "INFO" "$@"
}

log_error() {
    log "ERROR" "$@" >&2
}

log_warn() {
    log "WARN" "$@"
}

# Check for required utilities
verify_dependencies() {
    local missing_deps=()
    
    for cmd in smbclient pct qm; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing required utilities: ${missing_deps[*]}"
        log_error "Install with: apt install smbclient"
        log_error "pct and qm should be available in Proxmox VE environment"
        exit 1
    fi
    
    # Verify Proxmox environment
    if [[ ! -d "$CONTAINER_CONFIG_DIR" ]]; then
        log_error "Container config directory not found: $CONTAINER_CONFIG_DIR"
        log_error "This script must run on a Proxmox VE host"
        exit 1
    fi
    
    log_info "All dependencies verified"
}

# Validate credentials file
check_credentials() {
    if [[ ! -f "$CREDENTIALS_FILE" ]]; then
        log_error "Credentials file not found: $CREDENTIALS_FILE"
        log_error "Create it from: docs/credentials.example"
        exit 1
    fi
    
    # Check file permissions (should be 600)
    local perms
    perms=$(stat -c "%a" "$CREDENTIALS_FILE" 2>/dev/null || stat -f "%OLp" "$CREDENTIALS_FILE" 2>/dev/null || echo "000")
    if [[ "$perms" != "600" ]]; then
        log_warn "Credentials file permissions are $perms (recommended: 600)"
        log_warn "Fix with: chmod 600 $CREDENTIALS_FILE"
    fi
    
    if [[ ! -r "$CREDENTIALS_FILE" ]]; then
        log_error "Insufficient permissions to read credentials file"
        exit 1
    fi
    
    if ! grep -q "^username" "$CREDENTIALS_FILE" || ! grep -q "^password" "$CREDENTIALS_FILE"; then
        log_error "Credentials file missing username or password entry"
        log_error "Format: username = your_user"
        log_error "        password = your_password"
        exit 1
    fi
    
    log_info "Credentials file validated"
}

# Wait for TrueNAS VM to reach running state
wait_for_truenas() {
    local waited=0
    
    log_info "Waiting for TrueNAS VM (${TRUENAS_VMID}) to start..."
    
    while :; do
        local vm_status
        vm_status=$(qm status "$TRUENAS_VMID" 2>/dev/null | awk '{print $2}' || echo "unknown")
        
        case "$vm_status" in
            "running")
                log_info "TrueNAS VM (${TRUENAS_VMID}) is running"
                return 0
                ;;
            "stopped")
                log_warn "TrueNAS VM (${TRUENAS_VMID}) is stopped"
                ;;
            "unknown")
                log_warn "Could not determine TrueNAS VM status"
                ;;
        esac
        
        if (( waited >= VM_MAX_WAIT )); then
            log_error "Timeout reached waiting for TrueNAS VM (${waited}s)"
            return 1
        fi
        
        if (( waited % 30 == 0 )); then
            log_info "Still waiting for TrueNAS VM... (${waited}/${VM_MAX_WAIT}s)"
        fi
        
        (( waited += SLEEP_INTERVAL )) || true
        sleep "$SLEEP_INTERVAL"
    done
}

# Wait for SMB shares to become available
wait_for_smb_shares() {
    local waited=0
    
    log_info "Waiting for SMB share '${SMB_SHARE_NAME}' on ${TRUENAS_IP}..."
    
    while :; do
        # Use // prefix for IP address and remove --machine-pass flag
        # Capture both stdout and stderr to check for errors
        local smb_output
        local smb_exit_code
        
        smb_output=$(smbclient -L "//${TRUENAS_IP}" \
            --authentication-file="$CREDENTIALS_FILE" \
            2>&1)
        smb_exit_code=$?
        
        # Check if the share name appears in the output
        if echo "$smb_output" | grep -q "$SMB_SHARE_NAME"; then
            log_info "SMB share '${SMB_SHARE_NAME}' is available"
            return 0
        fi
        
        # Log error details if smbclient failed (but not on every iteration)
        if (( smb_exit_code != 0 )) && (( waited % 30 == 0 )); then
            log_warn "smbclient returned exit code ${smb_exit_code}"
            log_warn "Last error output: $(echo "$smb_output" | tail -3)"
        fi
        
        if (( waited >= SMB_MAX_WAIT )); then
            log_error "Timeout reached waiting for SMB shares (${waited}s)"
            log_error "Verify SMB share name and network connectivity"
            log_error "Last smbclient output:"
            echo "$smb_output" | while IFS= read -r line; do
                log_error "  $line"
            done
            return 1
        fi
        
        if (( waited % 30 == 0 )); then
            log_info "Still waiting for SMB shares... (${waited}/${SMB_MAX_WAIT}s)"
        fi
        
        (( waited += SLEEP_INTERVAL )) || true
        sleep "$SLEEP_INTERVAL"
    done
}

# Wait for container network to be ready
wait_for_container_network() {
    local vmid="$1"
    local waited=0
    
    log_info "Waiting for container ${vmid} network to be ready..."
    
    while (( waited < NETWORK_MAX_WAIT )); do
        if pct exec "$vmid" -- ping -c1 -W1 "$NETWORK_CHECK_TARGET" &>/dev/null; then
            log_info "Container ${vmid} network is ready"
            return 0
        fi
        
        sleep 1
        (( waited += 1 )) || true
    done
    
    log_warn "Container ${vmid} network check timeout (${waited}s), but continuing..."
    return 0  # Don't fail if network check times out
}

# Get container status
get_container_status() {
    local vmid="$1"
    pct status "$vmid" 2>/dev/null | awk '{print $2}' || echo "unknown"
}

# Start a container and verify it's running
start_container() {
    local vmid="$1"
    local status
    
    status=$(get_container_status "$vmid")
    
    case "$status" in
        "running")
            log_info "Container ${vmid} is already running"
            return 0
            ;;
        "stopped")
            log_info "Starting container ${vmid}"
            if ! pct start "$vmid"; then
                log_error "Failed to start container ${vmid}"
                return 1
            fi
            
            # Wait a moment for container to initialize
            sleep 2
            
            # Verify container started successfully
            local max_verify_wait=30
            local verify_waited=0
            while (( verify_waited < max_verify_wait )); do
                status=$(get_container_status "$vmid")
                if [[ "$status" == "running" ]]; then
                    log_info "Container ${vmid} started successfully"
                    wait_for_container_network "$vmid"
                    return 0
                fi
                sleep 1
                (( verify_waited += 1 )) || true
            done
            
            log_error "Container ${vmid} did not reach running state"
            return 1
            ;;
        "unknown")
            log_error "Could not determine status of container ${vmid}"
            return 1
            ;;
        *)
            log_warn "Container ${vmid} is in state: ${status}"
            return 0
            ;;
    esac
}

# Main execution
main() {
    log_info "=== Starting SMB container autostart sequence ==="
    
    # Preliminary checks
    verify_dependencies
    check_credentials
    
    # Wait for TrueNAS VM first
    if ! wait_for_truenas; then
        log_error "TrueNAS VM did not start properly"
        exit 1
    fi
    
    # Wait for SMB shares to become available
    if ! wait_for_smb_shares; then
        log_error "SMB shares did not become available"
        exit 1
    fi
    
    # Find and start SMB containers
    local containers_found=0
    local containers_started=0
    local containers_failed=0
    
    log_info "Scanning for containers with 'smb' tag..."
    
    for config in "${CONTAINER_CONFIG_DIR}"/*.conf; do
        # Handle case where no .conf files exist
        [[ -f "$config" ]] || continue
        
        local vmid
        vmid=$(basename "${config}" .conf)
        
        # Skip if vmid is not numeric (invalid config file)
        [[ "$vmid" =~ ^[0-9]+$ ]] || continue
        
        if grep -q -E '^tags:\s.*\bsmb\b' "$config"; then
            (( containers_found++ )) || true
            log_info "Found SMB container: ${vmid}"
            
            if start_container "$vmid"; then
                (( containers_started++ )) || true
            else
                (( containers_failed++ )) || true
            fi
        fi
    done
    
    log_info "=== Autostart sequence completed ==="
    log_info "Containers found: ${containers_found}, started: ${containers_started}, failed: ${containers_failed}"
    
    if (( containers_failed > 0 )); then
        log_error "Some containers failed to start"
        exit 1
    fi
    
    exit 0
}

# Run main function
main "$@"
