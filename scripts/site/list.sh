#!/usr/bin/env bash
# edge-gateway-hub – List active Nginx stream routing rules
# Usage: list.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../_lib.sh"

require_jq
require_sites

echo ""
printf '  %-30s  %-8s  %-8s  %-18s  %s\n' \
    "DOMAIN / PORT" "TYPE" "PROTOCOL" "TARGET IP" "TARGET PORT"
printf '  %-30s  %-8s  %-8s  %-18s  %s\n' \
    "------------------------------" "--------" "--------" "------------------" "-----------"

site_count=0
while IFS=$'\t' read -r key type protocol target_ip target_port; do
    printf '  %-30s  %-8s  %-8s  %-18s  %s\n' \
        "$key" "$type" "$protocol" "$target_ip" "$target_port"
    (( site_count++ )) || true
done < <(jq -r '.sites | to_entries[]
                | [.key,
                   .value.type,
                   .value.protocol,
                   .value.target_ip,
                   (.value.target_port | tostring)]
                | @tsv' "$SITES_FILE")

echo ""
printf '  Total: %d site(s)\n\n' "$site_count"
