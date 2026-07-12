# Proxmox Share Container Autostarter

Wait for one SMB or NFS share, then start every **local** LXC carrying an exact
`smb` tag. Designed for Proxmox VE 8 and 9.

This is useful when an LXC bind-mounts storage supplied by a NAS VM: ordinary
boot ordering only knows that the NAS guest started, not that its share is ready.

## Install

Run on each Proxmox node which owns matching containers:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/D35P4C1T0/proxmox-smb-container-autostarter/main/install.sh)"
```

Installer opens guided terminal UI. Choose SMB or NFS, enter share address, tag,
optional provider guest, timeout, and SMB credentials. It installs dependencies,
writes configuration, then enables service. Existing installs offer either
reconfiguration or program-only update.

Generated `/etc/share-autostart.conf` resembles:

```bash
PROTOCOL="smb"
SHARE_HOST="192.168.1.100"
SHARE_NAME="media"
TAG="smb"

# Optional: NAS VM or LXC on this node. Empty means external NAS.
SOURCE_VMID="110"
SOURCE_TYPE="qemu"

# Empty enables SMB guest access.
CREDENTIALS_FILE="/root/.smbcredentials"
MAX_WAIT=600
```

SMB credentials entered in UI are written automatically with mode `0600`. Manual
alternative:

```bash
install -m 600 /dev/null /root/.smbcredentials
printf 'username=YOUR_USER\npassword=YOUR_PASSWORD\n' > /root/.smbcredentials
```

For NFS:

```bash
PROTOCOL="nfs"
SHARE_HOST="192.168.1.100"
SHARE_NAME="/mnt/tank/media"
CREDENTIALS_FILE=""
```

Apply later manual configuration changes:

```bash
systemctl restart share-autostart.service
journalctl -u share-autostart.service -f
```

Installer preserves an existing `/etc/share-autostart.conf` during upgrades.

## Tag containers

Use Proxmox CLI or GUI:

```bash
pct set 101 --tags smb
```

Multiple tags use semicolons, for example `media;smb`. Matching is exact and
case-sensitive. Only containers returned by the current node's `pct list` are
started, so clustered nodes cannot accidentally start each other's containers.

Disable Proxmox's normal autostart for managed containers; otherwise
`pve-guests.service` can start them before the share is ready:

```bash
pct set 101 --onboot 0
```

Keep the NAS VM's `onboot` enabled when it runs inside Proxmox.

## Operation

The service starts after `pve-guests.service`, waits until the optional provider
guest is running, then probes the exact share:

- SMB: opens `//HOST/SHARE` using `smbclient`.
- NFS: checks an exact export path using `showmount`.

Failures are retried by systemd after 30 seconds. Boot wait has no systemd-level
timeout; `MAX_WAIT` controls each attempt. Logs go to the journal.

Test without starting containers:

```bash
DRY_RUN=1 /usr/local/sbin/proxmox-share-autostart
```

## Troubleshooting

```bash
systemctl status share-autostart.service
journalctl -b -u share-autostart.service
smbclient //192.168.1.100/media -A /root/.smbcredentials -c quit
showmount -e 192.168.1.100
pct list
pct config 101 | grep '^tags:'
```

Common causes: managed LXC still has `onboot=1`, wrong exact share/export name,
credentials unreadable by root, provider VM not configured for autostart, or
service installed on a cluster node which does not own the LXC.

## Remove

```bash
systemctl disable --now share-autostart.service
rm /etc/systemd/system/share-autostart.service /usr/local/sbin/proxmox-share-autostart
systemctl daemon-reload
```

Configuration and SMB credentials remain untouched.
