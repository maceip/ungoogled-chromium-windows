#!/bin/bash
# ipfs-build.sh
#
# Build ipfs-chromium for Windows using the cross-compilation Docker image.
# Run inside the chromium-win-cross container with /build mounted as a volume.
#
# Usage:
#   ./ipfs-build.sh [--fetch-only] [--patch-only] [--build-only] [--clean-patches]
#
# The build directory layout:
#   /build/
#     depot_tools/      - Google's build tools
#     ipfs-chromium/    - The ipfs-chromium repo (patches + component)
#     chromium/src/     - Full Chromium source tree
#

set -e

BUILD_DIR=/build
CHROMIUM_TAG="145.0.7561.2"
IPFS_REPO="https://github.com/little-bear-labs/ipfs-chromium.git"
IPFS_BRANCH="main"
OUT_DIR="out/win-component"

# Parse args
FETCH_ONLY=0
PATCH_ONLY=0
BUILD_ONLY=0
CLEAN_PATCHES=0
JOBS=$(( $(nproc) / 2 ))

while [ -n "$1" ]; do
    case "$1" in
        --fetch-only)    FETCH_ONLY=1 ;;
        --patch-only)    PATCH_ONLY=1 ;;
        --build-only)    BUILD_ONLY=1 ;;
        --clean-patches) CLEAN_PATCHES=1 ;;
        --jobs=*)        JOBS="${1#*=}" ;;
        --tag=*)         CHROMIUM_TAG="${1#*=}" ;;
        -h|--help)
            echo "Usage: $0 [--fetch-only] [--patch-only] [--build-only] [--clean-patches] [--jobs=N] [--tag=VERSION]"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

log() { echo "=== $(date '+%H:%M:%S') $* ==="; }

# ── 0. Environment setup ────────────────────────────────────────────
export PATH="/build/depot_tools:$PATH"

# Tell Chromium to use OUR Windows SDK via win_toolchain.json
# DEPOT_TOOLS_WIN_TOOLCHAIN=1 makes setup_toolchain.py read SetEnv.*.json
# instead of trying to run vcvarsall.bat
export DEPOT_TOOLS_WIN_TOOLCHAIN=1
export GYP_MSVS_OVERRIDE_PATH=/opt/microsoft
export GYP_MSVS_VERSION=2022
export vs2022_install=/opt/microsoft
export WINDOWSSDKDIR="/opt/microsoft/Windows Kits/10"
export vs_path=/opt/microsoft
export winsdk="/opt/microsoft/Windows Kits/10"

# Suppress depot_tools nags and telemetry
export DEPOT_TOOLS_METRICS=0
export GCLIENT_SUPPRESS_GIT_VERSION_WARNING=1

# Allow git to work on directories owned by other users (needed when running as root)
git config --global --add safe.directory '*' 2>/dev/null || true

# Locate cross-patches (bundled in Docker image or in repo)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CROSS_PATCHES_DIR="$SCRIPT_DIR/cross-patches"

cd $BUILD_DIR

# ── 1. depot_tools ──────────────────────────────────────────────────
if [ ! -d depot_tools ]; then
    log "Cloning depot_tools"
    git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git
else
    log "depot_tools already present"
fi

# ── 2. ipfs-chromium repo ──────────────────────────────────────────
if [ ! -d ipfs-chromium ]; then
    log "Cloning ipfs-chromium"
    git clone --branch "$IPFS_BRANCH" "$IPFS_REPO"
else
    log "ipfs-chromium already present, updating"
    (cd ipfs-chromium && git fetch origin && git reset --hard "origin/$IPFS_BRANCH")
fi

# Determine the best chromium_edits version directory
EDITS_DIR="ipfs-chromium/chromium_edits"
if [ -d "$EDITS_DIR/$CHROMIUM_TAG" ]; then
    PATCH_VERSION="$CHROMIUM_TAG"
    log "Using exact patch version: $PATCH_VERSION"
else
    # Find closest version directory
    PATCH_VERSION=$(ls -1 "$EDITS_DIR" | sort -V | tail -1)
    log "No exact match for $CHROMIUM_TAG, using closest: $PATCH_VERSION"
fi

if [ "$PATCH_ONLY" = "1" ] || [ "$BUILD_ONLY" = "1" ]; then
    # Skip fetch for patch/build-only modes
    true
else

# ── 3. Fetch Chromium source ───────────────────────────────────────
mkdir -p chromium
cd chromium

# Create .gclient config pinned to the exact tag
cat > .gclient << GCLIENT
solutions = [
  {
    "name": "src",
    "url": "https://chromium.googlesource.com/chromium/src.git@$CHROMIUM_TAG",
    "managed": False,
    "custom_deps": {},
    "custom_vars": {
      "checkout_nacl": False,
      "checkout_pgo_profiles": False,
    },
  },
]
target_os = ["win", "android"]
GCLIENT

