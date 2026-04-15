#!/usr/bin/env bash

set -u

remote_target="$1"
mode="${2:-}"
disk_mount="${3:-/}"

profile="base"

RED="\033[0;31m"
YELLOW="\033[0;33m"
GREEN="\033[0;32m"
RESET="\033[0m"

remote_target=""
mode=""
disk_mount="/"
profile="base"

if [ $# -lt 1 ]; then
    echo "Usage: $0 user@ip-address [--once] [mount] [--profile db]"
    exit 1
fi

remote_target="$1"
shift

while [ $# -gt 0 ]; do
    case "$1" in
        --once)
            mode="--once"
            ;;
        --profile)
            shift
            profile="${1:-base}"
            ;;
        *)
            disk_mount="$1"
            ;;
    esac
    shift
done



color_status() {
    local status="$1"

    case "$status" in
        OK)
            printf "${GREEN}%s${RESET}" "$status"
            ;;
        WARNING)
            printf "${YELLOW}%s${RESET}" "$status"
            ;;
        CRITICAL)
            printf "${RED}%s${RESET}" "$status"
            ;;
        OFFLINE)
            printf "${RED}%s${RESET}" "$status"
            ;;
        *)
            printf "%s" "$status"
            ;;
    esac
}

run_remote() {
    local cmd="$1"
    ssh -o BatchMode=yes -o ConnectTimeout=3 "$remote_target" \
        "bash -lc '$cmd'" 2>/dev/null
}

status_from_thresholds() {
    local value="$1"
    local warn="$2"
    local crit="$3"

    awk -v v="$value" -v w="$warn" -v c="$crit" 'BEGIN {
        if (v >= c) print "CRITICAL";
        else if (v >= w) print "WARNING";
        else print "OK";
    }'
}

##### Basil Functions #####

get_uptime() {
    ssh -o BatchMode=yes -o ConnectTimeout=3 "$remote_target" 'bash -s' <<'EOF' 2>/dev/null
read -r uptime_seconds _ < /proc/uptime || exit 1

awk -v s="$uptime_seconds" 'BEGIN {
  s = int(s)
  d = int(s / 86400)
  h = int((s % 86400) / 3600)
  m = int((s % 3600) / 60)

  if (d > 0) {
    printf "%dd%dh\n", d, h
  } else if (h > 0) {
    printf "%dh%dm\n", h, m
  } else {
    printf "%dm\n", m
  }
}'
EOF
}


status_from_inode_usage() {
    local value="$1"

    awk -v v="$value" 'BEGIN {
        if (v >= 90) print "CRITICAL";
        else if (v >= 80) print "WARNING";
        else print "OK";
    }'
}

get_inodes() {
    ssh -o BatchMode=yes -o ConnectTimeout=3 "$remote_target" 'bash -s' <<EOF 2>/dev/null
df -Pi "$disk_mount" | awk 'NR==2 {
  gsub(/%/, "", \$5)
  printf "%s|%s\n", \$5, \$6
}'
EOF
}

