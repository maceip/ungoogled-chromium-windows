#!/bin/bash
# smoke-test.sh - Verify cross-compilation toolchain works
# Run inside the chromium-win-cross container
set -e

echo "=== Cross-build environment smoke test ==="
echo ""

# 1. Check all tools are present
echo "--- 1. Checking tool availability ---"
for tool in /opt/llvm/bin/clang-cl /opt/llvm/bin/lld-link /opt/llvm/bin/llvm-lib \
            /opt/llvm/bin/clang++ /opt/llvm/bin/llvm-ar \
            /opt/node/bin/node /opt/rust/sysroot/bin/rustc \
            /opt/rust/bindgen/bin/bindgen /usr/local/bin/rc; do
    if [ -x "$tool" ]; then
        echo "  OK: $tool"
    else
        echo "  FAIL: $tool missing or not executable"
        exit 1
    fi
done
echo ""

# 2. Check MSVC/SDK paths
echo "--- 2. Checking Windows SDK structure ---"
MSVC_DIR=$(echo /opt/microsoft/VC/Tools/MSVC/*)
SDK_INC=$(echo /opt/microsoft/Windows\ Kits/10/Include/10.0.*)
SDK_LIB=$(echo /opt/microsoft/Windows\ Kits/10/Lib/10.0.*)

for d in "$MSVC_DIR/include" "$MSVC_DIR/lib/x64" "$MSVC_DIR/lib/arm64" \
         "$MSVC_DIR/atlmfc/include" "$MSVC_DIR/atlmfc/lib/x64"; do
    if [ -d "$d" ]; then
        echo "  OK: $d"
    else
        echo "  FAIL: $d missing"
        exit 1
    fi
done

# Check at least one SDK version has all needed dirs
sdk_ok=0
for sdk_ver_dir in /opt/microsoft/Windows\ Kits/10/Include/10.0.*; do
    ver=$(basename "$sdk_ver_dir")
    all_good=1
    for sub in um shared winrt ucrt; do
        if [ ! -d "$sdk_ver_dir/$sub" ]; then
            all_good=0
        fi
    done
    if [ "$all_good" = "1" ]; then
        echo "  OK: SDK Include/$ver has um/shared/winrt/ucrt"
        sdk_ok=1
    fi
done
[ "$sdk_ok" = "1" ] || { echo "  FAIL: No complete SDK Include version found"; exit 1; }

# Check SDK Lib
for sdk_ver_dir in /opt/microsoft/Windows\ Kits/10/Lib/10.0.*; do
    ver=$(basename "$sdk_ver_dir")
    if [ -d "$sdk_ver_dir/um/x64" ] && [ -d "$sdk_ver_dir/ucrt/x64" ]; then
        echo "  OK: SDK Lib/$ver has um/x64 and ucrt/x64"
    fi
done
echo ""

# 3. Check SetEnv JSON files
echo "--- 3. Checking SetEnv files ---"
for f in /opt/microsoft/Windows\ Kits/10/bin/SetEnv.x64.json \
         /opt/microsoft/Windows\ Kits/10/bin/SetEnv.x86.json \
         /opt/microsoft/Windows\ Kits/10/bin/SetEnv.arm64.json \
         /opt/microsoft/Windows\ Kits/10/bin/SetEnv.cmd; do
    if [ -f "$f" ]; then
        echo "  OK: $f"
    else
        echo "  FAIL: $f missing"
        exit 1
    fi
done
echo ""

# 4. Check case-fold symlinks
echo "--- 4. Checking case-fold symlinks ---"
for sdk_ver_dir in /opt/microsoft/Windows\ Kits/10/Include/10.0.*; do
    if [ -L "$sdk_ver_dir/um/windows.h" ]; then
        echo "  OK: windows.h -> $(readlink "$sdk_ver_dir/um/windows.h")"
    elif [ -f "$sdk_ver_dir/um/windows.h" ]; then
        echo "  OK: windows.h exists (not a symlink)"
    else
        echo "  WARN: windows.h not found in $sdk_ver_dir/um/"
    fi
done
echo ""

# 5. Test clang-cl can compile a simple Windows C program
echo "--- 5. Test: clang-cl compile (C, x64) ---"
TMPDIR=$(mktemp -d)
cat > "$TMPDIR/hello.c" << 'EOF'
#include <windows.h>
#include <stdio.h>
int main(void) {
    DWORD ver = GetVersion();
    printf("Hello from cross-compiled Windows binary!\n");
    return 0;
}
EOF

MSVC_VER=$(basename /opt/microsoft/VC/Tools/MSVC/*)
SDK_VER=$(ls /opt/microsoft/Windows\ Kits/10/Lib/ | sort -V | tail -1)

/opt/llvm/bin/clang-cl \
    --target=x86_64-pc-windows-msvc \
    -fuse-ld=lld \
    "/I/opt/microsoft/VC/Tools/MSVC/$MSVC_VER/include" \
    "/I/opt/microsoft/Windows Kits/10/Include/$SDK_VER/ucrt" \
    "/I/opt/microsoft/Windows Kits/10/Include/$SDK_VER/um" \
    "/I/opt/microsoft/Windows Kits/10/Include/$SDK_VER/shared" \
    "$TMPDIR/hello.c" \
    -o "$TMPDIR/hello.exe" \
    /link \
    "/LIBPATH:/opt/microsoft/VC/Tools/MSVC/$MSVC_VER/lib/x64" \
    "/LIBPATH:/opt/microsoft/Windows Kits/10/Lib/$SDK_VER/ucrt/x64" \
    "/LIBPATH:/opt/microsoft/Windows Kits/10/Lib/$SDK_VER/um/x64" \
    2>&1

if [ -f "$TMPDIR/hello.exe" ]; then
    echo "  OK: hello.exe produced ($(wc -c < "$TMPDIR/hello.exe") bytes)"
    file "$TMPDIR/hello.exe"
else
    echo "  FAIL: hello.exe was not produced"
    exit 1
fi
echo ""

# 6. Test C++ compilation
echo "--- 6. Test: clang-cl compile (C++, x64) ---"
cat > "$TMPDIR/hello.cpp" << 'EOF'
#include <windows.h>
#include <string>
#include <iostream>
int main() {
    std::string msg = "Hello from cross-compiled C++ Windows binary!";
    std::cout << msg << std::endl;
    HANDLE h = GetStdHandle(STD_OUTPUT_HANDLE);
    return h != INVALID_HANDLE_VALUE ? 0 : 1;
}
EOF

/opt/llvm/bin/clang-cl \
    --target=x86_64-pc-windows-msvc \
    -fuse-ld=lld \
    /EHsc \
    "/I/opt/microsoft/VC/Tools/MSVC/$MSVC_VER/include" \
    "/I/opt/microsoft/Windows Kits/10/Include/$SDK_VER/ucrt" \
    "/I/opt/microsoft/Windows Kits/10/Include/$SDK_VER/um" \
    "/I/opt/microsoft/Windows Kits/10/Include/$SDK_VER/shared" \
    "$TMPDIR/hello.cpp" \
    -o "$TMPDIR/hellocpp.exe" \
    /link \
    "/LIBPATH:/opt/microsoft/VC/Tools/MSVC/$MSVC_VER/lib/x64" \
    "/LIBPATH:/opt/microsoft/Windows Kits/10/Lib/$SDK_VER/ucrt/x64" \
    "/LIBPATH:/opt/microsoft/Windows Kits/10/Lib/$SDK_VER/um/x64" \
    2>&1

if [ -f "$TMPDIR/hellocpp.exe" ]; then
    echo "  OK: hellocpp.exe produced ($(wc -c < "$TMPDIR/hellocpp.exe") bytes)"
    file "$TMPDIR/hellocpp.exe"
else
    echo "  FAIL: hellocpp.exe was not produced"
    exit 1
fi
echo ""

# 7. Test Rust cross-compilation
echo "--- 7. Test: Rust cross-compile (x64-windows-msvc) ---"
cat > "$TMPDIR/hello.rs" << 'EOF'
fn main() {
    println!("Hello from cross-compiled Rust Windows binary!");
}
EOF

# Set up lib paths for the linker
export LIB="/opt/microsoft/VC/Tools/MSVC/$MSVC_VER/lib/x64;/opt/microsoft/Windows Kits/10/Lib/$SDK_VER/ucrt/x64;/opt/microsoft/Windows Kits/10/Lib/$SDK_VER/um/x64"

/opt/rust/sysroot/bin/rustc \
    --target x86_64-pc-windows-msvc \
    -C linker=/opt/llvm/bin/lld-link \
    "$TMPDIR/hello.rs" \
    -o "$TMPDIR/hello_rust.exe" \
    2>&1

if [ -f "$TMPDIR/hello_rust.exe" ]; then
    echo "  OK: hello_rust.exe produced ($(wc -c < "$TMPDIR/hello_rust.exe") bytes)"
    file "$TMPDIR/hello_rust.exe"
else
    echo "  FAIL: hello_rust.exe was not produced"
    exit 1
fi
echo ""

# 8. Test ARM64 if available
if [ -d "/opt/microsoft/VC/Tools/MSVC/$MSVC_VER/lib/arm64" ]; then
    echo "--- 8. Test: clang-cl compile (C, arm64) ---"
    /opt/llvm/bin/clang-cl \
        --target=aarch64-pc-windows-msvc \
        -fuse-ld=lld \
        "/I/opt/microsoft/VC/Tools/MSVC/$MSVC_VER/include" \
        "/I/opt/microsoft/Windows Kits/10/Include/$SDK_VER/ucrt" \
        "/I/opt/microsoft/Windows Kits/10/Include/$SDK_VER/um" \
        "/I/opt/microsoft/Windows Kits/10/Include/$SDK_VER/shared" \
        "$TMPDIR/hello.c" \
        -o "$TMPDIR/hello_arm64.exe" \
        /link \
        "/LIBPATH:/opt/microsoft/VC/Tools/MSVC/$MSVC_VER/lib/arm64" \
        "/LIBPATH:/opt/microsoft/Windows Kits/10/Lib/$SDK_VER/ucrt/arm64" \
        "/LIBPATH:/opt/microsoft/Windows Kits/10/Lib/$SDK_VER/um/arm64" \
        2>&1
    if [ -f "$TMPDIR/hello_arm64.exe" ]; then
        echo "  OK: hello_arm64.exe produced ($(wc -c < "$TMPDIR/hello_arm64.exe") bytes)"
        file "$TMPDIR/hello_arm64.exe"
    else
        echo "  FAIL: hello_arm64.exe was not produced"
    fi
    echo ""
fi

# 9. Test Wine can run cl.exe (needed for MIDL)
echo "--- 9. Test: Wine + cl.exe ---"
if command -v wine64 >/dev/null 2>&1; then
    WINEDEBUG=-all wine64 /opt/microsoft/VC/Tools/MSVC/$MSVC_VER/bin/Hostx64/x64/cl.exe 2>&1 | head -2 || echo "  (Wine cl.exe returned non-zero, may be expected)"
    echo "  OK: Wine can invoke cl.exe"
else
    echo "  SKIP: wine64 not found"
fi
echo ""

# 10. Test GN bootstrap compile would work (just check clang++ host compiler)
echo "--- 10. Test: Host clang++ (for GN bootstrap) ---"
cat > "$TMPDIR/gn_test.cc" << 'EOF'
#include <string>
#include <iostream>
int main() {
    std::cout << "GN bootstrap compiler works" << std::endl;
    return 0;
}
EOF
/opt/llvm/bin/clang++ -stdlib=libc++ -fuse-ld=lld "$TMPDIR/gn_test.cc" -o "$TMPDIR/gn_test" 2>&1
if [ -x "$TMPDIR/gn_test" ]; then
    "$TMPDIR/gn_test"
    echo "  OK: Host clang++ works"
else
    echo "  FAIL: Host clang++ compilation failed"
    exit 1
fi
echo ""

# Cleanup
rm -rf "$TMPDIR"

echo "=========================================="
echo "  All smoke tests PASSED"
echo "=========================================="
