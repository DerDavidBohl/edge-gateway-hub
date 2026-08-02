#!/usr/bin/env bash
# edge-gateway-hub – Remove a public routing or private DNS site rule
# Usage: remove.sh <domain|port>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../_lib.sh"

# ─── Usage ────────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: $(basename "$0") <domain|port>

  domain|port   The key originally passed to site/add.sh

Examples:
  $(basename "$0") example.com
  $(basename "$0") 8080
EOF
    exit 1
}

[[ $# -eq 1 ]] || usage

KEY="$1"

# ─── Validate ─────────────────────────────────────────────────────────────────

require_jq
require_sites

jq -e --arg k "$KEY" '.sites | has($k)' "$SITES_FILE" &>/dev/null || {
    echo "Error: Site '$KEY' not found." >&2
    exit 1
}

# ─── Remove from sites.json ───────────────────────────────────────────────────

echo "Removing site '$KEY'..."

jq --arg key "$KEY" 'del(.sites[$key])' "$SITES_FILE" > "${SITES_FILE}.tmp"
mv "${SITES_FILE}.tmp" "$SITES_FILE"

# ─── Regenerate Nginx and private DNS configs ─────────────────────────────────

rebuild_nginx_configs
rebuild_dns_hosts
reload_nginx
reload_coredns

echo ""
echo "✓ Site '$KEY' removed successfully."
echo ""
