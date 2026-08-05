# edge-gateway-hub

A fully containerised Layer-4 edge gateway that combines WireGuard (VPN hub) and Nginx (TCP/UDP stream proxy) to route public internet traffic to private backend services—without touching host firewall rules.

## 🤖 AI Assistance Disclaimer

This project was developed with the assistance of [GitHub Copilot](https://github.com/features/copilot). While AI was used to aid in code generation, syntax suggestions, and development efficiency, all code has been reviewed, tested, and validated by human maintainers.

## Architecture

```
Internet
   │
   ▼
┌──────────────────────────────────────────────────────────┐
│  Docker Host (public IP)                                 │
│                                                          │
│  ┌─────────────────┐     ┌──────────────────────────┐   │
│  │  nginx:alpine   │     │  linuxserver/wireguard   │   │
│  │  (stream proxy) │◄────│  (wg0 VPN hub)           │   │
│  │  Layer 4 TCP/UDP│     │  network namespace owner  │   │
│  └─────────────────┘     └──────────────────────────┘   │
│   network_mode: service:wireguard                        │
└──────────────────────────────────────────────────────────┘
        │              │
        │ WireGuard     │ WireGuard
        ▼              ▼
   Access Clients  Internal / Edge Service Peers
```

Nginx runs in the WireGuard container's network namespace so it can reach peer IPs on `wg0` directly. No `iptables` rules needed on the host.

## The Three Security Zones

| Zone | Default Subnet | Purpose |
|------|---------------|---------|
| **client** | `10.101.0.0/24` | Road warriors, admins |
| **internal** | `10.102.0.0/24` | Private home servers, NAS (reachable only by clients) |
| **edge** | `10.103.0.0/24` | Peers hosting public services routed by Nginx |

The gateway uses default-deny forwarding between these zones: Access Clients
may initiate connections to Internal Nodes, while established replies are
allowed. Client-to-client, client-to-edge, client-to-Internet, and edge
Internet-egress traffic are blocked. Nginx continues to reach Edge Service
Peers directly from the gateway network namespace.

## Prerequisites

| Tool | Purpose |
|------|---------|
| `docker` + Docker Compose v2 | Container runtime |
| `jq` | JSON state manipulation |
| `wg` (optional) | Faster key generation; falls back to `docker run` |

Install on Debian/Ubuntu:

```bash
apt-get install -y docker.io jq wireguard-tools
```

## Quick Start

### 1. Clone and initialise

```bash
git clone https://github.com/DerDavidBohl/edge-gateway-hub.git
cd edge-gateway-hub
bash scripts/setup-gateway.sh
```

The wizard prompts for your public IP, WireGuard port, and subnet ranges, then:
- Generates the server WireGuard key pair
- Creates `data/ipam.json` and `data/sites.json`
- Writes `data/wireguard/wg_confs/wg0.conf`
- Starts the Docker Compose stack

### 2. Add peers

```bash
# Access client (laptop / phone)
bash scripts/peer/add.sh alice client

# Internal node (home server, NAS)
bash scripts/peer/add.sh homeserver internal

# Edge service peer (exposes a public website)
bash scripts/peer/add.sh webserver edge
```

The generated `data/keys/<name>/<name>.conf` is a ready-to-use WireGuard client config. Send it to the peer operator.

Edge Service Peer profiles route only the gateway's Edge Service address. They
must not be used as an Internet VPN exit. Existing Edge Service Peer profiles
created before this policy change contain `AllowedIPs = 0.0.0.0/0`; replace
that value with the gateway Edge Service address plus `/32` (normally
`10.103.0.1/32`) before re-importing the profile.

### Migrate an existing gateway to zone isolation

After updating the repository, migrate an existing installation with:

```bash
bash scripts/migrate-zone-firewall.sh
```

The migration validates managed Edge Service Peer profiles before changing
anything, replaces their default Internet route with the gateway Edge Service
address, rebuilds the gateway configuration, and recreates the stack. Copy
each regenerated Edge Service Peer profile to its peer and re-import it there.

Access Client profiles use the gateway's Internal Node Network address as their
DNS server. An Internal Node named `homeserver` is therefore reachable at both
`10.102.0.2` and `homeserver.internal`. DNS records are derived automatically
from `data/ipam.json` and written to `data/dns/hosts`. You can also assign a
private domain to an Internal Node; it resolves directly to that node only for
WireGuard clients, even if the name has a public DNS record.

Public domains for Edge Service Peers remain normal public-DNS records: point
their A/AAAA records at the gateway's public IP, then configure SNI routing
with `scripts/site/add.sh`.

Private and public domain routes support leading wildcards. A private wildcard
such as `*.media.home.arpa` resolves matching WireGuard-client queries directly
to its Internal Node. A public wildcard such as `*.media.example.com` routes
matching TLS SNI traffic through the gateway. Wildcards do not match their
parent domain, which must be added separately when needed. Exact routes and
more-specific wildcard routes take precedence. Public wildcard routes also
require matching public DNS records pointing to the gateway.

### 3. Expose a service

```bash
# Private DNS for an Internal Node; connect directly to its service port
bash scripts/site/add.sh media.home.arpa homeserver

# Private DNS for all matching subdomains (not media.home.arpa itself)
bash scripts/site/add.sh '*.media.home.arpa' homeserver

# SNI passthrough for an exact domain (defaults to HTTPS port 443)
bash scripts/site/add.sh example.com services01

# SNI passthrough for all subdomains (not example.com itself)
bash scripts/site/add.sh '*.example.com' services01 443

# Another public domain can use the same Edge Service Peer
bash scripts/site/add.sh another-example.com services01

# Use a nonstandard backend port when needed
bash scripts/site/add.sh api.example.com services01 8443

# Port-based TCP forwarding
bash scripts/site/add.sh 8080 services01 8080 tcp

# UDP forwarding (e.g. DNS)
bash scripts/site/add.sh 53 services01 53 udp
```

## Script Reference

### Peer management (`scripts/peer/`)

| Script | Description |
|--------|-------------|
| `add.sh <name> <type>` | Generate keys, allocate IP, create client config, hot-reload WireGuard |
| `remove.sh <name>` | Remove peer from server config, release IP, delete key files |
| `list.sh` | Tabular overview of all registered peers |

### Site routing (`scripts/site/`)

| Script | Description |
|--------|-------------|
| `add.sh <domain\|port> <target-peer-name> [target-port] [protocol]` | Add a private DNS domain for an Internal Node, or SNI/port routing for an Edge Service Peer |
| `remove.sh <domain\|port>` | Remove a private DNS or public routing rule |
| `list.sh` | Tabular overview of all active private DNS and public routing rules |

## Data directory layout

```
data/
├── ipam.json               # IP allocations and peer registry
├── dns/
│   ├── hosts                # Generated exact Internal Node and private domain records
│   ├── exact.conf           # Generated CoreDNS rules for private exact domains
│   └── wildcards.conf       # Generated CoreDNS rules for private wildcard domains
├── sites.json              # Private DNS aliases and Nginx routing rules
├── wireguard/
│   ├── server_private.key  # ⚠ secret – never commit
│   ├── server_public.key
│   ├── wg_interface.conf   # [Interface] block template
│   ├── peers/              # Per-peer [Peer] fragments
│   └── wg_confs/
│       └── wg0.conf        # Assembled config (mounted into container)
├── keys/
│   └── <name>/
│       ├── private.key     # ⚠ secret – never commit
│       ├── public.key
│       └── <name>.conf     # Ready-to-distribute WireGuard client config
└── nginx/                  # Generated stream.d configs (mounted into container)
    ├── tcp_sni.conf        # SNI map + server block (recreated on each change)
    └── port_<proto>_<port>.conf
```

> **Security:** `data/wireguard/` and `data/keys/` are listed in `.gitignore`.  
> Never commit private keys to version control.

## Adding extra exposed ports

Additional TCP/UDP ports routed via Nginx must also be published by the
`wireguard` service (which owns the network namespace). Edit
`docker-compose.yml` and add the port to the `wireguard.ports` list, then
run `docker compose up -d` to apply.

```yaml
ports:
  - "2222:2222"   # SSH jump host, for example
```

## Running Traefik on an Internal or Edge Node

[`examples/node/docker-compose.yml`](examples/node/docker-compose.yml) is a
minimal node-side stack for either peer type. Create the peer first, then copy
its generated profile into the example directory before starting it:

```bash
mkdir -p node/wireguard/wg_confs
cp data/keys/webserver/webserver.conf node/wireguard/wg_confs/wg0.conf
cd node
docker compose up -d
```

Traefik shares WireGuard's network namespace and listens on ports `80` and
`443` of the node's WireGuard address; it does not publish ports on the node
host. Its Docker provider is enabled with `exposedByDefault=false`, so
application containers must opt in with Traefik labels and join the
`node-proxy` network. The bundled `whoami` service demonstrates this at
`whoami.example.com` over HTTP. Test it through the node's WireGuard address:

```bash
curl --header 'Host: whoami.example.com' http://<node-wireguard-ip>/
```

## License

MIT
