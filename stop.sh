#!/usr/bin/env bash
# Stop everything started by run.sh: Cloudflare tunnel, Docker container
# (docker mode) and the native OCR server.
set -uo pipefail

source "$(dirname "$0")/scripts/common.sh"
cd "$ROOT"

# matching_pids <pattern> <candidate pids...>: keep only live pids whose command contains pattern
matching_pids() {
    local pattern="$1"; shift
    [[ $# -gt 0 ]] || return 0   # bash 3.2 treats an empty "$@" as unbound under set -u
    for pid in "$@"; do
        ps -p "$pid" -o command= 2>/dev/null | grep -q -- "$pattern" && echo "$pid"
    done | sort -u
}

# stop_pids <name> <pids...>: SIGTERM, then SIGKILL after 10s
stop_pids() {
    local name="$1"; shift
    if [[ $# -eq 0 ]]; then
        ok "$name not running"
        return
    fi
    for pid in "$@"; do
        kill "$pid" 2>/dev/null
        for _ in {1..10}; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 1
        done
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null
            ok "$name killed (pid $pid)"
        else
            ok "$name stopped (pid $pid)"
        fi
    done
}

# --- 1. Cloudflare tunnel -----------------------------------------------------
log "Cloudflare tunnel ($TUNNEL_NAME)"
candidates=$(cat "$RUN_DIR/tunnel.pid" 2>/dev/null; tunnel_pids)
# shellcheck disable=SC2086
stop_pids tunnel $(matching_pids "cloudflared tunnel" $candidates)
rm -f "$RUN_DIR/tunnel.pid"

# --- 2. Docker container (docker mode) ---------------------------------------
if [[ "$RUN_MODE" == docker ]]; then
    log "Docker container"
    if ! command -v docker >/dev/null || ! docker info >/dev/null 2>&1; then
        ok "Docker is not running"
    elif [[ -z "$(docker compose ps -q 2>/dev/null)" ]]; then
        ok "container not running"
    else
        docker compose down >"$RUN_DIR/docker-down.log" 2>&1 && ok "container removed" || cat "$RUN_DIR/docker-down.log"
    fi
fi

# --- 3. Native server ---------------------------------------------------------
log "Native OCR server (port $SERVER_PORT)"
# apple.pid is the pid file name used by older versions of run.sh
candidates=$(cat "$RUN_DIR/server.pid" "$RUN_DIR/apple.pid" 2>/dev/null; lsof -ti "tcp:$SERVER_PORT" -sTCP:LISTEN 2>/dev/null)
# shellcheck disable=SC2086
stop_pids server $(matching_pids "server.js" $candidates)
rm -f "$RUN_DIR/server.pid" "$RUN_DIR/apple.pid"
