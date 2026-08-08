# Project Specification: edge-gateway-hub

## 1. Architecture & Core Features

* **100% Containerized Stack:** All services (Nginx, WireGuard, and CoreDNS) run isolated as Docker containers on a public-facing host (Edge Gateway).
* **Nginx Stream Module (TCP SNI Passthrough & UDP Support):** Nginx operates at Layer 4 (Transport layer) using the Stream module. Domain-based routing is handled via TCP SNI passthrough (`ssl_preread`), keeping certificate management and TLS termination completely on the destination sites. Additionally, native UDP routing is supported for port-based services.
* **Isolated Network Routing:** Routing is handled independently within container and WireGuard interfaces, requiring no host firewall modifications.
* **Default-Deny Zone Firewall:** The gateway permits only Access Client traffic
  to Internal Nodes and established return traffic. It blocks lateral traffic,
  client access to Edge Service Peers, and VPN Internet egress. Public Edge
  Service traffic reaches peers only through the gateway's Nginx proxy.
* **State & Key Management:** All cryptographic keys, IP allocations, and routing configurations are persistently stored locally in the `./data/` directory on the gateway host.
* **Internal DNS:** CoreDNS is an authoritative resolver for the `internal` zone. It serves automatically generated `internal`-node records from the gateway and forwards all other names to the resolver configured in its container.

---

## 2. Glossary (Terminology)

* **Edge Gateway (Public Node):** The centrally accessible host (whether a cloud VPS, a dedicated root server, or a home server with a public IP) acting as the entry point.
* **Edge Proxy (Nginx Stream):** The container on the gateway responsible for Layer 4 TCP and UDP routing.
* **WireGuard Hub:** The central WireGuard service on the gateway that establishes the overlay networks.
* **Access Clients:** Mobile or temporary endpoints (laptops, smartphones) connecting from the road to access private resources.
* **Internal Nodes:** Private peers/sites (home servers, NAS) that are not publicly exposed and are only accessible to Access Clients.
* **Edge Service Peers:** Peers hosting public services (TCP/UDP) exposed via the Edge Proxy.
* **IP Address Management (IPAM):** The structured assignment and tracking of internal IP addresses via a local state file (`ipam.json`).
* **Site:** A specific application on an Edge Service Peer reachable via a public domain or fixed port, or a private domain mapped directly to an Internal Node.
* **Internal DNS Record:** An automatically generated `<internal-peer-name>.internal` A record, or an explicitly configured private domain, mapped to an Internal Node's WireGuard address.

---

## 3. The 3 WireGuard Networks (Security Zones)

Traffic is strictly separated into three isolated subnets:

1. **Access Client Network (e.g., `10.101.0.0/24`):**
   * For road warriors and administrators.
   * Grants access to *Internal Nodes*.
   * Cannot access other clients, Edge Service Peers, or the Internet through
     the gateway.
2. **Internal Node Network (e.g., `10.102.0.0/24`):**
   * For private home servers and containers.
   * Only internally accessible to Access Clients.
   * May return established Access Client connections but cannot initiate
     connections to clients through the gateway.
3. **Edge Service Network (e.g., `10.103.0.0/24`):**
   * For publicly accessible services (Web/TCP or UDP).
   * The Nginx proxy routes external traffic directly to these peers.
   * Is isolated from Access Clients and has no Internet egress through the
     gateway.

---

## 4. Repository Structure

```text
edge-gateway-hub/
├── .env.example              # Configuration template (Public IP, subnets, ports)
├── docker-compose.yml        # Orchestration for Nginx, WireGuard, and CoreDNS
├── examples/
│   └── node/
│       └── docker-compose.yml # Internal/Edge Node WireGuard and Traefik example
├── coredns/
│   └── Corefile              # Private-DNS overrides and forwarding configuration
├── data/                     # Persistent state
│   ├── dns/
│   │   └── hosts             # Generated Internal Node and private-domain records
│   ├── ipam.json             # Structured IP and type management
│   ├── keys/                 # Automatically generated keys & client configuration files
│   └── nginx/                # Dynamically generated Nginx stream configurations
├── scripts/
│   ├── setup-gateway.sh      # Initializes gateway setup and starts the stack
│   ├── peer/                 # Scripts for WireGuard participants
│   │   ├── add.sh            # Generates keys, updates IPAM, server config AND client/peer config file
│   │   ├── remove.sh         # Removes peer and releases IP
│   │   └── list.sh           # Lists active peers/clients
│   │   └── status.sh         # Shows live WireGuard handshake and traffic status
│   └── site/                 # Scripts for private DNS and public forwarding
│       ├── add.sh            # Maps a private domain or public route to a peer
│       ├── remove.sh         # Deletes a site rule
│       └── list.sh           # Lists active site rules
└── README.md
```

> **Implementation status:** All scripts and configuration files described in this specification have been implemented. Run `bash scripts/setup-gateway.sh` to get started.

---

## 5. Script & Workflow Specification

### A. Initialization (`setup-gateway.sh`)
* Interactively prompts for basic parameters (Public Gateway IP, subnets for the three zones, UDP ports).
* Validates that `WG_PORT` is within `1-65535` and that all three zone subnets are IPv4 `/24` CIDRs before generating configuration.
* Creates the `.env` file and the directory structure for persistent state (`data/`).
* Installs a default-deny WireGuard forwarding policy that permits only Access
  Client-to-Internal Node connections and established return traffic.
