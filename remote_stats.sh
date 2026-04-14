#!/usr/bin/env bash

set -u

if [ $# -lt 1 ]; then
    echo "Usage: $0 user@ip-address"
    exit 1
fi

remote_target="$1"

# One-shot mode (called by watch)
if [[ "${2:-}" == "--once" ]]; then
    if ! remote_host=$(ssh -o ConnectTimeout=3 "$remote_target" 'hostname' 2>/dev/null); then
        remote_host="$remote_target"
    fi

    get_stat() {
        local chart="$1"

        ssh -o BatchMode=yes -o ConnectTimeout=3 "$remote_target" \
            "curl -fsS \"http://localhost:19999/api/v1/data?chart=${chart}\" | jq -r '.data[-1]'" \
            2>/dev/null || echo "offline/unreachable"
    }

    echo "=== ${remote_host} CPU ==="
    echo "=== (${remote_target}) ==="
    get_stat "system.cpu"
    echo
    echo "=== ${remote_host} RAM ==="
    echo "=== (${remote_target}) ==="
    get_stat "system.ram"

    exit 0
fi

# Main mode → start watch
watch -n 2 "$0 $remote_target --once"
