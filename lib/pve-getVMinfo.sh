#!/bin/bash

# Temporary file to store start timestamps
TMP_FILE="/tmp/vm_last_start.log"

# Output CSV file
CSV_FILE="/tmp/vm_last_start.csv"

: > "$TMP_FILE"
: > "$CSV_FILE"

csv_escape() {
    local value=$1
    value=${value//\"/\"\"}
    printf "\"%s\"" "$value"
}

# Write CSV header
echo "Type,VMID,VM Name,Status,Pool,Node,Responsible,Tags,Last Start,vCPU,Mem(GB),Disk(GB)" >> "$CSV_FILE"

# Cache cluster inventory (includes ONLINE and OFFLINE VMs/CTs)
CLUSTER_VMS_JSON=$(pvesh get /cluster/resources --type vm --output-format=json)

# Cache pool metadata (pool comment = Responsible)
POOLS_JSON=$(pvesh get /pools --output-format=json)

# Collect all start task files with their modification timestamps
find /var/log/pve/tasks -type f \( -name '*qmstart*' -o -name '*vzstart*' -o -name '*pctstart*' -o -name '*lxc-start*' \) -printf '%T@\t%f\n' |
while IFS=$'\t' read -r timestamp filename; do

    # Extract VMID from task filename
    vmid=$(echo "$filename" | awk -F: '{print $(NF-2)}')

    # Extract node name from task filename
    node=$(echo "$filename" | awk -F: '{print $2}')

    # Extract task name from task filename
    task_name=$(echo "$filename" | awk -F: '{print $(NF-3)}')

    # Convert UNIX timestamp to ISO 8601 format (no spaces)
    readable_time=$(date -d @"$timestamp" '+%Y-%m-%dT%H:%M:%S')

    # Store data
    printf "%s\t%s\t%s\t%s\t%s\n" "$vmid" "$timestamp" "$readable_time" "$node" "$task_name" >> "$TMP_FILE"
done

# Print table header (screen output)
printf "%-6s %-6s %-25s %-10s %-15s %-12s %-20s %-25s %-20s %-6s %-10s %s\n" \
       "Type" "VMID" "VM_Name" "Status" "Pool" "Node" "Responsible" "Tags" "Last_Start" "vCPU" "Mem(GB)" "Disk(GB)"

# Process latest start per VM
sort -t $'\t' -k1,1n -k2,2nr "$TMP_FILE" |
awk -F $'\t' '!seen[$1]++' |
while IFS=$'\t' read -r vmid timestamp readable_time node task_name; do

    current_info=$(echo "$CLUSTER_VMS_JSON" | jq -r \
        --arg vmid "$vmid" '.[] | select(.vmid == ($vmid | tonumber)) | "\(.type)\t\(.node)\t\(.pool // "-")\t\(.maxdisk // "")"' | head -n 1)

    if [[ -z "$current_info" ]]; then
        continue
    fi

    IFS=$'\t' read -r current_type current_node vm_pool current_maxdisk <<< "$current_info"

    if [[ -z "$current_type" || "$current_type" == "null" ]]; then
        continue
    fi

    if [[ -z "$current_node" || "$current_node" == "null" ]]; then
        continue
    fi

    if [[ "$current_node" != "$node" ]]; then
        continue
    fi

    case "$current_type" in
        qemu)
            vm_type="vm"
            status_path="qemu"
            ;;
        lxc)
            vm_type="ct"
            status_path="lxc"
            ;;
        *)
            vm_type="unknown"
            status_path="qemu"
            ;;
    esac

    # Runtime status (may fail if VM is offline or node unavailable)
    status_json=$(pvesh get /nodes/"$node"/"$status_path"/"$vmid"/status/current \
        --output-format=json 2>/dev/null || true)
    vm_status=$(echo "$status_json" | jq -r '.status // "offline"' 2>/dev/null)
    maxdisk_bytes=$(echo "$status_json" | jq -r '.maxdisk // empty' 2>/dev/null)
    if [[ -z "$maxdisk_bytes" && -n "$current_maxdisk" && "$current_maxdisk" != "null" ]]; then
        maxdisk_bytes="$current_maxdisk"
    fi

    [[ "$vm_status" == "running" ]] && vm_status="online" || vm_status="offline"

    # Config (name and tags exist even if offline)
    vm_config=$(pvesh get /nodes/"$node"/"$status_path"/"$vmid"/config \
        --output-format=json 2>/dev/null)

    vm_name=$(echo "$vm_config" | jq -r '.name // "-"')
    vm_tags=$(echo "$vm_config" | jq -r '.tags // "-"')
    vm_cores=$(echo "$vm_config" | jq -r '.cores // "-"')
    vm_memory_mb=$(echo "$vm_config" | jq -r '.memory // "-"')
    vm_memory_gb="-"
    if [[ -n "$vm_memory_mb" && "$vm_memory_mb" != "-" && "$vm_memory_mb" != "null" ]]; then
        vm_memory_gb=$(awk -v m="$vm_memory_mb" 'BEGIN { printf "%.1f", m / 1024 }')
    fi
    vm_disk_gb="-"

    get_disk_gb_from_values() {
        awk '
            function to_gb(v, u) {
                if (u == "K") return v / (1024 * 1024);
                if (u == "M") return v / 1024;
                if (u == "G" || u == "") return v;
                if (u == "T") return v * 1024;
                return 0;
            }
            {
                while (match($0, /size=([0-9.]+)([KMGTP]?)/, m)) {
                    total += to_gb(m[1], m[2]);
                    $0 = substr($0, RSTART + RLENGTH);
                }
            }
            END { printf "%.2f", total + 0; }
        '
    }

    if [[ "$status_path" == "qemu" ]]; then
        disk_values=$(echo "$vm_config" | jq -r '
            to_entries[]
            | select(.key | test("^(scsi|sata|ide|virtio)[0-9]+$"))
            | .value
        ')
    else
        disk_values=$(echo "$vm_config" | jq -r '
            to_entries[]
            | select(.key == "rootfs" or (.key | test("^mp[0-9]+$")))
            | .value
        ')
    fi

    disk_from_config=$(printf "%s\n" "$disk_values" | get_disk_gb_from_values)
    if [[ -n "$disk_from_config" && "$disk_from_config" != "0.00" ]]; then
        vm_disk_gb="$disk_from_config"
    elif [[ -n "$maxdisk_bytes" && "$maxdisk_bytes" != "null" ]]; then
        vm_disk_gb=$(awk -v b="$maxdisk_bytes" 'BEGIN { printf "%.1f", b / 1024 / 1024 / 1024 }')
    fi

    [[ -z "$vm_pool" || "$vm_pool" == "null" ]] && vm_pool="-"

    # Resolve Responsible from pool comment (independent of VM status)
    responsible=$(echo "$POOLS_JSON" | jq -r \
        --arg pool "$vm_pool" '.[] | select(.poolid == $pool) | .comment // "-"')

    [[ -z "$responsible" ]] && responsible="-"

    # Screen output
    printf "%-6s %-6s %-25s %-10s %-15s %-12s %-20s %-25s %-20s %-6s %-10s %s\n" \
        "$vm_type" "$vmid" "$vm_name" "$vm_status" \
        "$vm_pool" "$node" "$responsible" "$vm_tags" "$readable_time" \
        "$vm_cores" "$vm_memory_gb" "$vm_disk_gb"

    # CSV output
    printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
        "$(csv_escape "$vm_type")" "$(csv_escape "$vmid")" "$(csv_escape "$vm_name")" \
        "$(csv_escape "$vm_status")" "$(csv_escape "$vm_pool")" "$(csv_escape "$node")" \
        "$(csv_escape "$responsible")" "$(csv_escape "$vm_tags")" "$(csv_escape "$readable_time")" \
        "$(csv_escape "$vm_cores")" "$(csv_escape "$vm_memory_gb")" "$(csv_escape "$vm_disk_gb")" >> "$CSV_FILE"
done