get_cpu() {
    ssh -o BatchMode=yes -o ConnectTimeout=3 "$remote_target" 'bash -s' <<'EOF' 2>/dev/null
curl -fsS "http://localhost:19999/api/v1/data?chart=system.cpu" | jq -r '
  .labels as $l |
  .data[-1] as $d |
  ($d[($l|index("user"))] // 0) as $user |
  ($d[($l|index("system"))] // 0) as $system |
  ($d[($l|index("iowait"))] // 0) as $iowait |
  ($user + $system + $iowait) as $total |
  "\($user)|\($system)|\($iowait)|\($total)"
'
EOF
}


get_ram() {
    ssh -o BatchMode=yes -o ConnectTimeout=3 "$remote_target" 'bash -s' <<'EOF' 2>/dev/null
curl -fsS "http://localhost:19999/api/v1/data?chart=system.ram" | jq -r '
  .labels as $l |
  .data[-1] as $d |
  ($d[($l|index("used"))] // 0) as $used |
  ($d[($l|index("free"))] // 0) as $free |
  ($d[($l|index("cached"))] // 0) as $cached |
  ($d[($l|index("buffers"))] // 0) as $buffers |
  ($used + $free + $cached + $buffers) as $total_mb |
  (if $total_mb > 0 then (($used / $total_mb) * 100) else 0 end) as $used_pct |
  "\($used_pct)|\($total_mb)"
'
EOF
}



get_load() {
    ssh -o BatchMode=yes -o ConnectTimeout=3 "$remote_target" 'bash -s' <<'EOF' 2>/dev/null
read -r loadavg _ < /proc/loadavg || exit 1

cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null) || cpus=""
if [ -z "$cpus" ]; then
    cpus=$(nproc 2>/dev/null) || cpus=""
fi
if [ -z "$cpus" ]; then
    cpus=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null) || cpus=""
fi
if [ -z "$cpus" ] || [ "$cpus" -le 0 ] 2>/dev/null; then
    cpus=1
fi

awk -v loadavg="$loadavg" -v cpus="$cpus" 'BEGIN {
  norm = (cpus > 0) ? (loadavg / cpus) * 100 : 0
  printf "%.2f|%d|%.0f\n", loadavg, cpus, norm
}'
EOF
}



get_disk() {
    ssh -o BatchMode=yes -o ConnectTimeout=3 "$remote_target" 'bash -s' <<EOF 2>/dev/null
df -P "$disk_mount" | awk 'NR==2 {
  gsub(/%/, "", \$5)
  printf "%s|%s|%s|%s|%s\n", \$5, \$6, \$2, \$3, \$4
}'
EOF
}



##### Database Profile Functions ######

status_from_pg_connections() {
    local value="$1"

    awk -v v="$value" 'BEGIN {
        if (v >= 90) print "CRITICAL";
        else if (v >= 70) print "WARNING";
        else print "OK";
    }'
}

status_from_pg_metrics() {
    local used_pct="$1"
    local idle_tx="$2"
    local long_q="$3"
    local blocked="$4"

    if (( blocked > 0 )); then
        echo "CRITICAL"
    elif (( used_pct >= 90 )); then
        echo "CRITICAL"
    elif (( idle_tx > 0 || long_q > 0 )); then
        echo "WARNING"
    elif (( used_pct >= 80 )); then
        echo "WARNING"
    else
        echo "OK"
    fi
}

get_postgres() {
    ssh -o BatchMode=yes -o ConnectTimeout=3 "$remote_target" 'bash -s' <<'EOF' 2>/dev/null
PGDATABASE=postgres
PGUSER=remote_monitor
PGHOST=localhost
PGPORT=5432

if ! command -v pg_isready >/dev/null 2>&1; then
    echo "UNKNOWN|pg_isready_missing"
    exit 0
fi

if ! command -v psql >/dev/null 2>&1; then
    echo "UNKNOWN|psql_missing"
    exit 0
fi

if ! pg_isready -q -h "$PGHOST" -p "$PGPORT" -d "$PGDATABASE" -U "$PGUSER"; then
    echo "DOWN"
    exit 0
fi

psql -X -A -t -q \
    -h "$PGHOST" \
    -p "$PGPORT" \
    -U "$PGUSER" \
    -d "$PGDATABASE" \
    -c "
SELECT
  'UP'
  || '|total='   || count(*)
  || '|max='     || current_setting('max_connections')
  || '|active='  || count(*) FILTER (WHERE state = 'active')
  || '|idle='    || count(*) FILTER (WHERE state = 'idle')
  || '|idle_tx=' || count(*) FILTER (
       WHERE state = 'idle in transaction'
         AND xact_start IS NOT NULL
         AND now() - xact_start > interval '60 seconds'
     )
  || '|long_q='  || count(*) FILTER (
       WHERE state = 'active'
         AND query_start IS NOT NULL
         AND now() - query_start > interval '60 seconds'
     )
  || '|blocked=' || count(*) FILTER (
       WHERE wait_event_type = 'Lock'
     )
FROM pg_stat_activity;
" 2>/dev/null || echo "UNKNOWN|query_failed"
EOF
}


##### VPN Profile Functions ######

get_vpn() {
    ssh -o BatchMode=yes -o ConnectTimeout=3 "$remote_target" 'bash -s' <<'EOF' 2>/dev/null
WG_IF="wg0"

if ! command -v wg >/dev/null 2>&1; then
    echo "UNKNOWN|wg_missing"
    exit 0
fi

if ! ip link show "$WG_IF" >/dev/null 2>&1; then
    echo "DOWN|interface_missing"
    exit 0
fi

peer_count=$(wg show "$WG_IF" peers 2>/dev/null | awk 'NF {count++} END {print count+0}')
recent_count=$(wg show "$WG_IF" latest-handshakes 2>/dev/null | awk '
BEGIN {
    now = systime()
    recent = 0
}
NF >= 2 {
    if ($2 > 0 && (now - $2) <= 180) recent++
}
END {
    print recent+0
}')

echo "${peer_count}|${recent_count}|${WG_IF}"
EOF
}


status_from_vpn() {
    local peers="$1"
    local recent="$2"

    if [[ "$peers" -eq 0 ]]; then
        echo "WARNING"
    elif [[ "$recent" -eq 0 ]]; then
        echo "CRITICAL"
    elif [[ "$recent" -lt "$peers" ]]; then
        echo "WARNING"
    else
        echo "OK"
    fi
}



##### Main Script Logic and Formatting #####

if [[ "$mode" == "--once" ]]; then
    if ! remote_host=$(ssh -o ConnectTimeout=3 "$remote_target" 'hostname' 2>/dev/null); then
        remote_host="$remote_target"
    fi

    cpu_line=$(get_cpu || true)
    ram_line=$(get_ram || true)
    load_line=$(get_load || true)
    disk_line=$(get_disk || true)
    uptime_line=$(get_uptime || true)
    inode_line=$(get_inodes || true)

    if [[ -z "$cpu_line" && -z "$ram_line" && -z "$load_line" && -z "$disk_line" ]]; then
        echo "=== ${remote_host} (${remote_target}) ==="
	offline_colored=$(color_status "OFFLINE")
	printf "HOST : %b\n" "$offline_colored"
        #echo "HOST : OFFLINE"
        exit 0
    fi

    echo "=== ${remote_host} (${remote_target}) ==="

    if [[ -n "$cpu_line" ]]; then
        IFS='|' read -r cpu_user cpu_system cpu_iowait cpu_total <<< "$cpu_line"
        cpu_status=$(status_from_thresholds "$cpu_total" 20 70)

	cpu_status_colored=$(color_status "$cpu_status")
	printf "CPU  : %-8b user=%.1f%% system=%.1f%% iowait=%.1f%% total=%.1f%%\n" \
            "$cpu_status_colored" "$cpu_user" "$cpu_system" "$cpu_iowait" "$cpu_total"
    else
        echo "CPU  : UNKNOWN  unavailable"
    fi

    if [[ -n "$ram_line" ]]; then
        IFS='|' read -r ram_used_pct ram_total_mb <<< "$ram_line"
        ram_total_gib=$(awk -v t="$ram_total_mb" 'BEGIN { printf "%.2f", t/1024 }')
        ram_status=$(status_from_thresholds "$ram_used_pct" 70 90)

	ram_status_colored=$(color_status "$ram_status")

        printf "RAM  : %-8s used=%.0f%% total=%s GiB\n" \
            "$ram_status_colored" "$ram_used_pct" "$ram_total_gib"
    else
        echo "RAM  : UNKNOWN  unavailable"
    fi

    if [[ -n "$load_line" ]]; then
        IFS='|' read -r load1 cpus load_norm <<< "$load_line"
        load_status=$(status_from_thresholds "$load_norm" 70 100)
	load_status_colored=$(color_status "$load_status")
        printf "LOAD : %-8s load1=%s cpus=%s normalized=%s%%\n" \
            "$load_status_colored" "$load1" "$cpus" "$load_norm"
    else
        echo "LOAD : UNKNOWN  unavailable"
    fi

    if [[ -n "$disk_line" ]]; then
        IFS='|' read -r disk_used_pct disk_mount_out disk_size_k disk_used_k disk_avail_k <<< "$disk_line"
        disk_status=$(status_from_thresholds "$disk_used_pct" 80 90)
	disk_status_colored=$(color_status "$disk_status")
        printf "DISK : %-8s used=%s%% mount=%s\n" \
            "$disk_status_colored" "$disk_used_pct" "$disk_mount_out"
    else
        echo "DISK : UNKNOWN  unavailable"
    
    fi

	if [[ "$profile" == "db" ]]; then
		pg_line=$(get_postgres || true)

		if [[ -z "$pg_line" ]]; then
			echo "PG   : UNKNOWN  unavailable"
		elif [[ "$pg_line" == "DOWN" ]]; then
			pg_status_colored=$(color_status "CRITICAL")
			printf "PG   : %-8b down\n" "$pg_status_colored"
		elif [[ "$pg_line" == UNKNOWN\|* ]]; then
			pg_reason="${pg_line#UNKNOWN|}"
			printf "PG   : %-8s %s\n" "UNKNOWN" "$pg_reason"
		elif [[ "$pg_line" == UP\|* ]]; then
			IFS='|' read -r pg_state \
				pg_total_field \
				pg_max_field \
				pg_active_field \
				pg_idle_field \
				pg_idle_tx_field \
				pg_long_q_field \
				pg_blocked_field <<< "$pg_line"

			pg_total="${pg_total_field#total=}"
			pg_max="${pg_max_field#max=}"
			pg_active="${pg_active_field#active=}"
			pg_idle="${pg_idle_field#idle=}"
			pg_idle_tx="${pg_idle_tx_field#idle_tx=}"
			pg_long_q="${pg_long_q_field#long_q=}"
			pg_blocked="${pg_blocked_field#blocked=}"

			pg_used_pct=$(awk -v c="$pg_total" -v m="$pg_max" 'BEGIN {
				if (m > 0) printf "%.0f", (c/m)*100;
				else print 0
			}')

			pg_status=$(status_from_pg_metrics "$pg_used_pct" "$pg_idle_tx" "$pg_long_q" "$pg_blocked")
			pg_status_colored=$(color_status "$pg_status")

			printf "PG   : %-8b conns=%s/%s used=%s%% active=%s idle=%s idle_tx=%s long_q=%s blocked=%s\n" \
				"$pg_status_colored" \
				"$pg_total" "$pg_max" "$pg_used_pct" \
				"$pg_active" "$pg_idle" "$pg_idle_tx" "$pg_long_q" "$pg_blocked"
		else
			printf "PG   : %-8s %s\n" "UNKNOWN" "unexpected_output"
		fi
	fi

	if [[ "$profile" == "vpn" ]]; then
      		vpn_line=$(get_vpn || true)

        if [[ -z "$vpn_line" ]]; then
            echo "VPN  : UNKNOWN  unavailable"
        
    	elif [[ "$vpn_line" == UNKNOWN\|* ]]; then
            vpn_reason="${vpn_line#UNKNOWN|}"
            printf "VPN  : %-8s %s\n" "UNKNOWN" "$vpn_reason"
        
    	elif [[ "$vpn_line" == DOWN\|* ]]; then
            vpn_reason="${vpn_line#DOWN|}"
            vpn_status_colored=$(color_status "CRITICAL")
            printf "VPN  : %-8b %s\n" "$vpn_status_colored" "$vpn_reason"
        
    	else
            IFS='|' read -r vpn_peers vpn_recent vpn_if <<< "$vpn_line"
            vpn_status=$(status_from_vpn "$vpn_peers" "$vpn_recent")
            vpn_status_colored=$(color_status "$vpn_status")

            printf "VPN  : %-8b iface=%s peers=%s recent=%s\n" \
                "$vpn_status_colored" "$vpn_if" "$vpn_peers" "$vpn_recent"
        fi
    fi

    exit 0
fi

##### Script Execution #####

watch -n 2 -t -- "$0 $remote_target --once \"$disk_mount\" --profile \"$profile\""
