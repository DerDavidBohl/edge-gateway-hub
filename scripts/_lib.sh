#!/usr/bin/env bash
# edge-gateway-hub – Shared library
# Source this file from other scripts; do not execute directly.

# ─── Paths ────────────────────────────────────────────────────────────────────

# When sourced, BASH_SOURCE[0] refers to this file, so LIB_DIR is always
# the scripts/ directory regardless of which script sourced us.
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$_LIB_DIR")"

DATA_DIR="$PROJECT_ROOT/data"
IPAM_FILE="$DATA_DIR/ipam.json"
SITES_FILE="$DATA_DIR/sites.json"
KEYS_DIR="$DATA_DIR/keys"
WG_DIR="$DATA_DIR/wireguard"
WG_INTERFACE_CONF="$WG_DIR/wg_interface.conf"
WG_PEERS_DIR="$WG_DIR/peers"
WG_CONFS_DIR="$WG_DIR/wg_confs"
WG_CONF="$WG_CONFS_DIR/wg0.conf"
NGINX_STREAM_DIR="$DATA_DIR/nginx"

# ─── Prerequisite checks ──────────────────────────────────────────────────────

require_jq() {
    command -v jq &>/dev/null || {
        echo "Error: 'jq' is required but not installed." >&2
        echo "  Ubuntu/Debian:  apt-get install -y jq" >&2
        echo "  macOS:          brew install jq" >&2
        exit 1
    }
}

require_docker() {
    command -v docker &>/dev/null || {
        echo "Error: 'docker' is required but not installed." >&2
        exit 1
    }
}

require_ipam() {
    [[ -f "$IPAM_FILE" ]] || {
        echo "Error: IPAM file not found at $IPAM_FILE" >&2
        echo "Run: bash scripts/setup-gateway.sh" >&2
        exit 1
    }
}

require_sites() {
    [[ -f "$SITES_FILE" ]] || {
        echo "Error: Sites file not found at $SITES_FILE" >&2
        echo "Run: bash scripts/setup-gateway.sh" >&2
        exit 1
    }
}

# ─── WireGuard key generation ─────────────────────────────────────────────────

# Generate a WireGuard private key using the best available method:
#   1. Host 'wg' binary
#   2. Running wireguard container
#   3. Temporary docker run (pulls image if needed)
_wg_genkey() {
    if command -v wg &>/dev/null; then
        wg genkey
    elif docker inspect --format '{{.State.Running}}' wireguard 2>/dev/null | grep -q true; then
        docker exec wireguard wg genkey
    else
        docker run --rm --entrypoint wg lscr.io/linuxserver/wireguard:latest genkey 2>/dev/null
    fi
}

# Derive the WireGuard public key from a private key.
_wg_pubkey() {
    local private_key="$1"
    if command -v wg &>/dev/null; then
        printf '%s' "$private_key" | wg pubkey
    elif docker inspect --format '{{.State.Running}}' wireguard 2>/dev/null | grep -q true; then
        printf '%s' "$private_key" | docker exec -i wireguard wg pubkey
    else
        printf '%s' "$private_key" | docker run --rm -i --entrypoint wg \
            lscr.io/linuxserver/wireguard:latest pubkey 2>/dev/null
    fi
}

# Generate a key pair; store private/public.key under <dir>.
# Prints the public key to stdout.
generate_keypair() {
    local dir="$1"
    mkdir -p "$dir"
    chmod 700 "$dir"

    local private_key public_key
    private_key="$(_wg_genkey)"
    public_key="$(_wg_pubkey "$private_key")"

    printf '%s\n' "$private_key" > "$dir/private.key"
    printf '%s\n' "$public_key"  > "$dir/public.key"
    chmod 600 "$dir/private.key"
    chmod 644 "$dir/public.key"

    printf '%s\n' "$public_key"
}

# ─── IPAM helpers ─────────────────────────────────────────────────────────────

# Return the next unassigned host IP in the subnet for <type>.
# Starts from .2 (.1 is reserved for the gateway hub).
get_next_ip() {
    local type="$1"
    require_ipam

    local subnet
    subnet="$(jq -r ".subnets.$type // empty" "$IPAM_FILE")"
    [[ -n "$subnet" ]] || {
        echo "Error: Unknown peer type '$type'. Valid types: client, internal, edge." >&2
        exit 1
    }

    # Extract base, e.g. "10.101.0.0/24" → "10.101.0"
    local network="${subnet%/*}"
    local base="${network%.*}"

    local used_ips
    used_ips="$(jq -r --arg t "$type" \
        '[.peers | to_entries[] | select(.value.type == $t) | .value.ip] | .[]' \
        "$IPAM_FILE")"

    for i in $(seq 2 254); do
        local candidate="${base}.${i}"
        if ! printf '%s\n' "$used_ips" | grep -qxF "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    echo "Error: Subnet $subnet is full (no IPs available from .2 to .254)." >&2
    return 1
}

