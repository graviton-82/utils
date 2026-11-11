# remote_stats.sh

## Requirements and setup

The local machine needs Bash 4+, GNU coreutils `timeout`, and an OpenSSH client
for remote targets. `--json` also requires local `jq`. The monitored Linux host
needs Bash 4+, curl, jq, awk, hostname, df, getconf, and readable `/proc` files.
Local monitoring requires those collector dependencies on the local machine.

Install and run Netdata using the installation procedure for your distribution.
Its API must be reachable **on the monitored host** at `http://localhost:19999`.
It does not need to be exposed to the network. Test on that host:

```bash
curl -fsS http://localhost:19999/api/v1/info
```

Configure SSH authentication and host keys before monitoring. The script uses
batch authentication and will not prompt for passwords or new host keys. SSH
aliases, ports, identity files, and `ProxyJump` belong in `~/.ssh/config`:

```sshconfig
Host db-vm
    HostName 10.0.0.20
    User monitor
    IdentityFile ~/.ssh/id_ed25519
    ProxyJump bastion
```

`localhost`, `127.0.0.1`, and the output of `hostname` bypass SSH. Other targets,
including other names for this host, use SSH. Hosts must run Linux; macOS,
FreeBSD, and Windows collectors are not implemented.

## Usage

```bash
./remote_stats.sh user@server --once
./remote_stats.sh db-vm /var/lib/postgresql --profile db --once
./remote_stats.sh vpn-vm --profile vpn --interval 5
./remote_stats.sh localhost --json
./remote_stats.sh localhost --once --debug --no-color
./remote_stats.sh --help
```

The first positional argument is the target; the optional second is a filesystem
path (default `/`). Quote paths containing spaces or shell characters. Newlines,
carriage returns, and `|` in paths are rejected. Unknown options, extra positional
arguments, invalid profiles, and missing option values are errors.

| Option | Meaning |
| --- | --- |
| `--once` | Collect and display one snapshot. |
| `--profile base\|db\|vpn` | Select base metrics or additional service metrics. |
| `--interval SECONDS` | Positive integer delay between snapshots, default 2. |
| `--timeout SECONDS` | Positive integer overall collection deadline, default 30. |
| `--no-color` | Disable ANSI color. Redirected output and `NO_COLOR` also disable it. |
| `--json` | Emit a JSON snapshot; implies `--once` and disables color. |
| `--debug` | Print sanitized failure tokens and transport exit codes to stderr. |
| `--help` | Display usage. |

Refresh mode clears an interactive terminal between snapshots. Redirected output
appends snapshots. The interval is a delay **after** collection; it is not a fixed
sampling period. Interrupt with Ctrl-C. No `watch` dependency is needed.

## Metrics and status

A snapshot includes uptime in the heading and CPU, RAM, LOAD, DISK, and INOD rows.
CPU and RAM use the sample with the greatest timestamp in the returned Netdata
response; absent or invalid required dimensions produce `UNKNOWN`.

- CPU total is explicitly **user + system + iowait**. Other CPU states are not
  included; it is not an all-states utilization measure.
- RAM usage is `used / (used + free + cached + buffers)`; total is displayed in GiB
  assuming Netdata's standard MiB dimensions. A zero total is invalid.
- LOAD reports one-minute load, online CPU count, and `load / CPUs * 100`.
- DISK and INOD report space and inode percentages for the requested path. The
  displayed path is the requested path, which may be inside the filesystem.
- PostgreSQL reports other client backends against `max_connections`, excluding
  this monitoring session and background workers. Reserved slots mean this is
  an approximate capacity indicator, not the number of usable remaining slots.
- VPN reports interface existence separately from peer activity. An existing
  interface with old or absent handshakes is `OK` with `idle_or_no_handshake`;
  inactivity alone does not prove a fault. `newest=-1s` means no peer has a
  handshake timestamp. A missing interface is `CRITICAL`.

Threshold comparisons are inclusive (`>=`). Defaults:

| Metric | Warning | Critical |
| --- | --- | --- |
| CPU | 20% | 70% |
| RAM | 70% | 90% |
| Normalized load | 100% | 200% |
| Disk and inodes | 80% | 90% |
| PostgreSQL connections | 80% | 90% |

Blocked PostgreSQL clients are critical. Transactions idle over 60 seconds and
active queries over 60 seconds are warnings unless another condition is critical.
A server not accepting connections is critical; query/authentication failures
are unknown. A successful readiness probe does not validate monitoring access.

