#!/usr/bin/env bash
# Dev launcher: starts an interactive bash in the dev container.
# agy (Antigravity CLI) can be started inside with: agy
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.dev.yml"

if ! docker info >/dev/null 2>&1; then
  echo "[FAIL] Docker daemon is not running. Start Docker Desktop first (open -a Docker)." >&2
  exit 1
fi

cd "$SCRIPT_DIR"

UPDATE_AGY=false
REMAINING_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --update|--update-agy)
      UPDATE_AGY=true
      ;;
    *)
      REMAINING_ARGS+=("$arg")
      ;;
  esac
done

export CACHEBUST_AGY="${CACHEBUST_AGY:-}"
if [ "$UPDATE_AGY" = true ]; then
  CACHEBUST_AGY="$(date +%s)"
  export CACHEBUST_AGY
  echo "[INFO] Updating agy installation (bypassing cache for agy layer) ..."
elif [ -n "$CACHEBUST_AGY" ]; then
  echo "[INFO] Using custom CACHEBUST_AGY=$CACHEBUST_AGY ..."
else
  echo "[INFO] Building dev image (cached) ..."
fi

# Export terminal environment variables for container passthrough
export TERM_PROGRAM="${TERM_PROGRAM:-}"
export TERM_PROGRAM_VERSION="${TERM_PROGRAM_VERSION:-}"
export LC_TERMINAL="${LC_TERMINAL:-}"
export LC_TERMINAL_VERSION="${LC_TERMINAL_VERSION:-}"
export ITERM_SESSION_ID="${ITERM_SESSION_ID:-}"
export COLORTERM="${COLORTERM:-truecolor}"

# Start macOS clipboard bridge daemon on host (allows pasting images into agy/opencode)
if [ "$(uname -s)" = "Darwin" ] && command -v python3 >/dev/null 2>&1; then
  python3 "$SCRIPT_DIR/scripts/mac_clipboard_server.py" --daemon 2>/dev/null || true
  export MAC_CLIPBOARD_TOKEN="${MAC_CLIPBOARD_TOKEN:-$(head -n 1 "$HOME/.mac_clipboard_token" 2>/dev/null || true)}"
fi

echo "[INFO] Starting interactive bash in dev container (agy & opencode available) ..."
if [ ${#REMAINING_ARGS[@]} -gt 0 ]; then
  exec docker compose -f "$COMPOSE_FILE" run --rm --service-ports dev "${REMAINING_ARGS[@]}"
else
  exec docker compose -f "$COMPOSE_FILE" run --rm --service-ports dev
fi
