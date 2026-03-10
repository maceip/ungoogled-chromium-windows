# Sovereignty/Tor/IPFS Cross-Build Guide

Lessons learned from cross-compiling Chromium for Windows (x64) and Android (arm64) with custom Sovereignty, Tor, and IPFS features from a Linux Docker container.

## Golden Rules

### 1. ALL build operations go through Docker

```bash
# CORRECT — always use docker exec
docker exec win-build bash -c 'cd /build/chromium/src && third_party/siso/cipd/siso ninja --offline -C out/win-component -local_jobs=12 chrome chromedriver mini_installer'

# NEVER do this — breaks permissions, invalidates caches, costs a full day
sudo chown -R ...
autoninja -C /home/devuser/chromium-win-build/chromium/src/out/win-component chrome
```

Running `chown`, `autoninja`, `gn gen`, or `ninja` directly on the host outside Docker will:
- Break file ownership (container user UID 1024 / host UID 166559)
- Invalidate siso's mtime-based cache, forcing a full rebuild (6+ hours)
- Corrupt the build state requiring `gn clean`

### 2. Never run `gn gen` manually

Siso/ninja auto-regenerates build files when `BUILD.gn` or `args.gn` changes. Running `gn gen` manually invalidates the entire siso cache.

### 3. Use `touch` to force incremental rebuilds

When you edit source files that siso doesn't detect as dirty (because outputs are newer), touch them:

```bash
docker exec win-build bash -c 'touch /build/chromium/src/path/to/edited/file.ts'
```

Siso uses mtime-based manifest hashing: it re-runs a step when inputs are newer than outputs OR when the command line / input list changes.

## Build Commands

### Windows (x64, component build)
```bash
docker exec win-build bash -c 'cd /build/chromium/src && third_party/siso/cipd/siso ninja --offline -C out/win-component -local_jobs=12 chrome chromedriver mini_installer'
```

### Android (arm64, static build)
```bash
docker exec win-build bash -c 'cd /build/chromium/src && third_party/siso/cipd/siso ninja --offline -C out/android-arm64 -local_jobs=12 chrome_public_apk'
```

### Sign Android APK (post-build)
```bash
docker exec win-build bash -c '/build/chromium/src/third_party/android_sdk/public/build-tools/36.0.0/apksigner sign --ks /build/chromium/src/build/android/chromium-debug.keystore --ks-pass pass:chromium --out /build/chromium/src/out/android-arm64/apks/ChromePublic-signed.apk /build/chromium/src/out/android-arm64/apks/ChromePublic.apk'
```

## Build Configurations

### Windows (`out/win-component/args.gn`)
```
target_os = "win"
target_cpu = "x64"
is_component_build = true
is_debug = false
is_official_build = false
is_clang = true
use_lld = true
treat_warnings_as_errors = false
enable_rust = true
use_siso = true
use_sysroot = false
chrome_pgo_phase = 0
enable_nacl = false
dcheck_always_on = false
symbol_level = 0
blink_symbol_level = 0
v8_symbol_level = 0
enable_ipfs = true
```

### Android (`out/android-arm64/args.gn`)
```
target_os = "android"
target_cpu = "arm64"
is_debug = false
is_official_build = false
is_component_build = false
is_clang = true
use_lld = true
treat_warnings_as_errors = false
enable_rust = true
use_siso = true
chrome_pgo_phase = 0
enable_nacl = false
dcheck_always_on = false
symbol_level = 0
blink_symbol_level = 0
v8_symbol_level = 0
enable_ipfs = true
android_static_analysis = "off"
```

## Sovereignty Feature: File Registration Checklist

`enable_ipfs = true` pulls in `//components/ipfs`, `//components/tor`, and `//components/sovereignty`.

### Desktop (Windows) — Settings UI

| What | Where | Notes |
|------|-------|-------|
| TypeScript files | `chrome/browser/resources/settings/BUILD.gn` | Must list all `.ts` files including `*_page_index.ts` |
| i18n string IDs | `chrome/app/settings_strings.grdp` | Every `$i18n{key}` in HTML needs `IDS_SETTINGS_*` |
| i18n registration | `chrome/browser/ui/webui/settings/settings_localized_strings_provider.cc` | `AddLocalizedString` for each key |
| Page visibility | `chrome/browser/resources/settings/page_visibility.ts` | Add `sovereignty?: boolean` to interface |
| Routes | `chrome/browser/resources/settings/route.ts` | `createSection` + `createChild` for subpages |
| Main page entry | `chrome/browser/resources/settings/settings_main/settings_main.html` | Use `*-page-index` wrapper, not the page directly |
| Main page import | `chrome/browser/resources/settings/settings_main/settings_main.ts` | Import the `*_page_index.js` |
| Menu entry | `chrome/browser/resources/settings/settings_menu/settings_menu.html` | Link with icon and `$i18n{}` label |
| Icon definition | `chrome/browser/resources/settings/icons.html` | SVG path in `<iron-iconset-svg>` |

