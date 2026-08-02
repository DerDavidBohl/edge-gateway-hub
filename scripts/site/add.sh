#!/usr/bin/env bash
# edge-gateway-hub – Add a public routing or private DNS site rule
# Usage: add.sh <domain|port> <target-peer-name> [target-port] [protocol]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../_lib.sh"

# ─── Usage ────────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: $(basename "$0") <domain|port> <target-peer-name> [target-port] [protocol]

  domain|port   Domain name → private DNS record for an Internal Node, or
                TCP SNI passthrough on port 443 for an Edge Service Peer
                Prefix with '*.': route all subdomains (not the parent domain)
                Port number → port-based TCP or UDP forwarding to an Edge Peer
  target-peer-name
                Name of a registered Internal Node or Edge Service Peer
  target-port   Required for Edge Service Peers; omitted for Internal Nodes
  protocol      tcp (default) or udp  — only relevant for port-based routing

Examples:
  $(basename "$0") app.home.arpa homeserver
  $(basename "$0") example.com   webserver 443
  $(basename "$0") '*.example.com' webserver 443
  $(basename "$0") api.foo.bar   webserver 8080
  $(basename "$0") 8080          webserver 8080 tcp
  $(basename "$0") 53            dns-server 53 udp
EOF
    exit 1
}

[[ $# -ge 2 && $# -le 4 ]] || usage

KEY="$1"
TARGET_PEER="$2"
TARGET_PORT="${3:-}"
PROTOCOL="${4:-tcp}"

is_valid_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 ))
}

is_valid_domain() {
    local domain="$1"
    domain="${domain#\*.}"
    [[ ${#domain} -le 253 ]] &&
        [[ "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

# ─── Validate inputs ──────────────────────────────────────────────────────────

require_jq
require_sites

TARGET_TYPE="$(peer_type "$TARGET_PEER")" || exit 1
TARGET_IP="$(peer_ip "$TARGET_PEER")" || exit 1

if jq -e --arg k "$KEY" '.sites | has($k)' "$SITES_FILE" &>/dev/null; then
    echo "Error: Site '$KEY' already exists. Use scripts/site/remove.sh to delete it first." >&2
    exit 1
fi

# ─── Determine routing type ───────────────────────────────────────────────────
# A numeric key → port-based routing; anything else → domain SNI routing.

if [[ "$KEY" =~ ^[0-9]+$ ]]; then
    [[ "$TARGET_TYPE" == "edge" ]] || {
        echo "Error: Port routes require an Edge Service Peer." >&2
        exit 1
    }
    [[ -n "$TARGET_PORT" ]] || {
        echo "Error: target-port is required for an Edge Service Peer." >&2
        exit 1
    }
    [[ "$PROTOCOL" =~ ^(tcp|udp)$ ]] || {
        echo "Error: Protocol must be 'tcp' or 'udp'." >&2
        exit 1
    }
    is_valid_port "$TARGET_PORT" || {
        echo "Error: target-port must be a number in range 1-65535." >&2
        exit 1
    }
    is_valid_port "$KEY" || {
        echo "Error: source port must be in range 1-65535." >&2
        exit 1
    }
    SITE_TYPE="port"
    SOURCE_PORT="$KEY"
else
    is_valid_domain "$KEY" || {
        echo "Error: domain must be a valid fully qualified domain name." >&2
        exit 1
    }
    if [[ "$TARGET_TYPE" == "internal" ]]; then
        [[ $# -eq 2 ]] || {
            echo "Error: Internal Node domains do not accept a target-port or protocol." >&2
            exit 1
        }
        if [[ "$KEY" == \*.* ]]; then
            SITE_TYPE="internal-wildcard-domain"
        else
            SITE_TYPE="internal-domain"
        fi
        TARGET_PORT=""
        SOURCE_PORT=""
        PROTOCOL="dns"
    elif [[ "$TARGET_TYPE" == "edge" ]]; then
        [[ -n "$TARGET_PORT" ]] || {
            echo "Error: target-port is required for an Edge Service Peer." >&2
            exit 1
        }
        is_valid_port "$TARGET_PORT" || {
            echo "Error: target-port must be a number in range 1-65535." >&2
            exit 1
        }
        SITE_TYPE="domain"
        SOURCE_PORT=443
        PROTOCOL="tcp"   # SNI passthrough is always TCP
    else
        echo "Error: Domains can target only Internal Nodes or Edge Service Peers." >&2
        exit 1
    fi
fi

if [[ "$SITE_TYPE" == internal-* ]]; then
    echo "Adding private DNS record '$KEY' → $TARGET_PEER ($TARGET_IP)..."
else
    echo "Adding site '$KEY' ($SITE_TYPE) → $TARGET_PEER ($TARGET_IP):$TARGET_PORT ($PROTOCOL)..."
fi

# ─── Update sites.json ────────────────────────────────────────────────────────

if [[ "$SITE_TYPE" == internal-* ]]; then
    jq --arg key "$KEY" \
       --arg type "$SITE_TYPE" \
       --arg target_peer "$TARGET_PEER" \
       --arg protocol "$PROTOCOL" \
       '.sites[$key] = {
           type: $type,
           target_peer: $target_peer,
           protocol: $protocol
       }' \
       "$SITES_FILE" > "${SITES_FILE}.tmp"
else
    jq --arg key "$KEY" \
       --arg type "$SITE_TYPE" \
       --arg target_peer "$TARGET_PEER" \
       --argjson target_port "$TARGET_PORT" \
       --argjson source_port "$SOURCE_PORT" \
       --arg protocol "$PROTOCOL" \
       '.sites[$key] = {
           type:        $type,
           target_peer: $target_peer,
           target_port: $target_port,
           source_port: $source_port,
           protocol:    $protocol
       }' "$SITES_FILE" > "${SITES_FILE}.tmp"
fi
mv "${SITES_FILE}.tmp" "$SITES_FILE"

# ─── Regenerate Nginx and private DNS configs ─────────────────────────────────

rebuild_nginx_configs
rebuild_dns_hosts
rebuild_dns_wildcards
if [[ "$SITE_TYPE" == internal-* ]]; then
    reload_coredns
else
    reload_nginx
fi

# ─── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "✓ Site '$KEY' added successfully."
echo ""
if [[ "$SITE_TYPE" == internal-* ]]; then
    printf '  Private DNS:          %-20s → %s\n' "$KEY" "$TARGET_PEER ($TARGET_IP)"
elif [[ "$SITE_TYPE" == "domain" ]]; then
    printf '  TCP SNI passthrough: HTTPS for %-20s → %s:%s\n' \
        "$KEY" "$TARGET_PEER ($TARGET_IP)" "$TARGET_PORT"
else
    printf '  Port forwarding:     %-4s %-6s%-20s → %s:%s\n' \
        "$PROTOCOL" "port" "$SOURCE_PORT" "$TARGET_PEER ($TARGET_IP)" "$TARGET_PORT"
fi
echo ""
