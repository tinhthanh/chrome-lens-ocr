#!/usr/bin/env bash
# Start the OCR stack on a Mac, detached from the terminal so it keeps running
# after VS Code or the terminal is closed. RUN_MODE (in .env or the environment):
#   docker (default): native Apple Vision OCR server (port 3001) + Docker
#                     container with the API (port 3000) + Cloudflare tunnel
#   native:           one native server with Lens and Apple OCR (port 3000)
#                     + Cloudflare tunnel, no Docker needed
# The tunnel is skipped when its config file does not exist.
# Safe to run again: components that are already running are left alone.
# Stop everything with ./stop.sh. Logs and pid files live in .run/
set -euo pipefail

source "$(dirname "$0")/scripts/common.sh"
cd "$ROOT"

# Run a command in a new session, ignoring SIGHUP, so closing the terminal does not kill it
detach() {
    local name="$1"; shift
    nohup perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or die "exec $ARGV[0]: $!\n"' "$@" \
        >"$RUN_DIR/$name.log" 2>&1 </dev/null &
    echo $! >"$RUN_DIR/$name.pid"
}

# wait_for <seconds> <command...>: retry the command every second until it succeeds
wait_for() {
    local timeout="$1"; shift
    for ((i = 0; i < timeout; i++)); do
        if "$@" >/dev/null 2>&1; then return 0; fi
        sleep 1
    done
    return 1
}

healthy() { curl -fsS -m 2 "http://127.0.0.1:$1/health"; }
tunnel_registered() { grep -q "Registered tunnel connection" "$RUN_DIR/tunnel.log"; }

# apple_state <port>: "local", "remote" or "unavailable (reason)" from /health
apple_state() {
    healthy "$1" | node -e '
        let s = "";
        process.stdin.on("data", d => (s += d)).on("end", () => {
            const a = JSON.parse(s).engines.apple;
            console.log(a.available ? a.mode : `unavailable (${a.reason})`);
        });'
}

# --- Prerequisites ----------------------------------------------------------
[[ "$(uname)" == Darwin ]] || die "run.sh needs macOS (Apple Vision). On Linux use: docker compose up -d"
[[ "$RUN_MODE" == docker || "$RUN_MODE" == native ]] || die "RUN_MODE must be docker or native, got: $RUN_MODE"
required=(node curl perl)
[[ "$RUN_MODE" == docker ]] && required+=(docker)
for cmd in "${required[@]}"; do
    command -v "$cmd" >/dev/null || die "$cmd not found"
done
mkdir -p "$RUN_DIR"

if [[ ! -d node_modules ]]; then
    log "Installing Node dependencies"
    npm ci --omit=dev
fi
# Rebuild when the Swift source is newer (packaged installs ship only the binary)
if [[ ! -x bin/apple-ocr || apple-ocr/AppleOCR.swift -nt bin/apple-ocr ]]; then
    command -v swiftc >/dev/null || die "bin/apple-ocr is missing and swiftc is not installed (xcode-select --install)"
    log "Building Apple OCR binary"
    npm run build:apple >"$RUN_DIR/build.log" 2>&1 || { tail -20 "$RUN_DIR/build.log"; die "build failed"; }
fi
if [[ "$RUN_MODE" == docker ]] && ! grep -q '^APPLE_OCR_URL=' .env 2>/dev/null; then
    echo "APPLE_OCR_URL=http://host.docker.internal:$APPLE_PORT" >>.env
fi

# --- 1. Native server ---------------------------------------------------------
if [[ "$RUN_MODE" == native ]]; then
    log "OCR API server, Lens + Apple Vision (port $SERVER_PORT)"
else
    log "Apple Vision OCR server (port $SERVER_PORT)"
fi
if healthy "$SERVER_PORT" >/dev/null 2>&1; then
    ok "already running"
else
    # APPLE_OCR_URL is for the container only; the native server must use Apple OCR locally
    detach server env -u APPLE_OCR_URL PORT="$SERVER_PORT" HOST="$SERVER_HOST" NODE_ENV=production \
        node "$ROOT/server.js"
    wait_for 30 healthy "$SERVER_PORT" || die "did not start, see .run/server.log"
    ok "started (pid $(cat "$RUN_DIR/server.pid")), Apple OCR: $(apple_state "$SERVER_PORT")"
fi

# --- 2. Docker container (docker mode) ---------------------------------------
if [[ "$RUN_MODE" == docker ]]; then
    log "Docker container (port $API_PORT)"
    if ! docker info >/dev/null 2>&1; then
        log "Starting Docker Desktop"
        open -a Docker
        wait_for 120 docker info || die "Docker Desktop did not start"
    fi
    docker compose up -d --build >"$RUN_DIR/docker.log" 2>&1 || { tail -20 "$RUN_DIR/docker.log"; die "docker compose failed"; }
    wait_for 60 healthy "$API_PORT" || die "API not responding, see: docker compose logs"
    ok "running, Apple OCR: $(apple_state "$API_PORT")"
fi

# --- 3. Cloudflare tunnel -----------------------------------------------------
log "Cloudflare tunnel ($TUNNEL_NAME)"
if [[ ! -f "$TUNNEL_CONFIG" ]]; then
    warn "skipped: $TUNNEL_CONFIG not found"
elif ! command -v cloudflared >/dev/null; then
    warn "skipped: cloudflared not installed"
elif tunnel_pids >/dev/null; then
    ok "already running"
else
    detach tunnel cloudflared tunnel --config "$TUNNEL_CONFIG" run "$TUNNEL_NAME"
    wait_for 30 tunnel_registered || die "tunnel did not connect, see .run/tunnel.log"
    ok "connected (pid $(cat "$RUN_DIR/tunnel.pid"))"
fi

echo
ok "Local:  http://localhost:$API_PORT"
if [[ -f "$TUNNEL_CONFIG" ]]; then
    ok "Public: $PUBLIC_URL"
fi
echo "     Logs: .run/*.log    Stop: ./stop.sh"
