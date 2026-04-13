#!/usr/bin/env bash

set -u

if [ $# -ne 1 ]; then
    echo "Usage: $0 user@ip-address"
    exit 1
fi

remote_target="$1"

if ! remote_host=$(ssh "$remote_target" 'hostname' 2>/dev/null); then
    echo "Error: could not connect to $remote_target"
    exit 1
fi

read -r -d '' WATCH_CMD <<EOF
echo '=== ${remote_host} CPU ==='
echo '=== (${remote_target}) ==='
ssh ${remote_target@Q} 'curl -s "http://localhost:19999/api/v1/data?chart=system.cpu" | jq -r ".data[-1]"'
echo
echo '=== ${remote_host} RAM ==='
echo '=== (${remote_target}) ==='
ssh ${remote_target@Q} 'curl -s "http://localhost:19999/api/v1/data?chart=system.ram" | jq -r ".data[-1]"'
EOF

watch -n 2 "$WATCH_CMD"