`OFFLINE` means no valid host header was received before transport failed or the
deadline elapsed; this does not prove the machine is powered off. Once the host
header arrives, failed collectors produce `UNKNOWN`, retaining available rows.

Exit codes for one snapshot:

- `0`: collection completed, including successfully observed unhealthy services.
- `1`: collection incomplete, transport failed, or privileged VPN helper failed.
- `2`: invalid invocation/configuration or missing local prerequisite.

Refresh mode continues through collection errors. SIGINT exits 130; SIGTERM exits
143. No health-based exit mode is provided; automation should inspect statuses.

JSON contains `target`, `host`, `uptime`, and a `metrics` array of
`{name, status, detail}` records. Details are readable strings; they are not a
stable numeric metrics API. Uptime is an empty string when unavailable.

## Configuration

Set these variables on the **invoking machine**; validated values are safely
transferred in the single remote collector session. CLI values override interval
and overall timeout environment settings.

| Variable | Default | Meaning |
| --- | --- | --- |
| `RS_INTERVAL` | `2` | Refresh delay in seconds. |
| `RS_TIMEOUT` | `30` | Overall snapshot deadline in seconds. |
| `RS_HTTP_TIMEOUT` | `5` | HTTP deadline, PostgreSQL connection timeout, and statement timeout in seconds. |
| `RS_NETDATA_URL` | `http://localhost:19999` | Base URL as seen by the monitored host. No embedded credentials, query, or fragment. |
| `RS_PGHOST` | `localhost` | PostgreSQL host or socket directory on the monitored host. |
| `RS_PGPORT` | `5432` | PostgreSQL port (1–65535). |
| `RS_PGUSER` | `remote_monitor` | PostgreSQL monitoring role. |
| `RS_PGDATABASE` | `postgres` | PostgreSQL database. |
| `RS_WG_INTERFACE` | `wg0` | WireGuard interface, at most 15 characters. |
| `RS_WG_RECENT` | `600` | Positive handshake age window in seconds. |
| `RS_CPU_WARN`, `RS_CPU_CRIT` | `20`, `70` | CPU thresholds. |
| `RS_RAM_WARN`, `RS_RAM_CRIT` | `70`, `90` | RAM thresholds. |
| `RS_LOAD_WARN`, `RS_LOAD_CRIT` | `100`, `200` | Normalized load thresholds. |
| `RS_DISK_WARN`, `RS_DISK_CRIT` | `80`, `90` | Space and inode thresholds. |
| `RS_PG_WARN`, `RS_PG_CRIT` | `80`, `90` | PostgreSQL connection thresholds. |

Integers must use decimal notation without leading zeros. Warning thresholds
must be lower than critical thresholds. Percentage critical thresholds cannot
exceed 100; load thresholds may. The collector sets `LC_ALL=C` for numeric parsing.
The overall deadline may truncate later collectors; increase it for slow hosts.
It sends TERM and allows at most two additional seconds before KILL. SSH also
uses a three-second connection timeout and server liveness probes.

## PostgreSQL profile

Install `psql` and `pg_isready` on the monitored host. Have a database administrator
create a login role with CONNECT access to the chosen database and monitoring
visibility into other sessions (for example, the built-in `pg_monitor` role).
Check that the role can read the required `pg_stat_activity` fields for other
users; restricted visibility can otherwise underreport query issues.

Configure authentication on that host for the SSH account, using a protected
`.pgpass` file or the site's existing PostgreSQL authentication mechanism. The
script uses `psql -w` and never prompts. It does not transfer passwords from the
invoking machine or accept them as command-line options. For local collection,
the normal libpq environment and credential files are available locally. The
script overrides connection identity settings and `PGOPTIONS` to enforce its
statement deadline.

## WireGuard profile

Install `ip`, `sudo`, WireGuard, and the [root-owned aggregate helper](helpers/README.md)
on the monitored host. The helper returns only peer counts and handshake age.
Upgrade the helper and main script together: the old raw-dump protocol is no
longer supported.

## Troubleshooting and validation

Run `--once --debug` first. Debug output deliberately exposes only fixed failure
reasons, not raw HTTP, database, SSH, or privileged command output, which could
contain sensitive data. Diagnose SSH separately with `ssh target hostname`.
Check Netdata locally on the monitored host. Validate PostgreSQL credentials with
`psql -w` under the same SSH account. Test the helper using the installation guide.

The test suite uses mocked commands and does not validate live Netdata versions,
database permissions, SSH configuration, sudoers policy, or VPN connectivity.
There is no metrics storage or automatic recovery. The Windows OBS watchdog
remains a [roadmap](WATCHDOG.md).
