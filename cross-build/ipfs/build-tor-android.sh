#!/bin/bash
# build-tor-android.sh — Download Tor source and build it for Android arm64
# using Chromium's NDK, BoringSSL, libevent, and zlib.
# Runs INSIDE the chromium-win-cross container.
set -e

BUILD_DIR=/build
SRC_DIR=$BUILD_DIR/chromium/src
TOR_DIR=$SRC_DIR/third_party/tor
TOR_VERSION="0.4.8.13"
TOR_URL="https://archive.torproject.org/tor-package-archive/tor-${TOR_VERSION}.tar.gz"
OUT_DIR="out/android-arm64"

log() { echo "=== $(date '+%H:%M:%S') $* ==="; }

export PATH="/build/depot_tools:$PATH"
export DEPOT_TOOLS_METRICS=0
git config --global --add safe.directory '*' 2>/dev/null || true

cd $SRC_DIR

# ── 1. Download and extract Tor source ──────────────────────────────
if [ ! -d "$TOR_DIR/src/app" ]; then
    log "Downloading Tor $TOR_VERSION source"
    cd /tmp
    if [ ! -f "tor-${TOR_VERSION}.tar.gz" ]; then
        curl -fSL -o "tor-${TOR_VERSION}.tar.gz" "$TOR_URL"
    fi

    log "Extracting Tor source"
    tar xzf "tor-${TOR_VERSION}.tar.gz"

    # Copy source tree into third_party/tor/src/
    mkdir -p "$TOR_DIR/src"
    cp -a "tor-${TOR_VERSION}/src/"* "$TOR_DIR/src/"

    log "Tor source installed to $TOR_DIR/src/"
else
    log "Tor source already present at $TOR_DIR/src/"
fi

cd $SRC_DIR

# ── 2. Copy config/compat files from zip archive ────────────────────
log "Installing orconfig and compat headers"

# orconfig_android
mkdir -p "$TOR_DIR/orconfig_android"
cat > "$TOR_DIR/orconfig_android/orconfig.h" << 'ORCONFIG_ANDROID'
ORCONFIG_PLACEHOLDER_ANDROID
ORCONFIG_ANDROID

# orconfig_win (already exists but refresh)
mkdir -p "$TOR_DIR/orconfig_win"

# BoringSSL compat
mkdir -p "$TOR_DIR/compat_openssl/openssl"

# orconfig.h at root for default/linux
if [ ! -f "$TOR_DIR/orconfig.h" ]; then
    cp "$TOR_DIR/orconfig_android/orconfig.h" "$TOR_DIR/orconfig.h"
fi

# ── 3. Install BUILD.gn ─────────────────────────────────────────────
log "Installing BUILD.gn for Tor static library + executable"

# Append tor_binary executable target if not already present
if ! grep -q 'executable("tor_binary")' "$TOR_DIR/BUILD.gn"; then
    cat >> "$TOR_DIR/BUILD.gn" << 'GNEOF'

# Tor standalone executable for bundling with Chrome.
executable("tor_binary") {
  output_name = "tor"
  sources = [ "src/app/main/tor_main.c" ]

  configs -= [ "//build/config/compiler:chromium_code" ]
  configs += [ "//build/config/compiler:no_chromium_code" ]
  configs += [ ":tor_internal_config" ]

  deps = [ ":tor" ]
}
GNEOF
fi

# ── 4. Build tor binary for Android arm64 ───────────────────────────
log "Running gn gen for Android arm64"
gn gen "$OUT_DIR" 2>&1

log "Building tor binary for Android arm64"
autoninja -C "$OUT_DIR" -j 12 third_party/tor:tor_binary 2>&1

log "Build complete!"
ls -lh "$OUT_DIR/tor" 2>/dev/null || ls -lh "$OUT_DIR/tor_binary" 2>/dev/null

if [ -f "$OUT_DIR/tor" ]; then
    log "Tor binary size: $(stat -c%s "$OUT_DIR/tor") bytes"
fi
