#!/usr/bin/env bash
# Linux monitoring over a single SSH session per snapshot.
set -uo pipefail

usage() {
    cat <<'EOF'
Usage: remote_stats.sh <ssh-target|localhost> [--once] [mount] [options]
  --profile base|db|vpn   Additional service metrics (default: base)
  --interval SECONDS     Refresh delay (default: 2)
  --timeout SECONDS      Overall snapshot deadline (default: 30)
  --no-color            Disable ANSI colors (also honors NO_COLOR)
  --json                JSON snapshot; implies --once
  --debug               Print sanitized collection failure reasons to stderr
  --help                Show this help
Configuration: see REMOTESTATS.md for RS_* environment variables.
Exit codes: 0 complete snapshot (including unhealthy services),
            1 incomplete collection, 2 invalid arguments/configuration.
EOF
}
fail() { printf 'remote_stats: %s\n' "$*" >&2; return 2; }
uint() { [[ "$1" =~ ^(0|[1-9][0-9]{0,8})$ ]]; }
positive() { uint "$1" && (( $1 > 0 )); }
threshold_status() {
    awk -v v="$1" -v w="$2" -v c="$3" 'BEGIN {
        print (v >= c ? "CRITICAL" : v >= w ? "WARNING" : "OK")
    }'
}

