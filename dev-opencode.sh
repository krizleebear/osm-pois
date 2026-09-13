#!/usr/bin/env bash
# Dev launcher: starts an interactive bash in the dev container.
# opencode can be started inside with: opencode
set -euo pipefail

# Set terminal window/tab title to osm-pois
printf '\033]0;%s\007' "osm-pois"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.dev.yml"

if ! docker info >/dev/null 2>&1; then
  echo "[FAIL] Docker daemon is not running. Start Docker Desktop first (open -a Docker)." >&2
  exit 1
fi

cd "$SCRIPT_DIR"

echo "[INFO] Building dev image (cached) ..."
docker compose -f "$COMPOSE_FILE" build dev

# Export terminal environment variables for container passthrough
export TERM_PROGRAM="${TERM_PROGRAM:-}"
export TERM_PROGRAM_VERSION="${TERM_PROGRAM_VERSION:-}"
export LC_TERMINAL="${LC_TERMINAL:-}"
export LC_TERMINAL_VERSION="${LC_TERMINAL_VERSION:-}"
export ITERM_SESSION_ID="${ITERM_SESSION_ID:-}"
export COLORTERM="${COLORTERM:-truecolor}"

# Start macOS clipboard bridge daemon on host (allows pasting images into opencode/agy)
if [ "$(uname -s)" = "Darwin" ] && command -v python3 >/dev/null 2>&1; then
  python3 "$SCRIPT_DIR/scripts/mac_clipboard_server.py" --daemon 2>/dev/null || true
  export MAC_CLIPBOARD_TOKEN="${MAC_CLIPBOARD_TOKEN:-$(head -n 1 "$HOME/.mac_clipboard_token" 2>/dev/null || true)}"
fi

echo "[INFO] Starting interactive bash in dev container (opencode & agy available) ..."
exec -a "osm-pois" docker compose -f "$COMPOSE_FILE" run --rm --service-ports dev "$@"
