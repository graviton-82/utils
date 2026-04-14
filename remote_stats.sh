#!/usr/bin/env bash

set -u

if [ $# -lt 1 ]; then
    echo "Usage: $0 user@ip-address [--once] [mount]"
    exit 1
fi

remote_target="$1"
mode="${2:-}"
disk_mount="${3:-/}"


RED="\033[0;31m"
YELLOW="\033[0;33m"
GREEN="\033[0;32m"
RESET="\033[0m"

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


if [[ "$mode" == "--once" ]]; then
    if ! remote_host=$(ssh -o ConnectTimeout=3 "$remote_target" 'hostname' 2>/dev/null); then
        remote_host="$remote_target"
    fi

    cpu_line=$(get_cpu || true)
    ram_line=$(get_ram || true)
    load_line=$(get_load || true)
    disk_line=$(get_disk || true)

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

    exit 0
fi

watch -n 2 -- "$0 $remote_target --once \"$disk_mount\""
