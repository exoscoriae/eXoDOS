#!/bin/bash
# Verify a bundle is truly portable for macOS 11+:
#   1. every Mach-O is universal (x86_64 + arm64)
#   2. every slice has minos <= 11.0
#   3. no dylib dependencies outside /usr/lib and /System/Library
# Usage: ./verify-bundle.sh <path/to/App.app>
set -euo pipefail

APP=${1:?usage: verify-bundle.sh <App.app>}
FAIL=0
FOUND=0

check_minos() { # $1=file $2=arch
    local out minos major minor rest
    out=$(otool -arch "$2" -l "$1" 2>/dev/null || true)
    # Modern binaries: LC_BUILD_VERSION "minos"; older: LC_VERSION_MIN_MACOSX "version"
    minos=$(echo "$out" | awk '/minos /{print $2; exit}')
    [ -z "$minos" ] && minos=$(echo "$out" | awk '/LC_VERSION_MIN_MACOSX/{f=1} f&&/version /{print $2; exit}')
    if [ -z "$minos" ]; then
        echo "FAIL: $1 [$2]: cannot determine minos"; FAIL=1; return
    fi
    major=${minos%%.*}
    rest=${minos#*.}; minor=${rest%%.*}; [ "$rest" = "$minos" ] && minor=0
    if [ "$major" -gt 11 ] || { [ "$major" -eq 11 ] && [ "${minor:-0}" -gt 0 ]; }; then
        echo "FAIL: $1 [$2]: requires macOS $minos (> 11.0)"; FAIL=1
    else
        echo "  ok: $(basename "$1") [$2] minos $minos"
    fi
}

while IFS= read -r -d '' f; do
    file -b "$f" | grep -q "Mach-O" || continue
    FOUND=1
    archs=$(lipo -archs "$f" 2>/dev/null || echo "")
    case "$archs" in
        *x86_64*arm64*|*arm64*x86_64*) ;;
        *) echo "FAIL: $f is not universal (archs: $archs)"; FAIL=1; continue ;;
    esac
    check_minos "$f" x86_64
    check_minos "$f" arm64
    # External linkage must be system-only (skip first line = file name)
    while IFS= read -r d; do
        case "$d" in
            ""|/usr/lib/*|/System/Library/*) ;;
            *) echo "FAIL: $f links non-system library: $d"; FAIL=1 ;;
        esac
    done < <(otool -arch arm64 -L "$f" | tail -n +2 | awk '{print $1}')
done < <(find "$APP" -type f -print0)

if [ "$FOUND" -eq 0 ]; then
    echo "FAIL: no Mach-O files found in $APP"; exit 1
fi
if [ "$FAIL" -ne 0 ]; then
    echo "VERIFICATION FAILED for $APP"
    exit 1
fi
echo "VERIFIED: $APP is universal, macOS 11.0-compatible, and self-contained."
