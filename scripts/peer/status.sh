#!/usr/bin/env bash
# edge-gateway-hub – Show live WireGuard peer status
# Usage: status.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../_lib.sh"

readonly FRESH_HANDSHAKE_SECONDS=180

format_bytes() {
    awk -v bytes="$1" '
        BEGIN {
            split("B KiB MiB GiB TiB", units, " ")
            unit = 1
            while (bytes >= 1024 && unit < 5) {
                bytes /= 1024
                unit++
            }
            if (unit == 1) {
                printf "%d %s", bytes, units[unit]
            } else {
                printf "%.1f %s", bytes, units[unit]
            }
        }
    '
}

format_handshake_age() {
    local seconds="$1"

    if (( seconds < 60 )); then
        printf '%ds ago' "$seconds"
    elif (( seconds < 3600 )); then
        printf '%dm ago' "$((seconds / 60))"
    elif (( seconds < 86400 )); then
        printf '%dh ago' "$((seconds / 3600))"
    else
        printf '%dd ago' "$((seconds / 86400))"
    fi
}

require_jq
require_ipam
require_docker

docker inspect --format '{{.State.Running}}' wireguard 2>/dev/null | grep -qx true || {
    echo "Error: WireGuard container is not running." >&2
    echo "Start with: docker compose up -d" >&2
    exit 1
}

WG_DUMP="$(docker exec wireguard wg show wg0 dump)" || {
    echo "Error: Unable to read WireGuard interface status from the container." >&2
    exit 1
}

declare -A endpoints handshakes received sent

while IFS=$'\t' read -r public_key _ endpoint _ handshake rx tx _; do
    [[ -n "$public_key" ]] || continue
    endpoints["$public_key"]="$endpoint"
    handshakes["$public_key"]="$handshake"
    received["$public_key"]="$rx"
    sent["$public_key"]="$tx"
done < <(tail -n +2 <<< "$WG_DUMP")

now="$(date +%s)"

echo ""
printf '  %-20s  %-10s  %-16s  %-10s  %-13s  %-10s  %-10s  %s\n' \
    "NAME" "TYPE" "IP" "STATUS" "LAST HANDSHAKE" "RECEIVED" "SENT" "ENDPOINT"
printf '  %-20s  %-10s  %-16s  %-10s  %-13s  %-10s  %-10s  %s\n' \
    "--------------------" "----------" "----------------" "----------" "-------------" \
    "----------" "----------" "-------------------------"

peer_count=0
while IFS=$'\t' read -r name type ip public_key; do
    handshake="${handshakes[$public_key]:-0}"
    rx="${received[$public_key]:-0}"
    tx="${sent[$public_key]:-0}"
    endpoint="${endpoints[$public_key]:--}"

    if (( handshake == 0 )); then
        status="never"
        handshake_age="never"
    else
        age=$((now - handshake))
        (( age < 0 )) && age=0
        handshake_age="$(format_handshake_age "$age")"
        if (( age <= FRESH_HANDSHAKE_SECONDS )); then
            status="connected"
        else
            status="stale"
        fi
    fi

    printf '  %-20s  %-10s  %-16s  %-10s  %-13s  %-10s  %-10s  %s\n' \
        "$name" "$type" "$ip" "$status" "$handshake_age" \
        "$(format_bytes "$rx")" "$(format_bytes "$tx")" "$endpoint"
    (( peer_count++ )) || true
done < <(jq -r '.peers | to_entries[]
                | [.key, .value.type, .value.ip, .value.public_key]
                | @tsv' "$IPAM_FILE")

echo ""
printf '  Total: %d peer(s); connected = handshake within %d minutes\n\n' \
    "$peer_count" "$((FRESH_HANDSHAKE_SECONDS / 60))"
