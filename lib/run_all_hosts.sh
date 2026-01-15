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

if command -v python3 >/dev/null 2>&1; then
    python3 - "$MERGED_CSV" <<'PY'
import csv
import datetime as dt
import sys

path = sys.argv[1]
with open(path, newline="") as f:
    rows = list(csv.reader(f))

if not rows:
    raise SystemExit(0)

header, data = rows[0], rows[1:]

def norm(text):
    return "".join(ch for ch in text.strip().lower() if ch.isalnum())

def find_index(name, default):
    target = norm(name)
    for i, col in enumerate(header):
        if norm(col) == target:
            return i
    return default

type_idx = find_index("Type", 0)
vmid_idx = find_index("VMID", 1)
status_idx = find_index("Status", -1)
last_idx = find_index("Last Start", 8)

def parse_ts(value):
    text = value.strip()
    if not text or text == "-" or text.lower() == "null":
        return None
    if " " in text and "T" not in text:
        text = text.replace(" ", "T", 1)
    try:
        return dt.datetime.fromisoformat(text)
    except ValueError:
        return None

def completeness_score(row):
    score = 0
    for cell in row:
        val = cell.strip()
        if val and val not in ("-", "null"):
            score += 1
    return score

def status_score(row):
    if status_idx < 0:
        return 0
    value = row[status_idx].strip().lower()
    if value == "online":
        return 2
    if value == "offline":
        return 1
    return 0

def is_better(new_row, old_row, new_meta, old_meta):
    if new_meta["ts"] and not old_meta["ts"]:
        return True
    if new_meta["ts"] and old_meta["ts"] and new_meta["ts"] > old_meta["ts"]:
        return True
    if new_meta["ts"] == old_meta["ts"]:
        if new_meta["score"] > old_meta["score"]:
            return True
        if new_meta["score"] == old_meta["score"]:
            return new_meta["status"] > old_meta["status"]
    return False

order = []
best = {}
meta = {}

for row in data:
    key = (row[type_idx].strip(), row[vmid_idx].strip())
    row_meta = {
        "ts": parse_ts(row[last_idx]) if last_idx >= 0 and last_idx < len(row) else None,
        "score": completeness_score(row),
        "status": status_score(row),
    }
    if key not in best:
        best[key] = row
        meta[key] = row_meta
        order.append(key)
        continue
    if is_better(row, best[key], row_meta, meta[key]):
        best[key] = row
        meta[key] = row_meta

with open(path, "w", newline="") as f:
    writer = csv.writer(f)
    writer.writerow(header)
    for key in order:
        writer.writerow(best[key])
PY
fi

echo "Merged CSV written to: $MERGED_CSV"
