#!/usr/bin/env bash
# Build a self-contained package for running the OCR API natively on another Mac
# (RUN_MODE=native, no Docker). The target only needs Node.js 18+ (and
# cloudflared for a public URL); no Xcode tools or npm install required.
#
# Output: dist/chrome-lens-ocr-mac-<version>-<commit>.tar.gz containing the app,
# production node_modules with sharp for both Intel and Apple Silicon, and a
# universal bin/apple-ocr.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

NAME=chrome-lens-ocr-mac
VERSION="$(node -p 'require("./package.json").version')-$(git rev-parse --short HEAD 2>/dev/null || echo local)"
DIST="$ROOT/dist"
STAGE="$DIST/$NAME"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

[[ "$(uname)" == Darwin ]] || { echo "package-mac.sh must run on macOS" >&2; exit 1; }
[[ -z "$(git status --porcelain 2>/dev/null)" ]] || echo "warning: working tree has uncommitted changes" >&2

log "Staging app files"
rm -rf "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/scripts"
cp -R server.js src public package.json package-lock.json run.sh stop.sh SETUP.md API_DOCUMENTATION.md "$STAGE/"
cp scripts/common.sh "$STAGE/scripts/"
cat >"$STAGE/.env.example" <<'EOF'
RUN_MODE=native
TUNNEL_NAME=ocr-02
PUBLIC_URL=https://ocr-02.webmcp.vn
EOF

log "Building universal bin/apple-ocr (x86_64 + arm64)"
for arch in x86_64 arm64; do
    swiftc -O -target "$arch-apple-macos13" apple-ocr/AppleOCR.swift -o "$TMP/apple-ocr-$arch" 2>"$TMP/swiftc-$arch.log" \
        || { cat "$TMP/swiftc-$arch.log"; exit 1; }
done
lipo -create "$TMP/apple-ocr-x86_64" "$TMP/apple-ocr-arm64" -output "$STAGE/bin/apple-ocr"

log "Installing production dependencies"
(cd "$STAGE" && npm ci --omit=dev --no-audit --no-fund --loglevel=error)

# npm only installs sharp's native binaries for the build machine's CPU; add the other one
for cpu in x64 arm64; do
    if ! ls -d "$STAGE/node_modules/@img/sharp-darwin-$cpu" >/dev/null 2>&1; then
        log "Adding sharp native binaries for darwin-$cpu"
        mkdir -p "$TMP/$cpu"
        cp package.json package-lock.json "$TMP/$cpu/"
        (cd "$TMP/$cpu" && npm ci --omit=dev --os=darwin --cpu="$cpu" --no-audit --no-fund --loglevel=error)
        cp -R "$TMP/$cpu/node_modules/@img/"*"-darwin-$cpu" "$STAGE/node_modules/@img/"
    fi
done

log "Creating archive"
ARCHIVE="$DIST/$NAME-$VERSION.tar.gz"
tar -czf "$ARCHIVE" -C "$DIST" "$NAME"
rm -rf "$STAGE"

echo
echo "Package: $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"