# Collector functions execute on the monitored host. Records contain no secrets.
metric_error() { printf '%s|UNKNOWN|%s\n' "$1" "$2"; }
netdata_metric() {
    local metric="$1" chart="$2" body value
    if ! body=$(curl -fsS --connect-timeout "$http_timeout" --max-time "$http_timeout" \
        "${netdata_url%/}/api/v1/data?chart=$chart"); then
        metric_error "$metric" http_failed; return
    fi
    if ! value=$(printf '%s' "$body" | jq -er --arg kind "$metric" '
        .labels as $labels |
        if (.data | type) != "array" or (.data | length) == 0 then error("no samples") else . end |
        ($labels | index("time")) as $ti |
        if $ti == null then error("no timestamp") else . end |
        if any(.data[]; (.[ $ti ] | type) != "number") then error("bad timestamp") else . end |
        (.data | max_by(.[$ti])) as $sample |
        (if $kind == "CPU" then ["user", "system", "iowait"]
         else ["used", "free", "cached", "buffers"] end) as $names |
        [$names[] | . as $name | ($labels | index($name)) as $i |
            if $i == null then error("missing dimension") else $sample[$i] end] as $v |
        if any($v[]; type != "number" or . < 0) then error("invalid dimension") else . end |
        if $kind == "CPU" then $v + [($v | add)]
        elif ($v | add) > 0 then [($v[0] / ($v | add) * 100), ($v | add)]
        else error("invalid RAM total") end | map(tostring) | join("|")'); then
        metric_error "$metric" invalid_sample; return
    fi
    printf '%s|VALUE|%s\n' "$metric" "$value"
}
collect_disk() {
    local metric="$1" flag="$2" value
    if ! value=$(df "$flag" -- "$disk_mount" | awk 'NR==2 {
        gsub(/%/, "", $5); if ($5 ~ /^[0-9]+$/) print $5
    }') || [[ -z "$value" ]]; then
        metric_error "$metric" df_failed
    else
        printf '%s|VALUE|%s\n' "$metric" "$value"
    fi
}
collect_pg() {
    local value
    if ! command -v psql >/dev/null || ! command -v pg_isready >/dev/null; then
        metric_error PG client_missing; return
    fi
    export PGHOST="$pg_host" PGPORT="$pg_port" PGUSER="$pg_user" PGDATABASE="$pg_database"
    export PGCONNECT_TIMEOUT="$http_timeout" PGOPTIONS="-c statement_timeout=${http_timeout}000"
    if ! pg_isready -q -t "$http_timeout"; then
        printf 'PG|CRITICAL|not_accepting_connections\n'; return
    fi
    if ! value=$(psql -w -X -A -t -q -v ON_ERROR_STOP=1 -c "
SELECT count(*) || '|' || current_setting('max_connections')
 || '|' || count(*) FILTER (WHERE state = 'active')
 || '|' || count(*) FILTER (WHERE state = 'idle')
 || '|' || count(*) FILTER (WHERE state = 'idle in transaction'
      AND now() - xact_start > interval '60 seconds')
 || '|' || count(*) FILTER (WHERE state = 'active'
      AND now() - query_start > interval '60 seconds')
 || '|' || count(*) FILTER (WHERE wait_event_type = 'Lock')
FROM pg_stat_activity WHERE backend_type = 'client backend' AND pid <> pg_backend_pid();"); then
        metric_error PG query_failed; return
    fi
    if [[ "$value" =~ ^[0-9]+\|[1-9][0-9]*\|[0-9]+\|[0-9]+\|[0-9]+\|[0-9]+\|[0-9]+$ ]]; then
        printf 'PG|VALUE|%s\n' "$value"
    else
        metric_error PG invalid_response
    fi
}
collect_vpn() {
    local value peers active newest
    if ! command -v ip >/dev/null || ! command -v sudo >/dev/null; then
        metric_error VPN client_missing; return
    fi
    if ! ip link show dev "$wg_interface" >/dev/null; then
        printf 'VPN|CRITICAL|interface_missing\n'; return
    fi
    if ! value=$(sudo -n /usr/local/bin/wg-dashboard-stats "$wg_interface" "$wg_recent"); then
        printf 'VPN|CRITICAL|helper_unavailable\n'; return
    fi
    if [[ ! "$value" =~ ^(0|[1-9][0-9]{0,8})\|(0|[1-9][0-9]{0,8})\|(-1|0|[1-9][0-9]{0,11})$ ]]; then
        metric_error VPN invalid_response; return
    fi
    IFS='|' read -r peers active newest <<< "$value"
    if (( active > peers || (peers == 0 && newest != -1) || (newest == -1 && active != 0) )); then
        metric_error VPN invalid_response; return
    fi
    printf 'VPN|VALUE|%s\n' "$value"
}
collect_snapshot() {
    local load cpus seconds
    printf 'HOST|OK|%s\n' "$(hostname)"
    if read -r seconds _ < /proc/uptime; then
        awk -v s="$seconds" 'BEGIN {printf "UP|VALUE|%dd%dh%dm\n", s/86400, (s%86400)/3600, (s%3600)/60}'
    else
        metric_error UP unavailable
    fi
    netdata_metric CPU system.cpu
    netdata_metric RAM system.ram
    if read -r load _ < /proc/loadavg && cpus=$(getconf _NPROCESSORS_ONLN) && positive "$cpus"; then
        awk -v l="$load" -v c="$cpus" 'BEGIN {printf "LOAD|VALUE|%.2f|%d|%.0f\n", l,c,l/c*100}'
    else
        metric_error LOAD unavailable
    fi
    collect_disk DISK -P
    collect_disk INOD -Pi
    case "$profile" in db) collect_pg ;; vpn) collect_vpn ;; esac
}

# printf %q creates Bash source, consumed by bash -s rather than the SSH login shell.
# Arguments are never interpolated into the SSH command string.
collector_source() {
    local name
    printf 'set -uo pipefail\nexport LC_ALL=C\n'
    for name in disk_mount profile http_timeout netdata_url pg_host pg_port pg_user pg_database wg_interface wg_recent; do
        printf '%s=%q\n' "$name" "${!name}"
    done
    declare -f uint positive metric_error netdata_metric collect_disk collect_pg collect_vpn collect_snapshot
    printf '\ncollect_snapshot\n'
}

