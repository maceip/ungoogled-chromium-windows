#!/bin/bash
# android-build.sh
#
# Build ipfs-chromium for Android using the cross-compilation Docker image.
# Run inside the chromium-win-cross container with /build mounted as a volume.
#
# Prerequisites:
#   - Run ipfs-build.sh --patch-only first (or a full Windows build) to set up
#     source tree, patches, and IPFS component
#   - .gclient must include target_os = ["win", "android"]
#
# Usage:
#   ./android-build.sh [--sync-only] [--build-only] [--jobs=N]
#

set -e

BUILD_DIR=/build
CHROMIUM_TAG="145.0.7561.2"
OUT_DIR="out/android-arm64"

# Parse args
SYNC_ONLY=0
BUILD_ONLY=0
JOBS=$(( $(nproc) / 2 ))

while [ -n "$1" ]; do
    case "$1" in
        --sync-only)     SYNC_ONLY=1 ;;
        --build-only)    BUILD_ONLY=1 ;;
        --jobs=*)        JOBS="${1#*=}" ;;
        -h|--help)
            echo "Usage: $0 [--sync-only] [--build-only] [--jobs=N]"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

log() { echo "=== $(date '+%H:%M:%S') $* ==="; }

# ── 0. Environment setup ────────────────────────────────────────────
export PATH="/build/depot_tools:$PATH"
export DEPOT_TOOLS_METRICS=0
export GCLIENT_SUPPRESS_GIT_VERSION_WARNING=1

# Allow git to work on directories owned by other users
git config --global --add safe.directory '*' 2>/dev/null || true

cd $BUILD_DIR

if [ "$BUILD_ONLY" != "1" ]; then

# ── 1. Sync Android dependencies ────────────────────────────────────
cd $BUILD_DIR/chromium

# Ensure .gclient includes Android target
if ! grep -q '"android"' .gclient 2>/dev/null; then
    log "ERROR: .gclient does not include android in target_os"
    log "Run ipfs-build.sh first (it creates .gclient with target_os = [\"win\", \"android\"])"
    exit 1
fi

log "Syncing Android dependencies (gclient sync)"
gclient sync --no-history --nohooks 2>&1

cd src

log "Running gclient runhooks for Android"
gclient runhooks 2>&1

cd $BUILD_DIR

fi # end of sync section

[ "$SYNC_ONLY" = "1" ] && { log "Sync complete. Exiting."; exit 0; }

# ── 2. Verify IPFS patches are applied ──────────────────────────────
cd $BUILD_DIR/chromium/src

if [ ! -f components/ipfs/BUILD.gn ]; then
    log "IPFS component not found - patches must be applied first"
    log "Run ipfs-build.sh --patch-only first, then run this script with --build-only"
    exit 1
fi

# ── 3. Configure GN and build ───────────────────────────────────────
log "Configuring GN build for Android arm64"

mkdir -p "$OUT_DIR"

cat > "$OUT_DIR/args.gn" << GNARGS
# Target: Android arm64
target_os = "android"
target_cpu = "arm64"

# Build configuration
is_debug = false
is_official_build = false
is_component_build = false

# Toolchain
is_clang = true
use_lld = true
treat_warnings_as_errors = false
enable_rust = true

# Build speed
use_siso = true

# Disable things we don't need
chrome_pgo_phase = 0
enable_nacl = false
dcheck_always_on = false

# Symbols
symbol_level = 0
blink_symbol_level = 0
v8_symbol_level = 0

# IPFS
enable_ipfs = true

# Android-specific
android_static_analysis = "off"
GNARGS

log "GN args written to $OUT_DIR/args.gn"
cat "$OUT_DIR/args.gn"
echo ""

# Generate ninja files
log "Running gn gen"
gn gen "$OUT_DIR" 2>&1

# Build
log "Starting Android build with $JOBS jobs"
autoninja -C "$OUT_DIR" -j "$JOBS" chrome_public_apk 2>&1

log "Build complete!"
ls -lh "$OUT_DIR/apks/ChromePublic.apk" 2>/dev/null

# end android-build.sh