if [ ! -f .sync-done ]; then
    log "Syncing Chromium $CHROMIUM_TAG (this will take a while...)"
    gclient sync --no-history --nohooks 2>&1
    touch .sync-done
else
    log "Chromium source already synced"
fi

cd src

# Run hooks (generates build files, downloads toolchains, etc.)
if [ ! -f ../../.hooks-done ]; then
    log "Running gclient runhooks..."
    gclient runhooks 2>&1
    touch ../../.hooks-done
fi

cd $BUILD_DIR

fi # end of fetch section

[ "$FETCH_ONLY" = "1" ] && { log "Fetch complete. Exiting."; exit 0; }

# ── 4. Apply ipfs-chromium patches ─────────────────────────────────
cd $BUILD_DIR/chromium/src

if [ "$CLEAN_PATCHES" = "1" ]; then
    log "Cleaning previous patches"
    git checkout -- . 2>/dev/null || true
    git clean -fd 2>/dev/null || true
fi

if [ ! -f ../../.patches-applied ]; then
    log "Applying ipfs-chromium patches from $PATCH_VERSION"

    EDIT_SRC="$BUILD_DIR/$EDITS_DIR/$PATCH_VERSION"

    # Walk through all files in the chromium_edits version directory
    (cd "$EDIT_SRC" && find . -type f) | while read -r file; do
        # Strip leading ./
        file="${file#./}"

        src="$EDIT_SRC/$file"

        if [[ "$file" == *.patch ]]; then
            # Apply as git patch
            target="${file%.patch}"
            log "  Patching: $target"
            git apply --check "$src" 2>/dev/null && \
                git apply "$src" || \
                { echo "  WARN: patch failed for $target (may already be applied)"; }

        elif [[ "$file" == *.rm ]]; then
            # Remove the target file
            target="${file%.rm}"
            log "  Removing: $target"
            rm -f "$target"

        else
            # Copy file directly into source tree
            target="$file"
            log "  Copying: $target"
            mkdir -p "$(dirname "$target")"
            cp "$src" "$target"
        fi
    done

    # Apply cross-compilation patches (fix tool paths for Linux)
    if [ -d "$CROSS_PATCHES_DIR" ]; then
        log "Applying cross-compilation patches"
        for patch in "$CROSS_PATCHES_DIR"/*.patch; do
            [ -f "$patch" ] || continue
            log "  Applying: $(basename "$patch")"
            git apply "$patch" 2>/dev/null || \
                echo "  WARN: $(basename "$patch") may already be applied or doesn't match"
        done
    fi

    # Patch vs_toolchain.py: skip copying debug DLLs on Linux
    # (dbghelp.dll, dbgcore.dll are not available in our cross-compilation SDK)
    log "Patching vs_toolchain.py for cross-compilation"
    python3 -c "
p = 'build/vs_toolchain.py'
t = open(p).read()
old = 'def _CopyDebugger(target_dir, target_cpu):'
new = old + '''
  import platform
  if platform.system() != 'Windows':
    return'''
if old in t and 'platform.system' not in t.split('_CopyDebugger')[2][:200]:
    t = t.replace(old, new, 1)
    open(p, 'w').write(t)
    print('  Patched _CopyDebugger to skip on Linux')
else:
    print('  _CopyDebugger already patched or not found')
"

    # Patch vs_toolchain.py Update(): skip ciopfs FUSE mount on Linux
    # (ciopfs doesn't work in rootless Docker; we use case-fold symlinks instead)
    log "Patching vs_toolchain.py Update() for Linux"
    python3 -c "
import os, json
p = 'build/vs_toolchain.py'
t = open(p).read()
old = 'def Update(force=False, no_download=False):'
new = old + '''
  import platform
  if platform.system() != \"Windows\" and os.path.isdir('/opt/microsoft/VC'):
    if not os.path.exists(json_data_file):
      import json
      with open(json_data_file, \"w\") as f:
        json.dump({\"path\": \"/opt/microsoft\"}, f)
    return 0'''
if old in t and \"'/opt/microsoft/VC'\" not in t.split('def Update')[1][:500]:
    t = t.replace(old, new, 1)
    open(p, 'w').write(t)
    print('  Patched Update() to skip ciopfs on Linux')
else:
    print('  Update() already patched or not found')
"

    # Fix IPFS web_contents scope for Android builds
    # (web_contents is declared inside a !IS_ANDROID block but used by IPFS code)
    log "Fixing IPFS Android compatibility (web_contents scope)"
    python3 -c "
p = 'chrome/browser/chrome_content_browser_client.cc'
t = open(p).read()
old = '#if BUILDFLAG(ENABLE_IPFS)\n  if (!web_contents) {'
if old in t:
    new = ('#if BUILDFLAG(ENABLE_IPFS)\n'
           '#if !(BUILDFLAG(IS_CHROMEOS) || BUILDFLAG(ENABLE_EXTENSIONS_CORE) || \\\\\n'
           '      !BUILDFLAG(IS_ANDROID))\n'
           '  content::RenderFrameHost* frame_host =\n'
           '      RenderFrameHost::FromID(render_process_id, render_frame_id);\n'
           '  WebContents* web_contents = WebContents::FromRenderFrameHost(frame_host);\n'
           '#endif\n'
           '  if (!web_contents) {')
    t = t.replace(old, new, 1)
    open(p, 'w').write(t)
    print('  Fixed web_contents scope for Android')
else:
    print('  web_contents fix already applied or not needed')
"

    # Fix MurmurHash3 duplicate symbol conflict (ipfs_client vs Chromium smhasher)
    # Only matters for static/monolithic builds (Android), but safe to apply always
    log "Fixing MurmurHash3 duplicate symbol conflict"
    python3 -c "
p = 'third_party/ipfs_client/BUILD.gn'
import os
if not os.path.exists(p):
    print('  ipfs_client BUILD.gn not found yet, skipping')
else:
    t = open(p).read()
    changed = False

    # Remove bundled MurmurHash3.cc from sources
    for pattern in ['       \"src/smhasher/MurmurHash3.cc\", \n',
                    '       \"src/smhasher/MurmurHash3.cc\",\n']:
        if pattern in t:
            t = t.replace(pattern, '')
            changed = True

    # Add Chromium's smhasher as dependency
    old_deps = '\"//third_party/abseil-cpp:absl\",\n        \"//base\",\n      ]'
    new_deps = '\"//third_party/abseil-cpp:absl\",\n        \"//base\",\n        \"//third_party/smhasher:murmurhash3\",\n      ]'
    if '//third_party/smhasher:murmurhash3' not in t and old_deps in t:
        t = t.replace(old_deps, new_deps)
        changed = True

    if changed:
        open(p, 'w').write(t)
        print('  Updated ipfs_client BUILD.gn')
    else:
        print('  ipfs_client BUILD.gn already fixed or pattern not found')

    # Update smhasher visibility
    p2 = 'third_party/smhasher/BUILD.gn'
    if os.path.exists(p2):
        t2 = open(p2).read()
        if '//third_party/ipfs_client' not in t2:
            old_vis = '\"//third_party/nearby:connections_implementation_mediums\",\n  ]'
            new_vis = '\"//third_party/nearby:connections_implementation_mediums\",\n    \"//third_party/ipfs_client:*\",\n  ]'
            if old_vis in t2:
                t2 = t2.replace(old_vis, new_vis)
                open(p2, 'w').write(t2)
                print('  Updated smhasher visibility')
"

    touch ../../.patches-applied
    log "Patches applied"
else
    log "Patches already applied"
fi

# ── 5. Sync ipfs component and library source ─────────────────────
IPFS_CLIENT_VERSION="0.0.1.6"

if [ ! -f components/ipfs/BUILD.gn ]; then
    log "Syncing ipfs component source and generating BUILD.gn"
    mkdir -p components/ipfs
    python3 - "$BUILD_DIR/ipfs-chromium/component" "components/ipfs" <<'PYEOF'
import os, glob, shutil, sys
src_dir = sys.argv[1]
dst_dir = sys.argv[2]
sources = []
for f in sorted(glob.glob(os.path.join(src_dir, '*'))):
    bn = os.path.basename(f)
    if bn.endswith('.in') or bn.endswith('_unittest.cc') or bn.startswith('opinionated_') or bn == 'CMakeLists.txt':
        continue
    if os.path.isfile(f):
        shutil.copy2(f, os.path.join(dst_dir, bn))
        if bn.endswith('.cc') or bn.endswith('.h'):
            sources.append(bn)
tmpl = open(os.path.join(src_dir, 'BUILD.gn.in')).read()
formatted = '\n'.join(f'    "{s}",' for s in sorted(sources))
build_gn = tmpl.replace('@gn_sources@', formatted)
open(os.path.join(dst_dir, 'BUILD.gn'), 'w').write(build_gn)
print(f'  Generated BUILD.gn with {len(sources)} source files')
PYEOF
fi

if [ ! -d third_party/ipfs_client ]; then
    log "Downloading ipfs_client library v$IPFS_CLIENT_VERSION"
    IPFS_CLIENT_URL="https://gitlab.com/jbt/ipfs_client/-/archive/$IPFS_CLIENT_VERSION/ipfs_client-$IPFS_CLIENT_VERSION.tar.gz"
    wget -q "$IPFS_CLIENT_URL" -O /tmp/ipfs_client.tar.gz
    tar xzf /tmp/ipfs_client.tar.gz -C third_party/
    mv "third_party/ipfs_client-$IPFS_CLIENT_VERSION" third_party/ipfs_client
    rm /tmp/ipfs_client.tar.gz
    log "ipfs_client library synced"
fi

# ── 5b. Create win_toolchain.json for Chromium's build system ─────
MSVC_VER=$(basename /opt/microsoft/VC/Tools/MSVC/*)
SDK_VER=$(ls /opt/microsoft/Windows\ Kits/10/Lib/ | sort -V | tail -1)
log "Setting up win_toolchain.json (MSVC=$MSVC_VER, SDK=$SDK_VER)"

REDIST_BASE="/opt/microsoft/VC/Redist/MSVC/$MSVC_VER"
cat > build/win_toolchain.json << WINTOOLCHAIN
{
  "path": "/opt/microsoft",
  "version": "2022",
  "win_sdk": "/opt/microsoft/Windows Kits/10",
  "wdk": "",
  "runtime_dirs": [
    "$REDIST_BASE/x64/Microsoft.VC143.CRT",
    "$REDIST_BASE/x86/Microsoft.VC143.CRT",
    "$REDIST_BASE/arm64/Microsoft.VC143.CRT"
  ]
}
WINTOOLCHAIN

[ "$PATCH_ONLY" = "1" ] && { log "Patches applied. Exiting."; exit 0; }

# ── 5c. Fix case-sensitivity for Windows SDK headers ──────────────
# Linux is case-sensitive; Windows headers are included with varying case.
# Create symlinks for headers that case-fold.sh in the Docker image missed.
log "Creating missing case-fold symlinks for Windows SDK headers"
for d in /opt/microsoft/Windows\ Kits/10/Include/*/um; do
    [ -d "$d" ] || continue
    cd "$d"
    for pair in \
        "D3D11_1.h:d3d11_1.h" \
        "D3D11_2.h:d3d11_2.h" \
        "D3D11_3.h:d3d11_3.h" \
        "D3D11_4.h:d3d11_4.h" \
        "D3D11.h:d3d11.h" \
        "D3Dcompiler.h:d3dcompiler.h" \
        "D3D11SDKLayers.h:d3d11sdklayers.h"
    do
        upper="${pair%%:*}"
        lower="${pair##*:}"
        [ -f "$lower" ] && [ ! -f "$upper" ] && ln -sv "$lower" "$upper"
    done
