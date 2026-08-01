#!/usr/bin/env bash
# edge-gateway-hub – List active WireGuard peers
# Usage: list.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../_lib.sh"

require_jq
require_ipam

echo ""
printf '  %-20s  %-10s  %-16s  %s\n' "NAME" "TYPE" "IP" "PUBLIC KEY (truncated)"
printf '  %-20s  %-10s  %-16s  %s\n' \
    "--------------------" "----------" "----------------" "-------------------------------"

peer_count=0
while IFS=$'\t' read -r name type ip pubkey; do
    printf '  %-20s  %-10s  %-16s  %s\n' \
        "$name" "$type" "$ip" "${pubkey:0:28}..."
    (( peer_count++ )) || true
done < <(jq -r '.peers | to_entries[]
                | [.key, .value.type, .value.ip, .value.public_key]
                | @tsv' "$IPAM_FILE")

echo ""
printf '  Total: %d peer(s)\n\n' "$peer_count"
