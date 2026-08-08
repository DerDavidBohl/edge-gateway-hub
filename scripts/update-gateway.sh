#!/usr/bin/env bash
# edge-gateway-hub – Pull current container images and reapply the stack.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
COMPOSE_FILE="$PROJECT_ROOT/docker-compose.yml"

info() { printf '  \033[34m[INFO]\033[0m  %s\n' "$*"; }
ok() { printf '  \033[32m[ OK ]\033[0m  %s\n' "$*"; }
err() { printf '  \033[31m[ERR ]\033[0m  %s\n' "$*" >&2; exit 1; }

command -v docker &>/dev/null || err "'docker' is not installed."
[[ -f "$COMPOSE_FILE" ]] || err "Compose file not found at $COMPOSE_FILE."
[[ -f "$PROJECT_ROOT/.env" ]] || err "Gateway is not initialized. Run: bash scripts/setup-gateway.sh"

if docker compose version &>/dev/null 2>&1; then
    compose=(docker compose)
elif docker-compose version &>/dev/null 2>&1; then
    compose=(docker-compose)
else
    err "Docker Compose (v1 or v2) is not installed."
fi

compose_args=(--project-directory "$PROJECT_ROOT" --file "$COMPOSE_FILE")

info "Pulling updated images..."
"${compose[@]}" "${compose_args[@]}" pull

info "Applying updated stack..."
"${compose[@]}" "${compose_args[@]}" up --detach --remove-orphans

info "Pruning unused dangling images..."
docker image prune --force

ok "Gateway stack is up to date."
