#!/usr/bin/env bash
# edge-gateway-hub – Add an Nginx stream routing rule
# Usage: add.sh <domain|port> <target-peer-name> <target-port> [protocol]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../_lib.sh"

# ─── Usage ────────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: $(basename "$0") <domain|port> <target-peer-name> <target-port> [protocol]

  domain|port   Domain name → TCP SNI passthrough on port 443
                Port number → port-based TCP or UDP forwarding
  target-peer-name
                Name of a registered Edge Service Peer (e.g. webserver)
  target-port   Port on the target peer
  protocol      tcp (default) or udp  — only relevant for port-based routing

Examples:
  $(basename "$0") example.com   webserver 443
  $(basename "$0") api.foo.bar   webserver 8080
  $(basename "$0") 8080          webserver 8080 tcp
  $(basename "$0") 53            dns-server 53 udp
EOF
    exit 1
}

[[ $# -ge 3 ]] || usage

KEY="$1"
TARGET_PEER="$2"
TARGET_PORT="$3"
PROTOCOL="${4:-tcp}"

is_valid_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 ))
}

# ─── Validate inputs ──────────────────────────────────────────────────────────

require_jq
require_sites

[[ "$PROTOCOL" =~ ^(tcp|udp)$ ]] || {
    echo "Error: Protocol must be 'tcp' or 'udp'." >&2
    exit 1
}

is_valid_port "$TARGET_PORT" || {
    echo "Error: target-port must be a number in range 1-65535." >&2
    exit 1
}

TARGET_IP="$(edge_peer_ip "$TARGET_PEER")" || exit 1

if jq -e --arg k "$KEY" '.sites | has($k)' "$SITES_FILE" &>/dev/null; then
    echo "Error: Site '$KEY' already exists. Use scripts/site/remove.sh to delete it first." >&2
    exit 1
fi

# ─── Determine routing type ───────────────────────────────────────────────────
# A numeric key → port-based routing; anything else → domain SNI routing.

if [[ "$KEY" =~ ^[0-9]+$ ]]; then
    is_valid_port "$KEY" || {
        echo "Error: source port must be in range 1-65535." >&2
        exit 1
    }
    SITE_TYPE="port"
    SOURCE_PORT="$KEY"
else
    SITE_TYPE="domain"
    SOURCE_PORT=443
    PROTOCOL="tcp"   # SNI passthrough is always TCP
fi

echo "Adding site '$KEY' ($SITE_TYPE) → $TARGET_PEER ($TARGET_IP):$TARGET_PORT ($PROTOCOL)..."

# ─── Update sites.json ────────────────────────────────────────────────────────

jq --arg  key         "$KEY" \
   --arg  type        "$SITE_TYPE" \
   --arg  target_peer "$TARGET_PEER" \
   --argjson target_port  "$TARGET_PORT" \
   --argjson source_port  "$SOURCE_PORT" \
   --arg  protocol    "$PROTOCOL" \
   '.sites[$key] = {
       type:        $type,
       target_peer: $target_peer,
       target_port: $target_port,
       source_port: $source_port,
       protocol:    $protocol
   }' "$SITES_FILE" > "${SITES_FILE}.tmp"
mv "${SITES_FILE}.tmp" "$SITES_FILE"

# ─── Regenerate Nginx configs and reload ──────────────────────────────────────

rebuild_nginx_configs
reload_nginx

# ─── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "✓ Site '$KEY' added successfully."
echo ""
if [[ "$SITE_TYPE" == "domain" ]]; then
    printf '  TCP SNI passthrough: HTTPS for %-20s → %s:%s\n' \
        "$KEY" "$TARGET_PEER ($TARGET_IP)" "$TARGET_PORT"
else
    printf '  Port forwarding:     %-4s %-6s%-20s → %s:%s\n' \
        "$PROTOCOL" "port" "$SOURCE_PORT" "$TARGET_PEER ($TARGET_IP)" "$TARGET_PORT"
fi
echo ""
