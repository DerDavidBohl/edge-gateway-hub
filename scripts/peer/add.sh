#!/usr/bin/env bash
# edge-gateway-hub – Add a WireGuard peer
# Usage: add.sh <name> <type>
#   type: client | internal | edge
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../_lib.sh"

# ─── Usage ────────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: $(basename "$0") <name> <type>

  name   Unique alphanumeric identifier for this peer (letters, digits, - _)
  type   One of:
           client    – Access Client (road warrior / admin)
           internal  – Internal Node (home server, NAS, private container)
           edge      – Edge Service Peer (exposes public services via Nginx)

Examples:
  $(basename "$0") alice      client
  $(basename "$0") homeserver internal
  $(basename "$0") webserver  edge
EOF
    exit 1
}

[[ $# -eq 2 ]] || usage

NAME="$1"
TYPE="$2"

# ─── Validate inputs ──────────────────────────────────────────────────────────

require_jq
require_ipam

[[ "$TYPE" =~ ^(client|internal|edge)$ ]] || {
    echo "Error: Invalid type '$TYPE'. Must be one of: client, internal, edge." >&2
    exit 1
}

[[ "$NAME" =~ ^[a-zA-Z0-9_-]+$ ]] || {
    echo "Error: Name must contain only letters, digits, dashes, and underscores." >&2
    exit 1
}

if jq -e --arg n "$NAME" '.peers | has($n)' "$IPAM_FILE" &>/dev/null; then
    echo "Error: Peer '$NAME' already exists. Use scripts/peer/remove.sh to delete it first." >&2
    exit 1
fi

# ─── Allocate IP ──────────────────────────────────────────────────────────────

echo "Allocating IP address for $TYPE peer '$NAME'..."
IP="$(get_next_ip "$TYPE")"
echo "  Assigned IP: $IP"

# ─── Generate key pair ────────────────────────────────────────────────────────

PEER_KEY_DIR="$KEYS_DIR/$NAME"
echo "Generating WireGuard key pair..."
PUBLIC_KEY="$(generate_keypair "$PEER_KEY_DIR")"
PRIVATE_KEY="$(cat "$PEER_KEY_DIR/private.key")"
echo "  Public key: $PUBLIC_KEY"

# ─── Read gateway parameters ──────────────────────────────────────────────────

GATEWAY_IP="$(jq -r '.gateway.public_ip'  "$IPAM_FILE")"
WG_PORT="$(jq    -r '.gateway.wg_port'    "$IPAM_FILE")"
SERVER_PUBLIC_KEY="$(cat "$WG_DIR/server_public.key")"

CLIENT_SUBNET="$(jq   -r '.subnets.client'   "$IPAM_FILE")"
INTERNAL_SUBNET="$(jq -r '.subnets.internal' "$IPAM_FILE")"
INTERNAL_DNS_IP="$(hub_ip "$INTERNAL_SUBNET")"

# ─── Determine type-specific AllowedIPs for client config ────────────────────
# These are the IPs the peer should route through the WireGuard tunnel.
#   client   → reach the internal node network
#   internal → reach the access client network
#   edge     → route all traffic through the hub (internet traffic arrives
#               via the Nginx proxy; responses must go back through the tunnel)

case "$TYPE" in
    client)
        ALLOWED_IPS="$INTERNAL_SUBNET"
        INTERFACE_EXTRAS="DNS = $INTERNAL_DNS_IP"
        ;;
    internal)
        ALLOWED_IPS="$CLIENT_SUBNET"
        INTERFACE_EXTRAS=""
        ;;
    edge)
        ALLOWED_IPS="0.0.0.0/0"
        INTERFACE_EXTRAS=""
        ;;
esac

# ─── Generate client WireGuard config ────────────────────────────────────────

CLIENT_CONF="$PEER_KEY_DIR/$NAME.conf"
{
    echo "[Interface]"
    echo "PrivateKey = $PRIVATE_KEY"
    echo "Address = $IP/32"
    [[ -n "$INTERFACE_EXTRAS" ]] && echo "$INTERFACE_EXTRAS"
    echo ""
    echo "[Peer]"
    echo "PublicKey = $SERVER_PUBLIC_KEY"
    echo "Endpoint = $GATEWAY_IP:$WG_PORT"
    echo "AllowedIPs = $ALLOWED_IPS"
    echo "PersistentKeepalive = 25"
} > "$CLIENT_CONF"
chmod 600 "$CLIENT_CONF"

# ─── Update IPAM ──────────────────────────────────────────────────────────────

echo "Updating IPAM..."
jq --arg name "$NAME" \
   --arg type "$TYPE" \
   --arg ip   "$IP" \
   --arg pub  "$PUBLIC_KEY" \
   '.peers[$name] = {type: $type, ip: $ip, public_key: $pub}' \
   "$IPAM_FILE" > "${IPAM_FILE}.tmp"
mv "${IPAM_FILE}.tmp" "$IPAM_FILE"
rebuild_dns_hosts
reload_coredns

# ─── Update WireGuard server config and hot-reload ───────────────────────────

echo "Adding peer to WireGuard server config..."
add_wg_peer "$NAME" "$PUBLIC_KEY" "$IP"
reload_wireguard

# ─── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "✓ Peer '$NAME' added successfully."
echo ""
printf '  %-14s %s\n' "Type:"        "$TYPE"
printf '  %-14s %s\n' "IP:"          "$IP"
printf '  %-14s %s\n' "Public key:"  "$PUBLIC_KEY"
printf '  %-14s %s\n' "Config file:" "$CLIENT_CONF"
echo ""
echo "  Share the config file with the peer operator to configure their device."
echo ""
