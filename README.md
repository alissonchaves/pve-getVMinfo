# Proxmox VM Inventory

## Overview
- `lib/pve-getVMinfo.sh` runs on a Proxmox node and outputs `/tmp/vm_last_start.csv`.
- `lib/run_all_hosts.sh` copies and runs the script on multiple hosts via SSH, then merges into `pve_inventory.csv`.
- `pve_inventory.html` is a static page that loads the CSV over HTTP and provides filtering, sorting, and export.

## Requirements
- `sshpass` installed on the machine that runs `run_all_hosts.sh`.
- `jq` installed on Proxmox nodes for JSON parsing.
- HTTP server to open the HTML (Apache recommended for `.htaccess`).
- Apache with `AllowOverride All` if you want `.htaccess` access control.

## Configure hosts
Edit `lib/hosts.list` (one host per line):
```
flux-node1
flux-node2
```

## Run on all hosts
```
./lib/run_all_hosts.sh lib/hosts.list root 'YOUR_PASSWORD'
```
This generates `pve_inventory.csv` in this folder.

## Credentials
Two options:

1) SSH keys (recommended)
- Create a key and copy it to each Proxmox host:
  - `ssh-keygen -t ed25519`
  - `ssh-copy-id root@<host>`
- Run without password:
  - `./lib/run_all_hosts.sh lib/hosts.list root`

2) Password via `sshpass`
- Run with password:
  - `./lib/run_all_hosts.sh lib/hosts.list root 'YOUR_PASSWORD'`
- Requires `sshpass` installed on the machine running the script.

## Schedule with cron
Set a cron job on the machine running the script so the CSV stays updated. Example (every 15 minutes):
```
*/15 * * * * /path/to/pve-getVMinfo/lib/run_all_hosts.sh /path/to/pve-getVMinfo/lib/hosts.list root 'YOUR_PASSWORD' >/dev/null 2>&1
```

## View the HTML
```
python3 -m http.server 8000
```
Open:
```
http://localhost:8000/pve_inventory.html
```
Note: `python3 -m http.server` ignores `.htaccess`.

## Apache deployment
1) Place `pve_inventory.html`, `pve_inventory.csv`, `css/`, and `lib/` under your Apache DocumentRoot.
2) Ensure `AllowOverride All` is enabled for the directory so `.htaccess` is honored.
3) Access `http://your-host/pve_inventory.html`.

## Features
- Global search and per-column filters
- Sorting by any column (default: `Last Start` ascending)
- Row coloring by age of `Last Start`
- Export filtered rows to CSV

## Notes
- The HTML page reads `pve_inventory.csv` via HTTP.
- If you need a different CSV filename, update the `csvUrl` in `pve_inventory.html`.
