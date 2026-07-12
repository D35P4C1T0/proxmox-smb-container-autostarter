#!/usr/bin/env bash
set -uo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/share-autostart.conf}"
if [[ -r "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

TAG="${TAG:-smb}"
PROTOCOL="${PROTOCOL:-smb}"
SHARE_HOST="${SHARE_HOST:-${TRUENAS_IP:-}}"
SHARE_NAME="${SHARE_NAME:-${SMB_SHARE_NAME:-}}"
SOURCE_VMID="${SOURCE_VMID:-${TRUENAS_VMID:-}}"
SOURCE_TYPE="${SOURCE_TYPE:-qemu}"
CREDENTIALS_FILE="${CREDENTIALS_FILE-/root/.smbcredentials}"
MAX_WAIT="${MAX_WAIT:-600}"
SLEEP_INTERVAL="${SLEEP_INTERVAL:-5}"
START_TIMEOUT="${START_TIMEOUT:-60}"
LOG_FILE="${LOG_FILE:-}"
DRY_RUN="${DRY_RUN:-0}"

log() {
    local level=$1
    shift
    local line
    printf -v line '[%(%Y-%m-%d %H:%M:%S)T] [%s] %s' -1 "$level" "$*"
    printf '%s\n' "$line"
    if [[ -n "$LOG_FILE" ]]; then
        printf '%s\n' "$line" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

die() { log ERROR "$*" >&2; exit 1; }
has_command() { command -v "$1" >/dev/null 2>&1; }

validate_config() {
    [[ $EUID -eq 0 ]] || die "Run as root on a Proxmox VE node"
    has_command pct || die "pct not found; run this on a Proxmox VE node"
    [[ -n "$TAG" ]] || die "TAG cannot be empty"
    [[ "$MAX_WAIT" =~ ^[0-9]+$ && "$SLEEP_INTERVAL" =~ ^[1-9][0-9]*$ && \
        "$START_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || \
        die "MAX_WAIT, SLEEP_INTERVAL, and START_TIMEOUT have invalid values"

    case "$PROTOCOL" in
        smb)
            has_command smbclient || die "smbclient missing; install package smbclient"
            [[ -n "$SHARE_HOST" && -n "$SHARE_NAME" ]] || \
                die "Set SHARE_HOST and SHARE_NAME in $CONFIG_FILE"
            if [[ -n "$CREDENTIALS_FILE" && ! -r "$CREDENTIALS_FILE" ]]; then
                die "SMB credentials not readable: $CREDENTIALS_FILE"
            fi
            ;;
        nfs)
            has_command showmount || die "showmount missing; install package nfs-common"
            [[ -n "$SHARE_HOST" && -n "$SHARE_NAME" ]] || \
                die "Set SHARE_HOST and SHARE_NAME (export path) in $CONFIG_FILE"
            ;;
        *) die "PROTOCOL must be smb or nfs" ;;
    esac

    case "$SOURCE_TYPE" in qemu|lxc) ;; *) die "SOURCE_TYPE must be qemu or lxc" ;; esac
}

source_is_running() {
    [[ -z "$SOURCE_VMID" ]] && return 0
    if [[ "$SOURCE_TYPE" == qemu ]]; then
        has_command qm || return 1
        [[ $(qm status "$SOURCE_VMID" 2>/dev/null | awk '{print $2}') == running ]]
    else
        [[ $(pct status "$SOURCE_VMID" 2>/dev/null | awk '{print $2}') == running ]]
    fi
}

share_is_ready() {
    case "$PROTOCOL" in
        smb)
            local target="//${SHARE_HOST}/${SHARE_NAME}"
            if [[ -n "$CREDENTIALS_FILE" ]]; then
                smbclient "$target" --authentication-file="$CREDENTIALS_FILE" \
                    --command='quit' >/dev/null 2>&1
            else
                smbclient "$target" --no-pass --command='quit' >/dev/null 2>&1
            fi
            ;;
        nfs)
            showmount --exports "$SHARE_HOST" 2>/dev/null | \
                awk -v wanted="$SHARE_NAME" 'NR > 1 && $1 == wanted { found=1 } END { exit !found }'
            ;;
    esac
}

wait_for_share() {
    local waited=0 last_report=-30
    while (( waited <= MAX_WAIT )); do
        if ! source_is_running; then
            if (( waited - last_report >= 30 )); then
                log INFO "Waiting for ${SOURCE_TYPE} ${SOURCE_VMID}"
                last_report=$waited
            fi
        elif share_is_ready; then
            log INFO "${PROTOCOL^^} share ${SHARE_HOST}:${SHARE_NAME} is ready"
            return 0
        elif (( waited - last_report >= 30 )); then
            log INFO "Waiting for ${PROTOCOL^^} share ${SHARE_HOST}:${SHARE_NAME} (${waited}/${MAX_WAIT}s)"
            last_report=$waited
        fi
        (( waited == MAX_WAIT )) && break
        local delay=$SLEEP_INTERVAL
        (( waited + delay > MAX_WAIT )) && delay=$((MAX_WAIT - waited))
        sleep "$delay"
        waited=$((waited + delay))
    done
    die "Timed out waiting for ${PROTOCOL^^} share ${SHARE_HOST}:${SHARE_NAME}"
}

has_tag() {
    local vmid=$1 tags candidate
    tags=$(pct config "$vmid" 2>/dev/null | sed -n 's/^tags:[[:space:]]*//p' | head -n1)
    IFS=';' read -r -a tag_list <<< "$tags"
    for candidate in "${tag_list[@]}"; do
        candidate=${candidate#"${candidate%%[![:space:]]*}"}
        candidate=${candidate%"${candidate##*[![:space:]]}"}
        [[ "$candidate" == "$TAG" ]] && return 0
    done
    return 1
}

local_container_ids() {
    pct list 2>/dev/null | awk 'NR > 1 && $1 ~ /^[0-9]+$/ { print $1 }'
}

start_container() {
    local vmid=$1 status waited=0
    status=$(pct status "$vmid" 2>/dev/null | awk '{print $2}')
    if [[ "$status" == running ]]; then
        log INFO "Container $vmid already running"
        return 0
    fi
    [[ "$status" == stopped ]] || { log ERROR "Container $vmid has unknown state: ${status:-unknown}"; return 1; }
    if [[ "$DRY_RUN" == 1 ]]; then
        log INFO "DRY RUN: would start container $vmid"
        return 0
    fi
    log INFO "Starting container $vmid"
    pct start "$vmid" || { log ERROR "pct start $vmid failed"; return 1; }
    while (( waited < START_TIMEOUT )); do
        [[ $(pct status "$vmid" 2>/dev/null | awk '{print $2}') == running ]] && return 0
        sleep 1
        waited=$((waited + 1))
    done
    log ERROR "Container $vmid did not reach running state in ${START_TIMEOUT}s"
    return 1
}

main() {
    validate_config
    wait_for_share

    local found=0 failed=0 vmid
    while read -r vmid; do
        [[ -n "$vmid" ]] || continue
        if has_tag "$vmid"; then
            found=$((found + 1))
            start_container "$vmid" || failed=$((failed + 1))
        fi
    done < <(local_container_ids)

    (( found > 0 )) || log WARN "No local LXC has tag '$TAG'"
    log INFO "Finished: matched=$found failed=$failed"
    (( failed == 0 ))
}

main "$@"