# ─── WireGuard config management ──────────────────────────────────────────────

# Rebuild wg0.conf from the interface config + all per-peer files.
rebuild_wg_conf() {
    mkdir -p "$WG_CONFS_DIR"
    {
        cat "$WG_INTERFACE_CONF"
        for f in "$WG_PEERS_DIR"/*.conf; do
            [[ -f "$f" ]] || continue
            echo
            cat "$f"
        done
    } > "$WG_CONF"
    chmod 600 "$WG_CONF"
}

# Write a [Peer] block for <name> and rebuild wg0.conf.
add_wg_peer() {
    local name="$1" public_key="$2" ip="$3"
    mkdir -p "$WG_PEERS_DIR"
    printf '# Peer: %s\n[Peer]\nPublicKey = %s\nAllowedIPs = %s/32\n' \
        "$name" "$public_key" "$ip" > "$WG_PEERS_DIR/$name.conf"
    rebuild_wg_conf
}

# Remove the per-peer file for <name> and rebuild wg0.conf.
remove_wg_peer() {
    local name="$1"
    rm -f "$WG_PEERS_DIR/$name.conf"
    rebuild_wg_conf
}

# ─── Nginx config management ──────────────────────────────────────────────────

# Regenerate all stream.d configs from sites.json.
rebuild_nginx_configs() {
    require_sites
    mkdir -p "$NGINX_STREAM_DIR"

    # Remove previously generated files
    rm -f "$NGINX_STREAM_DIR"/tcp_sni.conf
    rm -f "$NGINX_STREAM_DIR"/port_*.conf

    # ── TCP SNI passthrough (domain-based sites) ──────────────────────────────
    local domain_count
    domain_count="$(jq '[.sites | to_entries[] | select(.value.type == "domain")] | length' \
        "$SITES_FILE")"

    if [[ "$domain_count" -gt 0 ]]; then
        {
            printf 'map $ssl_preread_server_name $tcp_sni_backend {\n'
            jq -r '.sites | to_entries[]
                   | select(.value.type == "domain")
                   | "    \(.key) \(.value.target_ip):\(.value.target_port);"' \
                "$SITES_FILE"
            printf '    default "";\n'
            printf '}\n\n'
            printf 'server {\n'
            printf '    listen 443;\n'
            printf '    ssl_preread on;\n'
            printf '    proxy_pass $tcp_sni_backend;\n'
            printf '}\n'
        } > "$NGINX_STREAM_DIR/tcp_sni.conf"
    fi

    # ── Port-based server blocks (TCP or UDP) ─────────────────────────────────
    while IFS=$'\t' read -r _key source_port target_ip target_port protocol; do
        {
            printf 'server {\n'
            if [[ "$protocol" == "udp" ]]; then
                printf '    listen %s udp;\n' "$source_port"
            else
                printf '    listen %s;\n' "$source_port"
            fi
            printf '    proxy_pass %s:%s;\n' "$target_ip" "$target_port"
            printf '}\n'
        } > "$NGINX_STREAM_DIR/port_${protocol}_${source_port}.conf"
    done < <(jq -r '.sites | to_entries[]
                    | select(.value.type == "port")
                    | [.key,
                       (.value.source_port | tostring),
                       .value.target_ip,
                       (.value.target_port | tostring),
                       .value.protocol]
                    | @tsv' "$SITES_FILE")
}

# ─── Container reload helpers ─────────────────────────────────────────────────

# Hot-reload the WireGuard peer list without dropping existing tunnels.
reload_wireguard() {
    if docker inspect --format '{{.State.Running}}' wireguard 2>/dev/null | grep -q true; then
        echo "Reloading WireGuard..."
        if ! docker exec wireguard sh -c \
                'wg-quick strip /config/wg_confs/wg0.conf | wg syncconf wg0 /dev/stdin' 2>/dev/null; then
            echo "syncconf unavailable – restarting WireGuard container..."
            docker restart wireguard
        fi
    else
        echo "WireGuard container not running – config saved."
        echo "Start with: docker compose up -d"
    fi
}

# Zero-downtime Nginx reload (nginx -s reload inside the container).
reload_nginx() {
    if docker inspect --format '{{.State.Running}}' nginx 2>/dev/null | grep -q true; then
        echo "Reloading Nginx..."
        docker exec nginx nginx -s reload
    else
        echo "Nginx container not running – config saved."
        echo "Start with: docker compose up -d"
    fi
}
