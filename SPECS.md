# Project Specification: edge-gateway-hub

## 1. Architecture & Core Features

* **100% Containerized Stack:** All services (Nginx, WireGuard, and CoreDNS) run isolated as Docker containers on a public-facing host (Edge Gateway).
* **Nginx Stream Module (TCP SNI Passthrough & UDP Support):** Nginx operates at Layer 4 (Transport layer) using the Stream module. Domain-based routing is handled via TCP SNI passthrough (`ssl_preread`), keeping certificate management and TLS termination completely on the destination sites. Additionally, native UDP routing is supported for port-based services.
* **Isolated Network Routing:** Routing is handled independently within container and WireGuard interfaces, requiring no host firewall modifications.
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
* **Site:** A specific application on an Edge Service Peer reachable via a public domain or fixed port.
* **Internal DNS Record:** An automatically generated `<internal-peer-name>.internal` A record mapped to an Internal Node's WireGuard address.

---

## 3. The 3 WireGuard Networks (Security Zones)

Traffic is strictly separated into three isolated subnets:

1. **Access Client Network (e.g., `10.101.0.0/24`):**
   * For road warriors and administrators.
   * Grants access to *Internal Nodes*.
2. **Internal Node Network (e.g., `10.102.0.0/24`):**
   * For private home servers and containers.
   * Only internally accessible to Access Clients.
3. **Edge Service Network (e.g., `10.103.0.0/24`):**
   * For publicly accessible services (Web/TCP or UDP).
   * The Nginx proxy routes external traffic directly to these peers.

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
│   └── Corefile              # Authoritative internal-zone and forwarding configuration
├── data/                     # Persistent state
│   ├── dns/
│   │   └── hosts             # Generated Internal Node hostname-to-IP records
│   ├── ipam.json             # Structured IP and type management
│   ├── keys/                 # Automatically generated keys & client configuration files
│   └── nginx/                # Dynamically generated Nginx stream configurations
├── scripts/
│   ├── setup-gateway.sh      # Initializes gateway setup and starts the stack
│   ├── peer/                 # Scripts for WireGuard participants
│   │   ├── add.sh            # Generates keys, updates IPAM, server config AND client/peer config file
│   │   ├── remove.sh         # Removes peer and releases IP
│   │   └── list.sh           # Lists active peers/clients
│   └── site/                 # Scripts for domain/port forwarding
│       ├── add.sh            # Maps a domain/port combination to an Edge Service Peer IP
│       ├── remove.sh         # Deletes forwarding
│       └── list.sh           # Lists active routings
└── README.md
```

> **Implementation status:** All scripts and configuration files described in this specification have been implemented. Run `bash scripts/setup-gateway.sh` to get started.

---

## 5. Script & Workflow Specification

### A. Initialization (`setup-gateway.sh`)
* Interactively prompts for basic parameters (Public Gateway IP, subnets for the three zones, UDP ports).
* Validates that `WG_PORT` is within `1-65535` and that all three zone subnets are IPv4 `/24` CIDRs before generating configuration.
* Creates the `.env` file and the directory structure for persistent state (`data/`).
* Starts the container stack via Docker Compose.
* Creates the DNS record directory and generates its initial empty hosts file.

### B. Peer & Client Management (`scripts/peer/`)
* **`add.sh <name> <type>`** (where `<type>` accepts `client`, `internal`, or `edge`):
  * Checks `ipam.json` and determines the next available IP in the corresponding subnet.
  * Generates a local WireGuard key pair and saves it under `data/keys/<name>/`.
  * **Automatically generates a complete WireGuard configuration file (`data/keys/<name>/<name>.conf`)** containing all necessary parameters (client/peer private key, assigned IP, public gateway endpoint, server public key, type-specific `AllowedIPs`, and keepalive settings).
  * Adds the peer to the server configuration and performs a hot reload of the WireGuard container.
  * Regenerates the CoreDNS hosts file; each Internal Node receives `<name>.internal` mapped to its allocated Internal Node Network address.
* **`remove.sh <name>`:**
  * Removes the peer from the server configuration, releases the IP in IPAM, cleans up keys and generated configuration files, and regenerates DNS records.
* **`list.sh`:**
  * Outputs a tabular overview of all registered peers, their zones, and IP addresses.

### C. Site & Domain Routing (`scripts/site/`)
* **`add.sh <domain-or-port> <target-ip> <target-port> [protocol]`:**
  * Creates a new TCP SNI routing block (or UDP stream block) in the Nginx stream configuration.
  * Validates `target-port` (and source port for port-based routes) as valid TCP/UDP ports in the range `1-65535`.
  * Performs a zero-downtime reload (`nginx -s reload`) of the proxy container.
* **`remove.sh <domain-or-port>`:**
  * Removes the corresponding routing block and updates the proxy.
* **`list.sh`:**
  * Displays all active forwards.

### D. DNS Resolution

* **Authoritative internal zone:** The `coredns` container shares the WireGuard network namespace and is not published on a host DNS port. It is authoritative for `internal`; generated records are stored in `data/dns/hosts`, with `ipam.json` as their source of truth. An Internal Node named `home-server` resolves as `home-server.internal` to its `10.102.x.x` address.
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
