# Shared settings and helpers for run.sh and stop.sh (sourced, not executed)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="$ROOT/.run"

# Load .env without overriding variables already set in the environment
if [[ -f "$ROOT/.env" ]]; then
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        [[ -n "${!key+x}" ]] || export "$key=$value"
    done <"$ROOT/.env"
fi

# docker: native Apple OCR helper on APPLE_PORT + Docker container with the API on API_PORT
# native: a single native server with Lens and Apple OCR on API_PORT, no Docker
RUN_MODE="${RUN_MODE:-docker}"
API_PORT="${API_PORT:-3000}"
APPLE_PORT="${APPLE_PORT:-3001}"
SERVER_HOST="${SERVER_HOST:-127.0.0.1}"
TUNNEL_NAME="${TUNNEL_NAME:-ocr-01}"
TUNNEL_CONFIG="${TUNNEL_CONFIG:-$HOME/.cloudflared/$TUNNEL_NAME.yml}"
PUBLIC_URL="${PUBLIC_URL:-https://$TUNNEL_NAME.webmcp.vn}"

# Port of the native node server
if [[ "$RUN_MODE" == native ]]; then
    SERVER_PORT="$API_PORT"
else
    SERVER_PORT="$APPLE_PORT"
fi

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m  ✗\033[0m %s\n' "$*" >&2; exit 1; }

tunnel_pids() { pgrep -f "cloudflared tunnel --config $TUNNEL_CONFIG run"; }