### Desktop — Subpage Pattern

Pages with child routes MUST use an index wrapper:
- `sovereignty_page_index.html` — `<cr-view-manager>` with main page + subpages as `slot="view"`
- `sovereignty_page_index.ts` — `RouteObserverMixin` + `SearchableViewContainerMixin`, switches views on route change
- `settings_main.html` references `<settings-sovereignty-page-index>`, NOT `<settings-sovereignty-page>`

### Desktop — TypeScript Rules

- Index signature properties require bracket notation: `this.prefs?.["sovereignty"]?.["log"]` (TS4111)
- Methods overriding base class/mixin methods need `override` keyword (TS4114)
- `async` methods must contain at least one `await` (ESLint `@typescript-eslint/require-await`)
- Polymer's `this.set('prefs.sovereignty.log.value', [])` uses string paths — no bracket notation needed

### Android — Settings UI

| What | Where | Notes |
|------|-------|-------|
| XML preferences | `chrome/android/java/res/xml/sovereignty_*.xml` | PreferenceScreen definitions |
| String resources | `chrome/android/java/res/values/strings_sovereignty.xml` | All `@string/*` references |
| Resource list | `chrome/android/chrome_java_resources.gni` | Must list every XML file — NOT auto-discovered |
| Java sources | `chrome/android/chrome_java_sources.gni` | Must list every `.java` file — NOT auto-discovered |
| Main settings entry | `chrome/android/java/res/xml/main_preferences.xml` | `<Preference android:fragment="...">` |

### Android — Java Fragment Rules

Fragments extending `ChromeBaseSettingsFragment` MUST implement:
- `getPageTitle()` — returns `ObservableSupplier<String>`
- `getAnimationType()` — returns `AnimationType.PROPERTY`
- `onCreatePreferences()` — loads XML and sets title

```java
import org.chromium.components.browser_ui.settings.SettingsFragment.AnimationType;

@Override
public @AnimationType int getAnimationType() {
    return AnimationType.PROPERTY;
}
```

### C++ Components

| What | Where |
|------|-------|
| Sovereignty component | `components/sovereignty/BUILD.gn` |
| Tor component | `components/tor/BUILD.gn` (depends on sovereignty) |
| IPFS component | `components/ipfs/BUILD.gn` (depends on tor) |
| Pref registration | `chrome/browser/prefs/browser_prefs.cc` |
| OnionInterceptor | `chrome/browser/chrome_content_browser_client.cc` |
| Browser deps | `chrome/browser/BUILD.gn` (under `enable_ipfs` conditional) |

## Pre-Build Verification Checklist

Before kicking off a build, verify:

1. **i18n completeness**: Every `$i18n{key}` has a matching `IDS_SETTINGS_*` in `.grdp` AND is registered in `settings_localized_strings_provider.cc`
2. **Java abstract methods**: Every `ChromeBaseSettingsFragment` subclass implements `getAnimationType()` and `getPageTitle()`
3. **TypeScript overrides**: Methods from mixins have `override` keyword
4. **ESLint**: No `async` without `await`
5. **Index wrapper**: Settings pages with subpages use `*_page_index` pattern
6. **Android registration**: All XML and Java files listed in `.gni` files
7. **Files touched**: All edited files have mtimes newer than build outputs

## Output Artifacts

- **Windows installer**: `out/win-component/mini_installer.exe`
- **Android APK**: `out/android-arm64/apks/ChromePublic.apk`
- **Android signed APK**: `out/android-arm64/apks/ChromePublic-signed.apk` (post-build signing step)

## Siso Notes

- Siso is Chromium's build system (replaces ninja). Uses mtime-based manifest hashing.
- `--offline` flag required in our container (no remote execution).
- `-local_jobs=12` matches our core allocation per build.
- Siso buffers stdout until build completion — use `siso.INFO` log for live progress.
- Switching between siso and ninja requires `gn clean` (full wipe).
- `siso_failed_commands.sh` in the output dir re-runs failed steps for debugging.
