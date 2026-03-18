# Chromium + IPFS + Tor: Cross-Build Guide

**Chromium version**: 145.0.7561.2
**Tor version**: 0.4.8.13 (client-only mode — relay/dirauth/dircache modules disabled)
**Targets**: Windows x86_64, Android arm64

---

## Prerequisites

- Docker (rootless OK, tested with UID 1001)
- ~100GB disk for Chromium source + build artifacts
- Host: Linux x86_64

## Docker Images

Built from `/home/devuser/ungoogled-chromium-windows/cross-build/`:

```bash
# Base image (Debian + depot_tools + build deps, 17.8GB)
make base        # builds chromium-win-cross-base:latest

# MSVC image (adds MSVC 17.14 + Windows SDK, 29GB, PRIVATE)
make msvc        # builds chromium-win-cross:latest
```

Registry: `ghcr.io/stare-network/chromium-win-cross-base:latest` (public), `ghcr.io/stare-network/chromium-win-cross:latest` (private).

## Container Setup

```bash
# Create build volume
mkdir -p /home/devuser/chromium-win-build
sudo chown -R 166559:165636 /home/devuser/chromium-win-build

# Run container (interactive)
docker run -d --name ipfs-build \
  -v /home/devuser/chromium-win-build:/build \
  chromium-win-cross:latest sleep infinity

# Or use the build script directly:
docker run --name ipfs-build \
  -v /home/devuser/chromium-win-build:/build \
  chromium-win-cross:latest /build/ipfs-build.sh
```

---

## Windows x86_64 Build

### Step 1: Sync Chromium + Apply Patches

```bash
docker exec ipfs-build bash -c '
  export PATH="/build/depot_tools:$PATH"
  export DEPOT_TOOLS_METRICS=0
  cd /build
  /build/ipfs-build.sh --sync-only
'
```

This fetches Chromium 145.0.7561.2 via `gclient sync`, applies IPFS patches, generates `components/ipfs/BUILD.gn`, and sets up the Windows sysroot.

### Step 2: Case-fold Windows Headers

```bash
docker exec ipfs-build bash -c '
  cd /build/chromium/src
  bash /build/cross-build/case-fold.sh
'
```

Creates lowercase symlinks for Windows SDK headers (required for case-sensitive Linux FS).

### Step 3: Build for Windows

```bash
docker exec ipfs-build bash -c '
  export PATH="/build/depot_tools:$PATH"
  export DEPOT_TOOLS_METRICS=0
  cd /build/chromium/src

  # GN args are in out/win-component/args.gn (written by ipfs-build.sh)
  gn gen out/win-component
  autoninja -C out/win-component -j 12 mini_installer
'
```

#### Key GN args (out/win-component/args.gn):
```gn
target_os = "win"
target_cpu = "x64"
is_debug = false
is_official_build = false
is_component_build = true
is_clang = true
use_lld = true
treat_warnings_as_errors = false
enable_rust = true
chrome_pgo_phase = 0
enable_nacl = false
symbol_level = 0
enable_ipfs = true
```

### Windows Output Artifacts

| File | Size | Description |
|------|------|-------------|
| `out/win-component/mini_installer.exe` | 442MB | Self-extracting installer |
| `out/win-component/chrome.exe` | 1.4MB | Chrome launcher |
| `out/win-component/chrome.dll` | ~200MB | Main Chrome library |
| `out/win-component/components_tor.dll` | 2.6MB | Tor component (C++ integration) |
| `out/win-component/tor.exe` | 8.6MB | Tor binary (pre-built from Expert Bundle) |

---

## Android arm64 Build

### Step 1: Sync Android Dependencies

```bash
# Update .gclient to include android target_os
docker exec ipfs-build bash -c '
  cd /build/chromium
  # Ensure .gclient has: target_os = ["win", "android"]
  gclient sync --no-history --nohooks
  cd src && gclient runhooks
'
```

### Step 2: Build Chrome APK + Tor Binary

```bash
docker exec ipfs-build bash -c '
  export PATH="/build/depot_tools:$PATH"
  export DEPOT_TOOLS_METRICS=0
  cd /build/chromium/src
  gn gen out/android-arm64
  autoninja -C out/android-arm64 -j 12 chrome_public_apk
'
```

#### Key GN args (out/android-arm64/args.gn):
```gn
target_os = "android"
target_cpu = "arm64"
is_debug = false
is_official_build = false
is_component_build = false
is_clang = true
use_lld = true
treat_warnings_as_errors = false
enable_rust = true
chrome_pgo_phase = 0
enable_nacl = false
symbol_level = 0
enable_ipfs = true
android_static_analysis = "off"
```

The tor binary is built as a GN dependency and automatically bundled into the APK as `libtor.so` via:
- `third_party/tor/BUILD.gn` -> `copy("tor_binary_named_as_so")` renames `tor` -> `libtor.so`
- `chrome/android/chrome_public_apk_tmpl.gni` -> `loadable_modules += [ "$root_out_dir/libtor.so" ]`

To build just the tor binary standalone:
```bash
autoninja -C out/android-arm64 -j 12 third_party/tor:tor_binary
```

### Android Output Artifacts

| File | Size | Description |
|------|------|-------------|
| `out/android-arm64/apks/ChromePublic.apk` | 320MB | Android APK |
| `out/android-arm64/tor` | 3.1MB | Tor binary (ELF aarch64) |