done
cd $BUILD_DIR/chromium/src

# ── 6. Configure GN and build ─────────────────────────────────────
log "Configuring GN build"

mkdir -p "$OUT_DIR"

cat > "$OUT_DIR/args.gn" << GNARGS
# Target: Windows x64, component build with siso
target_os = "win"
target_cpu = "x64"
is_component_build = true
is_debug = false
is_official_build = false

# Toolchain - use Chromium's bundled clang and Rust for full compatibility
is_clang = true
use_lld = true
treat_warnings_as_errors = false
enable_rust = true

# Siso / build speed
use_siso = true

# Disable things we don't need for cross-compilation
use_sysroot = false
chrome_pgo_phase = 0
enable_nacl = false
dcheck_always_on = false

# Symbols
symbol_level = 0
blink_symbol_level = 0
v8_symbol_level = 0

# IPFS
enable_ipfs = true
GNARGS

log "GN args written to $OUT_DIR/args.gn"
cat "$OUT_DIR/args.gn"
echo ""

# Create stub debug DLLs that _CopyDebugger would normally provide on Windows
# These are system DLLs Windows already has; the installer archive just needs files to copy
log "Creating stub debug DLLs for installer archive"
for dll in dbgcore.dll dbghelp.dll; do
    if [ ! -f "$OUT_DIR/$dll" ]; then
        python3 -c "
import struct
dos = bytearray(64); dos[0:2] = b'MZ'; struct.pack_into('<I', dos, 60, 64)
coff = struct.pack('<HHIIIHH', 0x8664, 0, 0, 0, 0, 0, 0x2022)
open('$OUT_DIR/$dll', 'wb').write(dos + b'PE\x00\x00' + coff)
"
        log "  Created stub $dll"
    fi
done

# Generate ninja files
log "Running gn gen"
gn gen "$OUT_DIR" --fail-on-unused-args 2>&1 || {
    echo "gn gen failed, trying without --fail-on-unused-args..."
    gn gen "$OUT_DIR" 2>&1
}

# Build
log "Starting build with $JOBS jobs"
autoninja -C "$OUT_DIR" -j "$JOBS" chrome chromedriver mini_installer 2>&1

log "Build complete!"
ls -lh "$OUT_DIR/chrome.exe" "$OUT_DIR/mini_installer.exe" 2>/dev/null

# end ipfs-build.sh