add_record() {
    local name="$1" status="$2" detail="$3"
    names+=("$name"); statuses+=("$status"); details+=("$detail")
    [[ "$status" != UNKNOWN && "$status" != OFFLINE ]] || incomplete=1
    if (( debug )) && [[ "$status" == UNKNOWN || "$status" == OFFLINE || "$detail" == helper_unavailable ]]; then
        printf 'remote_stats: %s: %s\n' "$name" "$detail" >&2
    fi
}
parse_snapshot() {
    local data="$1" name state value a b c d e f g status detail
    local numeric='[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?'
    local -A seen=()
    names=(); statuses=(); details=(); incomplete=0; remote_host="$target"; uptime_text=""
    while IFS='|' read -r name state value; do
        case "$name" in HOST|UP|CPU|RAM|LOAD|DISK|INOD|PG|VPN) ;; *) continue ;; esac
        [[ ! ${seen[$name]+exists} ]] || continue
        seen[$name]=1
        if [[ "$name" == HOST && "$state" == OK && -n "$value" ]]; then
            remote_host="$value"; continue
        fi
        if [[ "$name" == UP && "$state" == VALUE && "$value" =~ ^[0-9]+d[0-9]+h[0-9]+m$ ]]; then
            uptime_text="$value"; continue
        fi
        if [[ "$state" == UNKNOWN || "$state" == CRITICAL ]]; then
            # Only known reason tokens are displayed; collector stderr and raw responses may contain secrets.
            case "$value" in
                http_failed|invalid_sample|df_failed|client_missing|query_failed|invalid_response|unavailable|not_accepting_connections|interface_missing|helper_unavailable) ;;
                *) value=invalid_response; state=UNKNOWN ;;
            esac
            add_record "$name" "$state" "$value"
            [[ "$value" != helper_unavailable ]] || incomplete=1
            continue
        fi
        status=UNKNOWN; detail=invalid_response
        if [[ "$state" == VALUE ]]; then
            IFS='|' read -r a b c d e f g <<< "$value"
            case "$name" in
                CPU)
                    if [[ "$value" =~ ^$numeric\|$numeric\|$numeric\|$numeric$ ]]; then
                        status=$(threshold_status "$d" "$cpu_warn" "$cpu_crit")
                        printf -v detail 'user=%.1f%% system=%.1f%% iowait=%.1f%% total=%.1f%%' "$a" "$b" "$c" "$d"
                    fi ;;
                RAM)
                    if [[ "$value" =~ ^$numeric\|$numeric$ ]]; then
                        status=$(threshold_status "$a" "$ram_warn" "$ram_crit")
                        detail=$(awk -v p="$a" -v m="$b" 'BEGIN {printf "used=%.0f%% total=%.2f GiB",p,m/1024}')
                    fi ;;
                LOAD)
                    if [[ "$value" =~ ^[0-9]+([.][0-9]+)?\|[1-9][0-9]*\|[0-9]+$ ]]; then
                        status=$(threshold_status "$c" "$load_warn" "$load_crit")
                        detail="load1=$a cpus=$b normalized=$c%"
                    fi ;;
                DISK|INOD)
                    if uint "$value" && (( value <= 100 )); then
                        status=$(threshold_status "$value" "$disk_warn" "$disk_crit")
                        detail="used=$value% mount=$disk_mount"
                    fi ;;
                PG)
                    if [[ "$value" =~ ^[0-9]+\|[1-9][0-9]*\|[0-9]+\|[0-9]+\|[0-9]+\|[0-9]+\|[0-9]+$ ]]; then
                        local pct
                        pct=$(awk -v n="$a" -v m="$b" 'BEGIN {printf "%.0f",n/m*100}')
                        status=$(threshold_status "$pct" "$pg_warn" "$pg_crit")
                        if (( g > 0 )); then status=CRITICAL
                        elif [[ "$status" == OK ]] && (( e > 0 || f > 0 )); then status=WARNING; fi
                        detail="conns=$a/$b used=$pct% active=$c idle=$d idle_tx=$e long_q=$f blocked=$g"
                    fi ;;
                VPN)
                    if [[ "$value" =~ ^(0|[1-9][0-9]{0,8})\|(0|[1-9][0-9]{0,8})\|(-1|0|[1-9][0-9]{0,11})$ ]] && (( b <= a && (a > 0 || c == -1) && (c != -1 || b == 0) )); then
                        status=OK
                        if (( c == -1 || c > wg_recent )); then
                            detail="iface=$wg_interface active=$b/$a newest=${c}s idle_or_no_handshake"
                        else
                            detail="iface=$wg_interface active=$b/$a newest=${c}s"
                        fi
                    fi ;;
            esac
        fi
        add_record "$name" "$status" "$detail"
    done <<< "$data"
    if [[ ! ${seen[HOST]+exists} || "$data" != HOST\|OK\|* ]]; then
        names=(); statuses=(); details=()
        add_record HOST OFFLINE connection_or_deadline_failed
        return
    fi
    for name in UP CPU RAM LOAD DISK INOD; do
        [[ ${seen[$name]+exists} ]] || add_record "$name" UNKNOWN missing_record
    done
    case "$profile" in
        db) [[ ${seen[PG]+exists} ]] || add_record PG UNKNOWN missing_record ;;
        vpn) [[ ${seen[VPN]+exists} ]] || add_record VPN UNKNOWN missing_record ;;
    esac
}
render_snapshot() {
    local i status color
    if (( json )); then
        {
            printf '%s\0%s\0%s\0' "$target" "$remote_host" "$uptime_text"
            for i in "${!names[@]}"; do printf '%s\0%s\0%s\0' "${names[$i]}" "${statuses[$i]}" "${details[$i]}"; done
        } | jq -Rs 'split("\u0000") | .[:-1] |
            {target:.[0],host:.[1],uptime:.[2],metrics:(.[3:] | [range(0;length;3) as $i |
            {name:.[$i],status:.[$i+1],detail:.[$i+2]}])}'
        return
    fi
    printf '=== %s (%s)' "$remote_host" "$target"
    [[ -z "$uptime_text" ]] || printf ' | UP %s' "$uptime_text"
    printf ' ===\n'
    for i in "${!names[@]}"; do
        status="${statuses[$i]}"; color=""
        if (( use_color )); then
            case "$status" in OK) color=$'\033[32m' ;; WARNING|UNKNOWN) color=$'\033[33m' ;; *) color=$'\033[31m' ;; esac
        fi
        printf '%-5s: %s%-9s' "${names[$i]}" "$color" "$status"
        (( ! use_color )) || printf '\033[0m'
        printf ' %s\n' "${details[$i]}"
    done
}
snapshot() {
    local data rc=0
    if [[ "$target" == localhost || "$target" == 127.0.0.1 || "$target" == "$(hostname)" ]]; then
        data=$(collector_source | timeout --signal=TERM --kill-after=2 "$deadline" bash -s 2>/dev/null) || rc=$?
    else
        data=$(collector_source | timeout --signal=TERM --kill-after=2 "$deadline" \
            ssh -T -o BatchMode=yes -o ConnectTimeout=3 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 \
            "$target" 'bash -s' 2>/dev/null) || rc=$?
    fi
    parse_snapshot "$data"
    if (( rc != 0 )); then
        incomplete=1
        if [[ "$data" == HOST\|OK\|* ]]; then add_record COLLECTION UNKNOWN deadline_or_transport_failed; fi
        (( ! debug )) || printf 'remote_stats: transport/collector exit=%s\n' "$rc" >&2
    fi
    render_snapshot || return 1
    (( incomplete == 0 ))
}
main() {
    export LC_ALL=C
    local target="" profile=base disk_mount=/ mount_set=0 once=0 json=0 debug=0 use_color=0
    local interval="${RS_INTERVAL:-2}" deadline="${RS_TIMEOUT:-30}" http_timeout="${RS_HTTP_TIMEOUT:-5}"
    local netdata_url="${RS_NETDATA_URL:-http://localhost:19999}"
    local pg_host="${RS_PGHOST:-localhost}" pg_port="${RS_PGPORT:-5432}"
    local pg_user="${RS_PGUSER:-remote_monitor}" pg_database="${RS_PGDATABASE:-postgres}"
    local wg_interface="${RS_WG_INTERFACE:-wg0}" wg_recent="${RS_WG_RECENT:-600}"
    local cpu_warn="${RS_CPU_WARN:-20}" cpu_crit="${RS_CPU_CRIT:-70}"
    local ram_warn="${RS_RAM_WARN:-70}" ram_crit="${RS_RAM_CRIT:-90}"
    local load_warn="${RS_LOAD_WARN:-100}" load_crit="${RS_LOAD_CRIT:-200}"
    local disk_warn="${RS_DISK_WARN:-80}" disk_crit="${RS_DISK_CRIT:-90}"
    local pg_warn="${RS_PG_WARN:-80}" pg_crit="${RS_PG_CRIT:-90}"
    local name warn crit result=0 remote_host uptime_text incomplete
    local -a names=() statuses=() details=()
    [[ ! -t 1 || ${NO_COLOR+x} ]] || use_color=1
    while (( $# )); do
        case "$1" in
            --help|-h) usage; return 0 ;;
            --once) once=1 ;;
            --no-color) use_color=0 ;;
            --json) json=1; once=1; use_color=0 ;;
            --debug) debug=1 ;;
            --profile|--interval|--timeout)
                if (( $# < 2 )) || [[ -z "$2" || "$2" == --* ]]; then
                    fail "missing value for $1"; return 2
                fi
                case "$1" in --profile) profile="$2" ;; --interval) interval="$2" ;; --timeout) deadline="$2" ;; esac
                shift ;;
            -*) fail "unknown option: $1"; return 2 ;;
            *)
                if [[ -z "$target" ]]; then target="$1"
                elif (( ! mount_set )); then disk_mount="$1"; mount_set=1
                else fail 'too many positional arguments'; return 2; fi ;;
        esac
        shift
    done
    [[ -n "$target" ]] || { usage >&2; return 2; }
    [[ "$target" =~ ^[a-zA-Z0-9_@.:][a-zA-Z0-9_@.:%+-]*$ ]] || { fail 'invalid SSH target'; return 2; }
    [[ "$profile" == base || "$profile" == db || "$profile" == vpn ]] || { fail 'invalid profile'; return 2; }
    [[ "$disk_mount" != *$'\n'* && "$disk_mount" != *$'\r'* && "$disk_mount" != *'|'* ]] || { fail 'mount contains unsupported delimiter'; return 2; }
    for name in interval deadline http_timeout wg_recent pg_port; do
        positive "${!name}" || { fail "invalid $name"; return 2; }
    done
    (( pg_port <= 65535 )) || { fail 'invalid PostgreSQL port'; return 2; }
    [[ "$wg_interface" =~ ^[a-zA-Z0-9_=+.-]{1,15}$ && "$wg_interface" != -* ]] || { fail 'invalid WireGuard interface'; return 2; }
    [[ "$netdata_url" =~ ^https?://[^[:space:]]+$ && "$netdata_url" != *'@'* && "$netdata_url" != *'?'* && "$netdata_url" != *'#'* ]] || { fail 'invalid Netdata base URL (no credentials/query/fragment)'; return 2; }
    for name in cpu ram load disk pg; do
        warn="${name}_warn"; crit="${name}_crit"
        if ! uint "${!warn}" || ! positive "${!crit}" || (( ${!warn} >= ${!crit} )); then
            fail "invalid $name thresholds"; return 2
        fi
        [[ "$name" == load ]] || (( ${!crit} <= 100 )) || { fail "$name threshold exceeds 100"; return 2; }
    done
    command -v timeout >/dev/null || { fail 'local GNU timeout is required'; return 2; }
    if (( json )); then command -v jq >/dev/null || { fail 'local jq is required for --json'; return 2; }; fi
    if (( once )); then snapshot; return $?; fi
    trap 'exit 130' INT
    trap 'exit 143' TERM
    while :; do
        if [[ -t 1 ]]; then printf '\033[H\033[2J'; fi
        snapshot || result=$?
        sleep "$interval" || return "$result"
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
