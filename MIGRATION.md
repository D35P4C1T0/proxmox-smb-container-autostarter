# Migration Guide

## Changes in Improved Version

### Breaking Changes
None - the script maintains backward compatibility with existing configurations.

### New Features

1. **Configuration File Support**
   - New config file: `/etc/smb-autostart.conf`
   - Environment variables still supported
   - Better configuration management

2. **Enhanced Error Handling**
   - Strict error handling with `set -euo pipefail`
   - Proper exit codes
   - Better error messages

3. **Improved Logging**
   - Timestamps in log entries
   - Log levels (INFO, WARN, ERROR)
   - Better structured output

4. **Better Validation**
   - Checks for `pct` and `qm` commands
   - Validates Proxmox environment
   - Enhanced credential file validation

5. **Container State Handling**
   - Proper handling of all container states
   - Verification that containers actually start
   - Better network readiness checks

6. **Separate Timeouts**
   - `VM_MAX_WAIT` - for TrueNAS VM
   - `SMB_MAX_WAIT` - for SMB shares
   - `NETWORK_MAX_WAIT` - for container network

### Migration Steps

#### Option 1: Use Defaults (No Changes Required)
The script will work with existing setup using default values. No changes needed.

#### Option 2: Use Configuration File (Recommended)

1. Create configuration file:
   ```bash
   sudo cp docs/smb-autostart.conf.example /etc/smb-autostart.conf
   ```

2. Edit configuration file with your values:
   ```bash
   sudo nano /etc/smb-autostart.conf
   ```

3. Update script:
   ```bash
   sudo cp src/start-smb-containers.sh /usr/local/bin/
   sudo chmod +x /usr/local/bin/start-smb-containers.sh
   ```

4. Reload systemd:
   ```bash
   sudo systemctl daemon-reload
   ```

#### Option 3: Use Environment Variables

Set environment variables in systemd service file or use existing method.

### Configuration Mapping

| Old Variable | New Variable(s) | Notes |
|-------------|----------------|-------|
| `MAX_WAIT` | `VM_MAX_WAIT`, `SMB_MAX_WAIT` | Split into separate timeouts |
| - | `NETWORK_MAX_WAIT` | New: timeout for network checks |
| - | `NETWORK_CHECK_TARGET` | New: configurable ping target |
| - | `LOG_FILE` | New: configurable log file path |

### Testing After Migration

1. Test script manually:
   ```bash
   sudo /usr/local/bin/start-smb-containers.sh
   ```

2. Check logs:
   ```bash
   tail -f /var/log/smb-autostart.log
   ```

3. Verify service:
   ```bash
   systemctl status start-smb-containers.service
   ```

### Rollback

If you need to rollback to the old version:

1. Restore old script from git:
   ```bash
   git checkout HEAD~1 -- src/start-smb-containers.sh
   sudo cp src/start-smb-containers.sh /usr/local/bin/
   ```

2. Reload systemd:
   ```bash
   sudo systemctl daemon-reload
   ```

