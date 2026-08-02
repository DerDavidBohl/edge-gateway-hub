#!/usr/bin/env bash
# edge-gateway-hub – List active public routing and private DNS site rules
# Usage: list.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../_lib.sh"

require_jq
require_sites

echo ""
printf '  %-30s  %-8s  %-8s  %-20s  %-18s  %s\n' \
    "DOMAIN / PORT" "TYPE" "PROTOCOL" "TARGET PEER" "TARGET IP" "TARGET PORT"
printf '  %-30s  %-8s  %-8s  %-20s  %-18s  %s\n' \
    "------------------------------" "--------" "--------" "--------------------" "------------------" "-----------"

site_count=0
while IFS=$'\t' read -r key type protocol target_peer target_port; do
    target_ip="$(peer_ip "$target_peer")" || exit 1
    printf '  %-30s  %-8s  %-8s  %-20s  %-18s  %s\n' \
        "$key" "$type" "$protocol" "$target_peer" "$target_ip" "$target_port"
    (( site_count++ )) || true
done < <(jq -r '.sites | to_entries[]
                | [.key,
                   .value.type,
                   (.value.protocol // "dns"),
                   .value.target_peer,
                   (.value.target_port // "-" | tostring)]
                | @tsv' "$SITES_FILE")

echo ""
printf '  Total: %d site(s)\n\n' "$site_count"
