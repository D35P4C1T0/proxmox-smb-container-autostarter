# Proxmox SMB Container Autostarter

Automatically starts Proxmox containers tagged with "smb" after TrueNAS VM and SMB shares are available.

## Features
- ✅ Waits for TrueNAS VM to fully initialize
- ✅ Verifies SMB share availability using smbclient
- 🔒 Secure credential handling via authentication file
- ⏳ Configurable timeouts and retry intervals
- 📊 Detailed logging with timestamps to `/var/log/smb-autostart.log`
- 🐋 Container network readiness checks
- ⚙️ Configuration file support (`/etc/smb-autostart.conf`)
- 🔍 Enhanced error handling and validation
- 📝 Log rotation support

## Installation

### Prerequisites
- Proxmox VE 7+
- TrueNAS VM with SMB shares
- `smbclient` installed (`apt install smbclient`)

### Quick Setup

```bash
# Clone repository
git clone https://github.com/D35P4C1T0/proxmox-smb-container-autostarter.git
cd proxmox-smb-autostart

# Install script and service
sudo cp src/start-smb-containers.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/start-smb-containers.sh

sudo cp systemd/start-smb-containers.service /etc/systemd/system/

# Create credentials file (edit with your values)
sudo cp docs/credentials.example /root/.smbcredentials
sudo chmod 600 /root/.smbcredentials
sudo nano /root/.smbcredentials

# Create configuration file (optional, uses defaults if not present)
sudo cp docs/smb-autostart.conf.example /etc/smb-autostart.conf
sudo nano /etc/smb-autostart.conf

# Install logrotate configuration (optional)
sudo cp systemd/logrotate.conf /etc/logrotate.d/smb-autostart
```

### Enable service

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now start-smb-containers.service
```

### Configuration

The script supports configuration via:
1. **Configuration file** (`/etc/smb-autostart.conf`) - Recommended
2. **Environment variables** - Override config file values
3. **Default values** - Used if neither config file nor env vars are set

#### Configuration File Example

Edit `/etc/smb-autostart.conf`:

```bash
# TrueNAS VM Configuration
TRUENAS_VMID=110
TRUENAS_IP="192.168.1.100"

# SMB Share Configuration
SMB_SHARE_NAME="media"
CREDENTIALS_FILE="/root/.smbcredentials"

# Timeout Configuration (in seconds)
VM_MAX_WAIT=300              # Maximum wait time for TrueNAS VM
SMB_MAX_WAIT=300            # Maximum wait time for SMB shares
NETWORK_MAX_WAIT=60         # Maximum wait time for container network
SLEEP_INTERVAL=5            # Check interval in seconds

# Network Check Configuration
NETWORK_CHECK_TARGET="8.8.8.8"  # Target for network connectivity check
```

#### Container Tagging

To tag a container with "smb", edit the container config file:

```bash
# Edit container config (replace 100 with your container ID)
nano /etc/pve/lxc/100.conf

# Add or modify the tags line:
tags: smb,media
```

### Verification

```bash
# Check service status
systemctl status start-smb-containers.service

# Test SMB connectivity
smbclient -L //192.168.1.100 --authentication-file=/root/.smbcredentials

# View logs
journalctl -u start-smb-containers.service -f
tail -f /var/log/smb-autostart.log
```

### Systemd Service

The service runs with:
- Dependencies: `network.target`, `pve-storage.target`, `pve-guests.target`, `network-online.target`
- Timeout: 400 seconds
- Logging: Combined systemd journal and file logging
- Restart: No (runs once at boot)

### Troubleshooting

#### Service fails to start
- Check that all dependencies are installed: `smbclient`, `pct`, `qm`
- Verify Proxmox environment: `/etc/pve/lxc` directory exists
- Check credentials file permissions: `ls -l /root/.smbcredentials`
- Review logs: `journalctl -u start-smb-containers.service -n 50`

#### Containers not starting
- Verify containers are tagged correctly: `grep -r "tags.*smb" /etc/pve/lxc/`
- Check container status: `pct status <vmid>`
- Verify TrueNAS VM is running: `qm status 110`
- Test SMB connectivity manually: `smbclient -L //<TRUENAS_IP> --authentication-file=/root/.smbcredentials`

#### Timeout issues
- Increase timeout values in `/etc/smb-autostart.conf`
- Check network connectivity between Proxmox and TrueNAS
- Verify TrueNAS VM startup time (may need longer `VM_MAX_WAIT`)

#### Log file issues
- Check log file permissions: `ls -l /var/log/smb-autostart.log`
- Verify logrotate is configured: `logrotate -d /etc/logrotate.d/smb-autostart`
- Check disk space: `df -h /var/log`

### Security Considerations

1. **Keep credentials file permissions strict**
   ```bash
   sudo chmod 600 /root/.smbcredentials
   ```

2. **Use read-only SMB credentials if possible**

3. **Regularly rotate SMB credentials**

4. **Monitor access to credentials file**
   ```bash
   auditctl -w /root/.smbcredentials -p rwxa -k smb_credentials
   ```

5. **Review logs regularly**
   ```bash
   tail -f /var/log/smb-autostart.log
   ```

6. **Restrict configuration file access**
   ```bash
   sudo chmod 600 /etc/smb-autostart.conf
   ```

### Advanced Usage

#### Environment Variable Override

You can override configuration via environment variables:

```bash
TRUENAS_VMID=110 TRUENAS_IP="192.168.1.100" /usr/local/bin/start-smb-containers.sh
```

#### Manual Execution

Run the script manually for testing:

```bash
sudo /usr/local/bin/start-smb-containers.sh
```

#### Dry Run Mode

To test without making changes, you can modify the script temporarily or check container status:

```bash
# List containers with smb tag
grep -l "tags.*smb" /etc/pve/lxc/*.conf | xargs -I {} basename {} .conf

# Check container statuses
for vmid in $(grep -l "tags.*smb" /etc/pve/lxc/*.conf | xargs -I {} basename {} .conf); do
    echo "Container $vmid: $(pct status $vmid)"
done
```
