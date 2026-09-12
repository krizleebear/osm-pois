#!/usr/bin/env bash
# Dev launcher: starts an interactive bash in the dev container.
# opencode can be started inside with: opencode
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.dev.yml"

if ! docker info >/dev/null 2>&1; then
  echo "[FAIL] Docker daemon is not running. Start Docker Desktop first (open -a Docker)." >&2
  exit 1
fi

cd "$SCRIPT_DIR"

echo "[INFO] Building dev image (cached) ..."
docker compose -f "$COMPOSE_FILE" build dev

echo "[INFO] Starting interactive bash in dev container (opencode & agy available) ..."
exec docker compose -f "$COMPOSE_FILE" run --rm dev "$@"
