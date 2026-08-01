#!/usr/bin/env bash
# edge-gateway-hub – Remove a WireGuard peer
# Usage: remove.sh <name>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../_lib.sh"

# ─── Usage ────────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: $(basename "$0") <name>

  name   Name of the peer to remove

Example:
  $(basename "$0") alice
EOF
    exit 1
}

[[ $# -eq 1 ]] || usage

NAME="$1"

# ─── Validate ─────────────────────────────────────────────────────────────────

require_jq
require_ipam

jq -e --arg n "$NAME" '.peers | has($n)' "$IPAM_FILE" &>/dev/null || {
    echo "Error: Peer '$NAME' not found in IPAM." >&2
    exit 1
}

# ─── Remove from IPAM ─────────────────────────────────────────────────────────

echo "Removing peer '$NAME'..."

jq --arg name "$NAME" 'del(.peers[$name])' "$IPAM_FILE" > "${IPAM_FILE}.tmp"
mv "${IPAM_FILE}.tmp" "$IPAM_FILE"

# ─── Remove from WireGuard server config and hot-reload ──────────────────────

remove_wg_peer "$NAME"
reload_wireguard

# ─── Remove key files and client config ───────────────────────────────────────

if [[ -d "${KEYS_DIR}/$NAME" ]]; then
    rm -rf "${KEYS_DIR:?}/$NAME"
    echo "  Deleted key directory: $KEYS_DIR/$NAME"
fi

echo ""
echo "✓ Peer '$NAME' removed successfully."
echo ""
