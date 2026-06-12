
# 📊 `remote_stats.sh`

A lightweight CLI tool for monitoring remote Linux hosts over SSH using Netdata.

Designed for:

* quick diagnostics
* tmux dashboards
* low-overhead environments
* no central monitoring stack required

---

## 🚀 Features

* SSH-based (no agents beyond Netdata)
* Works across Debian, Ubuntu, Fedora
* Minimal dependencies (`jq`, `awk`, `ssh`)
* Real-time monitoring via `watch`
* Clean, structured output
* Color-coded status indicators

---

## 📦 Requirements

### Local machine

* `bash`
* `ssh`
* `jq`
* `awk`

### Remote host

* Netdata running on port `19999`
* `bash`
* `curl`
* `jq`
* `awk`

---

## ⚙️ Netdata Setup (Remote Hosts)

Install Netdata on each monitored host:

```bash
bash <(curl -Ss https://my-netdata.io/kickstart.sh)
```

On Offline hosts:
```bash
wget -O /tmp/netdata-kickstart.sh https://get.netdata.cloud/kickstart.sh
sh /tmp/netdata-kickstart.sh --release-channel stable --prepare-offline-install-source ./netdata-offline
```
Then transfer with scp (or equivalent)

More info:
https://learn.netdata.cloud/docs/netdata-agent/installation/linux/offline-systems

Note: 
Offline systems my install outside of your path. i.e.
/opt/netdata/bin/netdata 
/opt/netdata/etc/netdata/netdata.conf

find with: 
```bash
whereis
```
If necessary.

Verify it is running:

```bash
systemctl status netdata
```

Test locally on the host:

```bash
curl http://localhost:19999/api/v1/info
```

No external exposure is required—this script uses:

```text
SSH → localhost:19999
```

---

## 🔐 SSH Setup

Passwordless SSH is strongly recommended:

```bash
ssh-keygen -t ed25519
ssh-copy-id user@remote-host
```

Test:

```bash
ssh user@remote-host hostname
```

---

## 🧪 Usage

### One-shot (single run)

```bash
./remote_stats.sh user@ip --once
```

### Continuous monitoring (default)

```bash
./remote_stats.sh user@ip
```

### Specify disk mount

```bash
./remote_stats.sh user@ip --once /var/lib/postgresql
```

---

## 📈 Output Format

```text
=== hostname (user@ip) ===
CPU  : OK       user=2.0% system=3.2% iowait=0.1% total=5.2%
RAM  : OK       used=23% total=7.34 GiB
LOAD : OK       load1=0.35 cpus=8 normalized=4%
DISK : OK       used=17% mount=/
```

### Status Levels

| Status   | Meaning                 |
| -------- | ----------------------- |
| OK       | Healthy                 |
| WARNING  | Moderate pressure       |
| CRITICAL | High load / near limits |
| OFFLINE  | Host unreachable        |
| UNKNOWN  | Metric unavailable      |

---

## 🎨 Color Coding

Only the **status field** is colored:

* 🟢 OK → green
* 🟡 WARNING → yellow
* 🔴 CRITICAL / OFFLINE → red

Works well in:

* tmux
* terminal dashboards

---

## 🧠 Metrics Explained

### CPU

* `user`: user-space processes
* `system`: kernel activity
* `iowait`: waiting on disk/network
* `total`: sum of above

### RAM

* Derived from:

  * `used`
  * `free`
  * `cached`
  * `buffers`
* Shows:

  * used %
  * total memory (GiB)

### LOAD

* 1-minute load average
* normalized by CPU count:

```text
normalized = load1 / cpus * 100
```

### DISK

* Uses `df -P`
* Reports:

  * used %
  * mount point

---

## 🧱 Design Philosophy

This tool is:

* **stateless** → no history, only live data
* **pull-based** → SSH into hosts
* **minimal** → avoids heavy monitoring stacks
* **composable** → works well with tmux, scripts

It is **not**:

* a full monitoring system
* a metrics database
* a replacement for Prometheus/Grafana

---

## ⚠️ Limitations

* Requires SSH access
* No historical data
* No alerting
* Dependent on Netdata being available locally

---

## 🛠️ Troubleshooting

### Host shows `OFFLINE`

```bash
ssh user@host hostname
```

### Metrics show `UNKNOWN`

Test Netdata:

```bash
ssh user@host 'curl http://localhost:19999/api/v1/data?chart=system.cpu'
```

### JSON parsing issues

Check `jq`:

```bash
ssh user@host 'jq --version'
```

---

### Example SSH Configuration

```sshconfig
Host access-vm
    HostName private.network.com
    User access-user
    IdentityFile ~/access_keys/key-file.pem

Host private-vm
    HostName 10.10.10.20
    User private-user
    ProxyJump access-vm

Host db-vm
    HostName 192.168.1.150
    User db-user

Host vpn-vm
    HostName 192.168.1.149
    User vpn-user
```

### Usage

After configuring SSH aliases, hosts may be monitored using their alias name:

```bash
./remote_stats.sh db-vm
./remote_stats.sh vpn-vm --profile vpn
./remote_stats.sh private-vm
```

The monitoring script does not need to know whether a host is local, remote, cloud-hosted, or accessed through a jump host. All connection handling is delegated to OpenSSH.

### Localhost Monitoring

The special targets below bypass SSH and execute monitoring commands locally:

```text
localhost
127.0.0.1
$(hostname)
```

Example:

```bash
./remote_stats.sh localhost
```

This allows the monitoring host itself to be monitored using the same interface and output format as remote systems.

### Connection Tuning

The script centralizes SSH options in a shared helper. If cloud-hosted systems or jump-host chains require additional connection time, increase the configured `ConnectTimeout` value rather than modifying individual monitoring functions.


---

## 💡 Example Use Case

Run in tmux:

```bash
./remote_stats.sh host1
./remote_stats.sh host2
./remote_stats.sh host3
```
## SSH Configuration and Jump Hosts

`remote_stats.sh` relies on the local OpenSSH client for all remote connectivity. Host-specific connection settings should be configured in `~/.ssh/config` rather than embedded in the script.

### Benefits

* Supports SSH keys without modifying the script
* Supports non-standard ports
* Supports bastion/jump hosts (`ProxyJump`)
* Supports cloud VMs and VPN-only hosts
* Keeps monitoring logic separate from connection logic

---

## 🔭 Future Improvements

* `--no-color` flag
* `--brief` mode (single-line output)
* multi-host wrapper (`fleet_stats.sh`)
* role-based metrics (e.g., `--postgres`)
* tmux dashboard launcher