* Starts the container stack via Docker Compose.
* Creates the DNS record directory and generates its initial empty hosts file.

### B. Peer & Client Management (`scripts/peer/`)
* **`add.sh <name> <type>`** (where `<type>` accepts `client`, `internal`, or `edge`):
  * Checks `ipam.json` and determines the next available IP in the corresponding subnet.
  * Generates a local WireGuard key pair and saves it under `data/keys/<name>/`.
  * **Automatically generates a complete WireGuard configuration file (`data/keys/<name>/<name>.conf`)** containing all necessary parameters (client/peer private key, assigned IP, public gateway endpoint, server public key, type-specific `AllowedIPs`, and keepalive settings). Edge Service Peer profiles route only the gateway's Edge Service address through the tunnel; they do not use the gateway for Internet egress.
  * Adds the peer to the server configuration and performs a hot reload of the WireGuard container.
  * Regenerates the CoreDNS hosts file and reloads CoreDNS; each Internal Node receives `<name>.internal` mapped to its allocated Internal Node Network address.
* **`remove.sh <name>`:**
  * Removes the peer from the server configuration, releases the IP in IPAM, cleans up keys and generated configuration files, and regenerates DNS records.
  * Refuses to remove a peer while a private DNS or public routing rule references its name.
* **`list.sh`:**
  * Outputs a tabular overview of all registered peers, their zones, and IP addresses.
* **`status.sh`:**
  * Queries the running WireGuard container and joins its live peer data to IPAM.
  * Outputs each registered peer's type, address, connection state, last-handshake
    age, transfer totals, and most recently observed endpoint. A peer is marked
    `connected` when its handshake is at most three minutes old, `stale` when
    older, and `never` when it has not completed a handshake.

### C. Site & Domain Routing (`scripts/site/`)
* **`add.sh <domain-or-port> <target-peer-name> [target-port] [protocol]`:**
  * Resolves the named peer from IPAM. Port routes and public domain routes require an Edge Service Peer. A domain targeting an Internal Node creates a private DNS record and does not require a target port.
  * Multiple distinct public domains may target the same Edge Service Peer. Public domain routes default to backend port `443` when `target-port` is omitted; specify `target-port` to use a different backend port. Port-based routes always require a target port.
  * Stores the peer name in the site definition and resolves its current WireGuard address when generating Nginx configuration.
  * Creates a new TCP SNI routing block (or UDP stream block) in the Nginx stream configuration. Domain routes support exact hostnames and leading-wildcard hostnames (for example, `*.media.example.com`); exact and more-specific wildcard routes take precedence.
  * Wildcard routes require matching public wildcard DNS records (for example, `*.media.example.com`) that point to the gateway. They do not match the parent domain, which must be added separately when needed.
  * Private domain routes are served by CoreDNS only to WireGuard clients and resolve directly to the Internal Node address. They may deliberately override a public DNS name for those clients; the service port is selected by the client or a reverse proxy on the Internal Node. Private domains support leading-wildcard hostnames (for example, `*.home.example`), which match subdomains but not the parent domain. Exact private records take precedence over wildcard records, and more-specific wildcard records take precedence over less-specific ones.
  * Validates `target-port` (and source port for port-based routes) as valid TCP/UDP ports in the range `1-65535`.
  * Performs a zero-downtime reload (`nginx -s reload`) for public routes, or restarts CoreDNS for private DNS changes.
* **`remove.sh <domain-or-port>`:**
  * Removes the corresponding routing block and updates the proxy.
* **`list.sh`:**
  * Displays all active forwards.

### D. DNS Resolution

* **Private DNS:** The `coredns` container shares the WireGuard network namespace and is not published on a host DNS port. Generated exact records are stored in `data/dns/hosts` and `data/dns/exact.conf`, and generated wildcard rules are stored in `data/dns/wildcards.conf`; `ipam.json` and private site definitions are their source of truth. An Internal Node named `home-server` resolves as `home-server.internal` to its `10.102.x.x`, and configured exact or wildcard private domains resolve directly to their assigned address.
* **WireGuard clients:** Generated Access Client profiles configure `DNS = <Internal Node Network hub address>`, normally `10.102.0.1`. Their existing route to the Internal Node Network therefore carries DNS queries to the gateway. Internal and Edge Service Peer profiles do not use the gateway DNS unless their operators configure it explicitly.
* **Public names:** Queries outside `internal`, including public domains used by Edge Service Peers, are forwarded by CoreDNS to its configured upstream resolver. Public internet clients resolve Edge Service Peer domains through normal public DNS, which must publish A/AAAA records pointing to the gateway's public IP; Nginx then selects the private backend by SNI.

### E. Internal and Edge Node Compose Example

* `examples/node/docker-compose.yml` provides a minimal deployment for either
  an Internal Node or an Edge Service Peer. The operator copies the generated
  peer profile to `./wireguard/wg_confs/wg0.conf`.
* The Traefik container shares the WireGuard container's network namespace,
  allowing the gateway to reach Traefik on the node's WireGuard address without
  exposing ports on the node host. Traefik provides HTTP (`80`) and HTTPS
  (`443`) entrypoints and Docker service discovery for basic container routing.
* The example includes an opt-in `traefik/whoami` service on the `node-proxy`
  network. It demonstrates a Docker-label router for HTTP requests with the
  `Host` value `whoami.example.com`.
