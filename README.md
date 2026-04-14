
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

## 🔭 Future Improvements

* `--no-color` flag
* `--brief` mode (single-line output)
* multi-host wrapper (`fleet_stats.sh`)
* role-based metrics (e.g., `--postgres`)
* tmux dashboard launcher

---

## 📁 Source

Script: 

---

## 💡 Example Use Case

Run in tmux:

```bash
./remote_stats.sh host1
./remote_stats.sh host2
./remote_stats.sh host3
```
