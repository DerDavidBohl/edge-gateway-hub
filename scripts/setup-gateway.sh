#!/usr/bin/env bash
# edge-gateway-hub – Gateway initialisation wizard
# Creates .env, directory structure, WireGuard server keys, IPAM, and starts
# the Docker Compose stack.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DATA_DIR="$PROJECT_ROOT/data"

# ─── Helpers ──────────────────────────────────────────────────────────────────

info()  { printf '  \033[34m[INFO]\033[0m  %s\n' "$*"; }
ok()    { printf '  \033[32m[ OK ]\033[0m  %s\n' "$*"; }
err()   { printf '  \033[31m[ERR ]\033[0m  %s\n' "$*" >&2; exit 1; }

ask() {
    local prompt="$1" default="${2:-}" value
    if [[ -n "$default" ]]; then
        read -rp "  $prompt [$default]: " value
        printf '%s' "${value:-$default}"
    else
        read -rp "  $prompt: " value
        printf '%s' "$value"
    fi
}

is_valid_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 ))
}

is_valid_subnet_24() {
    local s="$1"
    [[ "$s" =~ ^([0-9]{1,3}\.){3}0/24$ ]] || return 1

    local o1 o2 o3 o4
    IFS=. read -r o1 o2 o3 o4 <<< "${s%/*}"
    for octet in "$o1" "$o2" "$o3" "$o4"; do
        [[ "$octet" =~ ^[0-9]+$ ]] || return 1
        (( octet >= 0 && octet <= 255 )) || return 1
    done
}

# Extract the first host address (.1) from a CIDR, e.g. 10.101.0.0/24 → 10.101.0.1
_net_hub_ip() {
    local network="${1%/*}"   # strip prefix
    local base="${network%.*}" # first three octets
    printf '%s.1' "$base"
}

# ─── Prerequisites ─────────────────────────────────────────────────────────────

check_prereqs() {
    info "Checking prerequisites..."
    for cmd in docker jq; do
        command -v "$cmd" &>/dev/null || err "'$cmd' is not installed."
    done
    docker compose version &>/dev/null 2>&1 || \
        docker-compose version &>/dev/null 2>&1 || \
        err "Docker Compose (v1 or v2) is not installed."
    ok "All prerequisites satisfied."
}

# ─── WireGuard key helpers (pre-container) ────────────────────────────────────

_wg_genkey_setup() {
    if command -v wg &>/dev/null; then
        wg genkey
    else
        info "Host 'wg' not found – using Docker image to generate keys..."
        docker run --rm --entrypoint wg lscr.io/linuxserver/wireguard:latest genkey
    fi
}

_wg_pubkey_setup() {
    local priv="$1"
    if command -v wg &>/dev/null; then
        printf '%s' "$priv" | wg pubkey
    else
        printf '%s' "$priv" | docker run --rm -i --entrypoint wg \
            lscr.io/linuxserver/wireguard:latest pubkey
    fi
}

# ─── Guard: existing installation ─────────────────────────────────────────────

if [[ -f "$PROJECT_ROOT/.env" ]]; then
    echo ""
    echo "  WARNING: $PROJECT_ROOT/.env already exists."
    read -rp "  Reinitialise from scratch? This will NOT delete existing keys. [y/N] " confirm
    [[ "${confirm,,}" == "y" ]] || { echo "  Aborted."; exit 0; }
fi

# ─── Interactive prompts ───────────────────────────────────────────────────────

echo ""
echo "  ╔══════════════════════════════════════╗"
echo "  ║  edge-gateway-hub  •  Setup Wizard   ║"
echo "  ╚══════════════════════════════════════╝"
echo ""

check_prereqs
echo ""

PUBLIC_IP="$(ask "Public gateway IP address")"
[[ -n "$PUBLIC_IP" ]] || err "Public IP cannot be empty."

WG_PORT="$(ask "WireGuard UDP listen port" "51820")"
CLIENT_SUBNET="$(ask  "Access Client subnet  (client zone)"    "10.101.0.0/24")"
INTERNAL_SUBNET="$(ask "Internal Node subnet  (internal zone)"  "10.102.0.0/24")"
EDGE_SUBNET="$(ask     "Edge Service subnet   (edge zone)"       "10.103.0.0/24")"

is_valid_port "$WG_PORT" || err "WireGuard port must be a number in range 1-65535."
is_valid_subnet_24 "$CLIENT_SUBNET" || err "Access Client subnet must be a valid IPv4 /24 CIDR (e.g. 10.101.0.0/24)."
is_valid_subnet_24 "$INTERNAL_SUBNET" || err "Internal Node subnet must be a valid IPv4 /24 CIDR (e.g. 10.102.0.0/24)."
is_valid_subnet_24 "$EDGE_SUBNET" || err "Edge Service subnet must be a valid IPv4 /24 CIDR (e.g. 10.103.0.0/24)."

echo ""

# ─── Directory structure ───────────────────────────────────────────────────────

info "Creating directory structure..."
mkdir -p \
    "$DATA_DIR/wireguard/wg_confs" \
    "$DATA_DIR/wireguard/peers" \
    "$DATA_DIR/keys" \
    "$DATA_DIR/nginx" \
    "$DATA_DIR/dns"
