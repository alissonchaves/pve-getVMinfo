#!/bin/bash
set -u

HOSTS_FILE=${1:-"$(dirname "$0")/hosts.list"}
SSH_USER=${2:-"root"}
SSH_PASS=${3:-""}
OUT_DIR=${4:-"$(cd "$(dirname "$0")/.." && pwd)"}

if [[ ! -f "$HOSTS_FILE" ]]; then
    echo "Hosts file not found: $HOSTS_FILE" >&2
    exit 1
fi

USE_SSHPASS=false
if [[ -n "${SSH_PASS}" ]]; then
    if ! command -v sshpass >/dev/null 2>&1; then
        echo "sshpass is required for password SSH. Install it and try again." >&2
        exit 1
    fi
    USE_SSHPASS=true
fi

SCRIPT_PATH="$(dirname "$0")/pve-getVMinfo.sh"
MERGED_CSV="$OUT_DIR/pve_inventory.csv"

: > "$MERGED_CSV"

echo "Type,VMID,VM Name,Status,Pool,Node,Responsible,Tags,Last Start,vCPU,Mem(GB),Disk(GB)" >> "$MERGED_CSV"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

exec 3< "$HOSTS_FILE"
while IFS= read -r raw_host <&3 || [[ -n "$raw_host" ]]; do
    host=${raw_host//$'\r'/}
    host=${host#"${host%%[![:space:]]*}"}
    host=${host%"${host##*[![:space:]]}"}
    [[ -z "$host" || "$host" =~ ^# ]] && continue

    echo "Processing host: $host"

    if $USE_SSHPASS; then
        scp_cmd=(sshpass -p "$SSH_PASS" scp)
        ssh_cmd=(sshpass -p "$SSH_PASS" ssh -n)
    else
        scp_cmd=(scp)
        ssh_cmd=(ssh -n)
    fi

    if ! "${scp_cmd[@]}" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        "$SCRIPT_PATH" "$SSH_USER@$host:/tmp/pve-getVMinfo.sh" </dev/null; then
        echo "Failed to copy script to $host" >&2
        continue
    fi

    if ! "${ssh_cmd[@]}" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        "$SSH_USER@$host" "bash /tmp/pve-getVMinfo.sh >/dev/null 2>/dev/null" </dev/null; then
        echo "Failed to run script on $host" >&2
        continue
    fi

    if ! "${ssh_cmd[@]}" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        "$SSH_USER@$host" "cat /tmp/vm_last_start.csv" > "$TMP_DIR/$host.csv" </dev/null; then
        echo "Failed to fetch CSV from $host" >&2
        continue
    fi

    if ! awk -F, 'NR>1 { print $0 }' "$TMP_DIR/$host.csv" >> "$MERGED_CSV"; then
        echo "Failed to merge CSV from $host" >&2
        continue
    fi

    if ! tail -n 1 "$TMP_DIR/$host.csv" >/dev/null 2>&1; then
        echo "Empty CSV from $host" >&2
    fi

done
exec 3<&-

echo "Merged CSV written to: $MERGED_CSV"
