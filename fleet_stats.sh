#!/usr/bin/env bash

set -u

FLEET_FILE="${1:-fleet_list.txt}"
INTERVAL="${2:-2}"

if [[ ! -f "$FLEET_FILE" ]]; then
    echo "Error: file not found: $FLEET_FILE"
    exit 1
fi

while true; do
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue

        ./remote_stats.sh $line --once </dev/null

        echo
    done < "$FLEET_FILE"

    sleep "$INTERVAL"
done
