#!/bin/bash
# verify-components.sh — Compile all sovereignty component .obj files
# Run this BEFORE starting any full build. Takes minutes, not hours.
#
# Usage: docker exec win-build bash /build/verify-components.sh
#   or:  ./verify-components.sh  (from inside the container)

set -e

SRC=/build/chromium/src
WIN_OUT=out/win-component
ANDROID_OUT=out/android-arm64

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ERRORS=0

compile_obj() {
    local target="$1"
    local label="$2"
    printf "  %-60s " "$label"
    if ninja -C "$SRC/$WIN_OUT" "$target" > /tmp/verify-$$.log 2>&1; then
        printf "${GREEN}OK${NC}\n"
    else
        printf "${RED}FAIL${NC}\n"
        cat /tmp/verify-$$.log
        ERRORS=$((ERRORS + 1))
    fi
    rm -f /tmp/verify-$$.log
}

echo ""
echo "=== Sovereignty Component Verification ==="
echo ""

echo "--- Sovereignty core ---"
compile_obj "obj/components/sovereignty/sovereignty/sovereignty_log.obj" "sovereignty_log.obj"
compile_obj "obj/components/sovereignty/sovereignty/pipe_registry.obj" "pipe_registry.obj"

echo ""
echo "--- Tor component ---"
compile_obj "obj/components/tor/tor/tor_service.obj" "tor_service.obj"
compile_obj "obj/components/tor/tor/tor_process_manager.obj" "tor_process_manager.obj"
compile_obj "obj/components/tor/tor/tor_control_util.obj" "tor_control_util.obj"
compile_obj "obj/components/tor/tor/tor_preferences.obj" "tor_preferences.obj"
compile_obj "obj/components/tor/tor/onion_interceptor.obj" "onion_interceptor.obj"
compile_obj "obj/components/tor/tor/onion_url_loader.obj" "onion_url_loader.obj"
compile_obj "obj/components/tor/tor/hidden_service_manager.obj" "hidden_service_manager.obj"

echo ""
echo "--- IPFS component ---"
compile_obj "obj/components/ipfs/ipfs/preferences.obj" "preferences.obj"
compile_obj "obj/components/ipfs/ipfs/interceptor.obj" "interceptor.obj"
compile_obj "obj/components/ipfs/ipfs/inter_request_state.obj" "inter_request_state.obj"
compile_obj "obj/components/ipfs/ipfs/chromium_ipfs_context.obj" "chromium_ipfs_context.obj"

echo ""
echo "=== Pref Path Audit ==="
echo ""

# Verify all pref paths are under sovereignty.*
BAD_PREFS=$(grep -rn '"tor\.\|"ipfs\.' \
    "$SRC/components/tor/" \
    "$SRC/components/ipfs/" \
    "$SRC/components/sovereignty/" \
    --include='*.cc' --include='*.h' 2>/dev/null | \
    grep -v 'sovereignty\.' | \
    grep -v '//' | \
    grep -v 'TODO' | \
    grep -v 'FILE_PATH_LITERAL' | \
    grep -v '\.exe\|\.log\|\.pid\|\.torrc' || true)

if [ -n "$BAD_PREFS" ]; then
    printf "${RED}PREF PATH VIOLATIONS:${NC}\n"
    echo "$BAD_PREFS"
    ERRORS=$((ERRORS + 1))
else
    printf "${GREEN}All pref paths under sovereignty.* namespace${NC}\n"
fi

echo ""
echo "=== Summary ==="
if [ $ERRORS -eq 0 ]; then
    printf "${GREEN}All checks passed.${NC}\n"
else
    printf "${RED}$ERRORS check(s) failed.${NC}\n"
    exit 1
fi