APK contains in `lib/arm64-v8a/`:
- `libchrome.so` (206MB) -- main Chrome
- `libtor.so` (3.1MB) -- Tor binary
- `libchrome_crashpad_handler.so` (1.8MB) -- crash handler

---

## Custom Files Reference

### Tor Source Build (`third_party/tor/`)
- `BUILD.gn` -- Full GN build: hashx, equix, trunnel source_sets + tor static_library + tor_binary executable
- `client_stubs.c` -- Stubs for disabled relay/dirauth/dircache modules (~25 functions)
- `boringssl_compat.h` -- BoringSSL<->OpenSSL compatibility (DHE ciphers, OSSL_HANDSHAKE_STATE, EC_GFp stubs)
- `config_openssl.h` -- Conditional include of boringssl_compat.h
- `orconfig_android/orconfig.h` -- Android aarch64 config (client-only: relay/dirauth/dircache disabled)
- `orconfig_win/orconfig.h` -- Windows x86_64 config
- `compat_openssl/` -- CRYPTO_ctr128_encrypt impl, openssl/modes.h shim, wincrypt.h shim
- `src/` -- Tor 0.4.8.13 source tree (downloaded from archive.torproject.org)
- `binaries/win-x64/tor.exe` -- Pre-built Windows Tor binary (from Tor Expert Bundle)

### Libevent (`third_party/libevent/`)
- `BUILD.gn` -- static_library for libevent 2.1.12-stable
- `evconfig-private.h` -- Generated config (epoll, eventfd, clock_gettime)
- `include/event2/event-config.h` -- Generated public config
- `openssl-compat.h` -- Internal libevent header for BoringSSL compat
- Source files: Full libevent 2.1.12-stable (buffer.c, event.c, epoll.c, etc.)

### Tor Component (`components/tor/`)
- `BUILD.gn` -- component("tor") shared library
- `tor_service.cc/h` -- Per-BrowserContext service (SupportsUserData)
- `tor_process_manager.cc/h` -- Launches tor binary, control port bootstrap
- `onion_interceptor.cc/h` -- URLLoaderRequestInterceptor for .onion
- `onion_url_loader.cc/h` -- SOCKS5 proxy via per-site NetworkContext
- `hidden_service_manager.cc/h` -- ADD_ONION ephemeral/persistent hidden services
- `tor_preferences.cc/h` -- User prefs (enable/disable, data dir)
- `tor_features.cc/h` -- Feature flag
- `tor_control_util.cc/h` -- Control port command helper
- `tor_export.h` -- COMPONENT_EXPORT(TOR) macro

### Chrome Integration Points (patches to existing Chromium files)
- `chrome/browser/ipfs_extra_parts.cc` -- PostProfileInit creates IPFS + Tor services
- `chrome/browser/chrome_content_browser_client.cc:~6453` -- OnionInterceptor registration
- `chrome/browser/prefs/browser_prefs.cc:~1668` -- tor::RegisterTorPreferences
- `chrome/browser/BUILD.gn:2643` -- deps on `//components/ipfs`, `//components/tor`
- `chrome/android/chrome_public_apk_tmpl.gni:~676` -- libtor.so in loadable_modules
- `net/base/is_potentially_trustworthy.cc` -- .onion treated as secure context (RFC 7686)

### Build Scripts
- `ipfs-build.sh` -- Main Windows build script (sync, patch, configure, build)
- `android-build.sh` -- Android APK build script
- `build-tor-android.sh` -- Standalone Tor Android build script
- `fix_ipfs_android.py` -- Fixes IPFS Android compilation issues
- `fix_murmurhash_conflict.py` -- Resolves MurmurHash3 symbol conflicts

---

## Tor Client-Only Mode

The current build disables three server-side Tor modules to avoid pulling in relay dependencies:

| Module | What it does | Why disabled |
|--------|-------------|--------------|
| `HAVE_MODULE_RELAY` | Forward traffic for other Tor users | Browser should never be a relay |
| `HAVE_MODULE_DIRAUTH` | Act as a directory authority | Only ~10 exist globally |
| `HAVE_MODULE_DIRCACHE` | Cache and serve directory data | Requires relay infrastructure |

These are disabled via `#undef` in `orconfig_android/orconfig.h` and stubbed in `client_stubs.c`.

**All client functionality works**: connecting to Tor, browsing .onion sites, building circuits, hosting hidden services via ADD_ONION control port command.

---

## Reproducibility Notes

- Chromium's bundled clang (22.0.0) and Rust from `third_party/llvm-build` and `third_party/rust-toolchain` -- NOT system toolchain
- Android NDK r28 from `third_party/android_toolchain/ndk/`
- Target: `aarch64-linux-android29`
- Tor source: https://archive.torproject.org/tor-package-archive/tor-0.4.8.13.tar.gz
- Libevent source: https://github.com/libevent/libevent/releases/download/release-2.1.12-stable/libevent-2.1.12-stable.tar.gz
- `vs_toolchain.py` patched: `_CopyDebugger` returns early on Linux (no dbghelp.dll)
- `vs_toolchain.py` patched: `Update()` skips ciopfs FUSE mount (doesn't work in rootless Docker)
- Minimal PE stub DLLs created for `dbgcore.dll`/`dbghelp.dll` (mini_installer archive requirement)
