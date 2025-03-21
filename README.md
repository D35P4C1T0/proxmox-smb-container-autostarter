---

# Proxmox SMB Container Autostarter

Automatically starts Proxmox containers tagged with "smb" after TrueNAS VM and SMB shares are available.

## Features
- ✅ Waits for TrueNAS VM to fully initialize
- ✅ Verifies SMB share availability using smbclient
- 🔒 Secure credential handling via authentication file
- ⏳ Configurable timeouts and retry intervals
- 📊 Detailed logging to `/var/log/smb-autostart.log`
- 🐋 Container network readiness checks

## Installation

### Prerequisites
- Proxmox VE 7+
- TrueNAS VM with SMB shares
- `smbclient` installed (`apt install smbclient`)

### Quick Setup
```bash
# Clone repository
git clone https://github.com/yourusername/proxmox-smb-autostart.git
cd proxmox-smb-autostart

# Install script and service
sudo cp src/start-smb-containers.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/start-smb-containers.sh

sudo cp systemd/start-smb-containers.service /etc/systemd/system/

# Create credentials file (edit with your values)
sudo cp docs/credentials.example /root/.smbcredentials
sudo chmod 600 /root/.smbcredentials
sudo nano /root/.smbcredentials
```

# Enable service
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now start-smb-containers.service
```

### Script Configuration (Edit before installation)

```bash
# Main configuration variables
TRUENAS_VMID=110                   # Your TrueNAS VM ID
TRUENAS_IP="192.168.1.100"        # TrueNAS server IP
SMB_SHARE_NAME="media"            # SMB share to monitor
MAX_WAIT=300                      # Maximum wait time in seconds
SLEEP_INTERVAL=5                  # Check interval in seconds
```

### Verification

```bash
# Check service status
systemctl status start-smb-containers.service

# Test SMB connectivity
smbclient -L //${TRUENAS_IP} --authentication-file=/root/.smbcredentials

# View logs
journalctl -u start-smb-containers.service -f
tail -f /var/log/smb-autostart.log
```


### Systemd Service
The service runs with:

- Dependencies: network.target pve-storage.target pve-guests.target
- Timeout: 400 seconds
- Logging: Combined systemd journal and file logging


### Security Considerations

1. Keep credentials file permission strict
```bash
sudo chmod 600 /root/.smbcredentials
```
2. Use read-only SMB credentials if possible
3. Regularly rotate SMB credentials
4. Monitor access to credentials file
5. Review logs regularly via /var/log/smb-autostart.log
