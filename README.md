# Monitoring Utilities

Small Bash utilities for monitoring Linux systems over SSH or on the local host.
The current tool reports Netdata CPU/RAM metrics, Linux load, disk space, inode
usage, and uptime. Optional profiles monitor PostgreSQL and WireGuard.

```bash
./remote_stats.sh user@server --once
./remote_stats.sh localhost
./remote_stats.sh db-vm --profile db --once
./remote_stats.sh vpn-vm --profile vpn --json
```

Configure keys, ports, and jump hosts in `~/.ssh/config`. Remote snapshots use one
SSH connection and execute collectors on the monitored host. Netdata can stay
bound to localhost. No metrics history or alert delivery is provided.

- [Setup, options, configuration, and troubleshooting](REMOTESTATS.md)
- [WireGuard helper installation](helpers/README.md)
- [Planned OBS watchdog](WATCHDOG.md) (not implemented)
- [Original review and implementation status](suggestions.md)

For remote monitoring the local machine needs Bash, GNU `timeout`, and OpenSSH.
JSON output additionally needs local `jq`. Linux collector dependencies belong
on the monitored host; see the setup guide. Refreshing uses a Bash loop and does
not require `watch`.

Run the regression suite without root or running services:

```bash
python3 -m unittest discover -s tests -v
bash -n remote_stats.sh helpers/wg-dashboard-stats
shellcheck remote_stats.sh helpers/wg-dashboard-stats
```