chmod 700 "$DATA_DIR/wireguard"
touch "$DATA_DIR/dns/hosts"
chmod 644 "$DATA_DIR/dns/hosts"
touch "$DATA_DIR/dns/exact.conf"
chmod 644 "$DATA_DIR/dns/exact.conf"
touch "$DATA_DIR/dns/wildcards.conf"
chmod 644 "$DATA_DIR/dns/wildcards.conf"
ok "Directory structure ready."

# ─── Server WireGuard key pair ─────────────────────────────────────────────────

SERVER_PRIV_FILE="$DATA_DIR/wireguard/server_private.key"
SERVER_PUB_FILE="$DATA_DIR/wireguard/server_public.key"

if [[ -f "$SERVER_PRIV_FILE" && -f "$SERVER_PUB_FILE" ]]; then
    info "Server keys already exist – reusing."
    SERVER_PRIVATE="$(cat "$SERVER_PRIV_FILE")"
    SERVER_PUBLIC="$(cat "$SERVER_PUB_FILE")"
else
    info "Generating server WireGuard key pair..."
    SERVER_PRIVATE="$(_wg_genkey_setup)"
    SERVER_PUBLIC="$(_wg_pubkey_setup "$SERVER_PRIVATE")"
    printf '%s\n' "$SERVER_PRIVATE" > "$SERVER_PRIV_FILE"
    printf '%s\n' "$SERVER_PUBLIC"  > "$SERVER_PUB_FILE"
    chmod 600 "$SERVER_PRIV_FILE"
    ok "Server keys generated."
fi

# ─── WireGuard interface config ────────────────────────────────────────────────

CLIENT_HUB_IP="$(_net_hub_ip "$CLIENT_SUBNET")"
INTERNAL_HUB_IP="$(_net_hub_ip "$INTERNAL_SUBNET")"
EDGE_HUB_IP="$(_net_hub_ip "$EDGE_SUBNET")"

cat > "$DATA_DIR/wireguard/wg_interface.conf" << EOF
[Interface]
Address = ${CLIENT_HUB_IP}/24,${INTERNAL_HUB_IP}/24,${EDGE_HUB_IP}/24
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIVATE}
PostUp = iptables -N EGHUB_WG_FORWARD; iptables -A EGHUB_WG_FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT; iptables -A EGHUB_WG_FORWARD -s ${CLIENT_SUBNET} -d ${INTERNAL_SUBNET} -j ACCEPT; iptables -A EGHUB_WG_FORWARD -j DROP; iptables -I FORWARD -i wg0 -j EGHUB_WG_FORWARD; iptables -I FORWARD -o wg0 -j EGHUB_WG_FORWARD
PostDown = iptables -D FORWARD -i wg0 -j EGHUB_WG_FORWARD; iptables -D FORWARD -o wg0 -j EGHUB_WG_FORWARD; iptables -F EGHUB_WG_FORWARD; iptables -X EGHUB_WG_FORWARD
EOF
chmod 600 "$DATA_DIR/wireguard/wg_interface.conf"

# Assemble initial wg0.conf (interface only; peers added later)
cp "$DATA_DIR/wireguard/wg_interface.conf" "$DATA_DIR/wireguard/wg_confs/wg0.conf"
chmod 600 "$DATA_DIR/wireguard/wg_confs/wg0.conf"
ok "WireGuard interface config created."

# ─── IPAM ─────────────────────────────────────────────────────────────────────

cat > "$DATA_DIR/ipam.json" << EOF
{
  "gateway": {
    "public_ip": "${PUBLIC_IP}",
    "wg_port": ${WG_PORT}
  },
  "subnets": {
    "client":   "${CLIENT_SUBNET}",
    "internal": "${INTERNAL_SUBNET}",
    "edge":     "${EDGE_SUBNET}"
  },
  "peers": {}
}
EOF
ok "IPAM initialised."

# ─── Sites registry ────────────────────────────────────────────────────────────

cat > "$DATA_DIR/sites.json" << EOF
{
  "sites": {}
}
EOF
ok "Sites registry initialised."

# ─── .env ─────────────────────────────────────────────────────────────────────

cat > "$PROJECT_ROOT/.env" << EOF
# edge-gateway-hub – generated by setup-gateway.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")

GATEWAY_PUBLIC_IP=${PUBLIC_IP}
WG_PORT=${WG_PORT}

CLIENT_SUBNET=${CLIENT_SUBNET}
INTERNAL_SUBNET=${INTERNAL_SUBNET}
EDGE_SUBNET=${EDGE_SUBNET}
EOF
ok ".env created."

# ─── Start the stack ──────────────────────────────────────────────────────────

echo ""
info "Starting Docker Compose stack..."
cd "$PROJECT_ROOT"
if docker compose version &>/dev/null 2>&1; then
    docker compose up -d
else
    docker-compose up -d
fi

echo ""
echo "  ╔═══════════════════════════════════════════════════════════════╗"
echo "  ║  edge-gateway-hub is running!                                 ║"
echo "  ║                                                               ║"
echo "  ║  Add a peer:                                                  ║"
echo "  ║    bash scripts/peer/add.sh <name> <client|internal|edge>    ║"
echo "  ║  Add a private domain or public route:                        ║"
echo "  ║    bash scripts/site/add.sh <domain|port> <peer> [port]     ║"
echo "  ╚═══════════════════════════════════════════════════════════════╝"
echo ""
printf '  Server public key: %s\n\n' "$SERVER_PUBLIC"
