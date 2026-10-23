#!/usr/bin/env bash
# build_all_gridc_gunstick.sh — Build DOSBox GridC (GC-v4.3.1) and DOSBox
# Gunstick (0.74-3 + lightgun) as universal (arm64 + x86_64) binaries
# targeting macOS 11.0, on a CURRENT macOS host (no VM needed).
#
# No Homebrew. No MacPorts. Build tools come from ./tools-prefix and
# libraries from ./deps-prefix; both are created automatically if missing.
#
# Usage:
#   ./build_all_gridc_gunstick.sh             # both forks
#   ./build_all_gridc_gunstick.sh gridc       # just GridC
#   ./build_all_gridc_gunstick.sh gunstick    # just Gunstick
#
# Apple Silicon dynamic core:
#   * GridC is SVN r4300 (same vintage as ECE) — the proven ECE treatment
#     applies: arm64 host detection, W^X/MAP_JIT/16K-page cache patches,
#     per-arch override in include/dosbox.h.
#   * Gunstick is DOSBox 0.74-3, which PREDATES the ARMv8 dynrec backend —
#     risc_armv8le.h is grafted in from the GridC/ECE sources (interface
#     verified identical), then the same W^X treatment is applied.
#   * Both: BOTH slices use core_dynrec (risc_x64 / risc_armv8le) — these
#     bases' core_dyn_x86 is 32-bit-only, unlike ECE's.
#
# Also fixes the Gunstick fullscreen lightgun bug (letterbox offsets).
#
# Compatible with the stock /bin/bash 3.2 on macOS.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPS_PREFIX="${DEPS_PREFIX:-$SCRIPT_DIR/deps-prefix}"
TOOLS_PREFIX="${TOOLS_PREFIX:-$SCRIPT_DIR/tools-prefix}"
NPROC=$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)

MACOS_MIN=11.0

SOURCE_BASE="https://github.com/jonesaaronj/exo_flatpaks/releases/download/source_bundles"
GRIDC_TARBALL="dosbox-gridc-GC-v4.3.1.tar.gz"
GUNSTICK_TARBALL="dosbox-gunstick.tar.gz"
GRIDC_DIR="$SCRIPT_DIR/dosbox-gridc-4-3-1"
GUNSTICK_DIR="$SCRIPT_DIR/dosbox-gunstick"

# ── Helpers ───────────────────────────────────────────────────────────────────

msg()  { printf "\033[36m[build]\033[0m %s\n" "$*"; }
ok()   { printf "\033[32m[ ok  ]\033[0m %s\n" "$*"; }
warn() { printf "\033[33m[warn ]\033[0m %s\n" "$*" >&2; }
die()  { printf "\033[31m[err  ]\033[0m %s\n" "$*" >&2; exit 1; }

# ── Prerequisite check ────────────────────────────────────────────────────────

xcode-select -p >/dev/null 2>&1 \
    || die "Xcode Command Line Tools not installed. Run: xcode-select --install"

for tool in tar make python3 codesign hdiutil curl lipo nm; do
    command -v "$tool" >/dev/null 2>&1 || die "Missing required tool: $tool"
done

for f in fix_gridc_build.py fix_gunstick_build.py dynrec_apple_silicon.py; do
    [ -f "$SCRIPT_DIR/$f" ] || die "$f not found in $SCRIPT_DIR"
done

# ── Ensure build tools + dependency prefix exist ─────────────────────────────

if [ ! -x "$TOOLS_PREFIX/bin/cmake" ] || [ ! -x "$TOOLS_PREFIX/bin/autoconf" ]; then
    msg "Build tools missing — running bootstrap_tools.sh (first run: 20-40 min)..."
    [ -x "$SCRIPT_DIR/bootstrap_tools.sh" ] || die "bootstrap_tools.sh not found"
    TOOLS_PREFIX="$TOOLS_PREFIX" "$SCRIPT_DIR/bootstrap_tools.sh"
fi

[ -x "$SCRIPT_DIR/build_deps.sh" ] || die "build_deps.sh not found or not executable"
msg "Ensuring dependency libraries are complete (stamps make this fast)..."
DEPS_PREFIX="$DEPS_PREFIX" TOOLS_PREFIX="$TOOLS_PREFIX" "$SCRIPT_DIR/build_deps.sh" \
    || die "build_deps.sh failed — fix the reported dependency and re-run."

# SDL_sound (compressed CD-audio images) is an extra; build it only if the
# stamp is missing (passing the name to build_deps.sh forces a rebuild).
if ! ls "$DEPS_PREFIX"/lib/libSDL_sound*.dylib >/dev/null 2>&1; then
    msg "SDL_sound missing — building it..."
    DEPS_PREFIX="$DEPS_PREFIX" TOOLS_PREFIX="$TOOLS_PREFIX" \
        "$SCRIPT_DIR/build_deps.sh" sdl-sound \
        || die "build_deps.sh sdl-sound failed."
fi

[ -x "$DEPS_PREFIX/bin/sdl-config" ] \
    || die "deps-prefix is incomplete: bin/sdl-config missing (sdl12-compat). Run ./build_deps.sh"

# ── Fully isolated build environment ─────────────────────────────────────────

export MACOSX_DEPLOYMENT_TARGET="${MACOS_MIN}"
export DEPS_PREFIX

unset PKG_CONFIG_PATH
export PKG_CONFIG_LIBDIR="${DEPS_PREFIX}/lib/pkgconfig:${DEPS_PREFIX}/share/pkgconfig"
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH OBJCPLUS_INCLUDE_PATH
unset LIBRARY_PATH DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH
unset CMAKE_PREFIX_PATH CMAKE_FRAMEWORK_PATH

export CC="$(xcrun -f clang 2>/dev/null || echo /usr/bin/clang)"
export CXX="$(xcrun -f clang++ 2>/dev/null || echo /usr/bin/clang++)"

_xcode_bin="$(dirname "$(xcrun -f clang 2>/dev/null || echo /usr/bin/clang)")"
export PATH="${TOOLS_PREFIX}/bin:${DEPS_PREFIX}/bin:${_xcode_bin}:/usr/bin:/bin:/usr/sbin:/sbin"

export DYLD_FALLBACK_LIBRARY_PATH="${DEPS_PREFIX}/lib"

if [ -z "${SDKROOT:-}" ]; then
    SDKROOT_VAL="$(xcrun --show-sdk-path 2>/dev/null || true)"
    [ -n "$SDKROOT_VAL" ] && export SDKROOT="$SDKROOT_VAL"
fi

# ── risc_armv8le.h source for the Gunstick graft ─────────────────────────────

find_armv8_backend() {
    # Prefer the freshly extracted GridC tree, then any extracted ECE tree,
    # then extract straight out of an ECE source tarball.
    local cand
    for cand in \
        "$GRIDC_DIR/src/cpu/core_dynrec/risc_armv8le.h" \
        "$SCRIPT_DIR"/ece-r4301/src/cpu/core_dynrec/risc_armv8le.h \
        "$SCRIPT_DIR"/ece-r4358/src/cpu/core_dynrec/risc_armv8le.h; do
        if [ -f "$cand" ]; then
            echo "$cand"
            return 0
        fi
    done
    local tb
    for tb in "$SCRIPT_DIR"/ece-r4301-source.tar.gz "$SCRIPT_DIR"/ece-r4358-source.tar.gz; do
        if [ -f "$tb" ]; then
            local out="$SCRIPT_DIR/.risc_armv8le.h.extracted"
            if tar -xzf "$tb" -O '*/src/cpu/core_dynrec/risc_armv8le.h' > "$out" 2>/dev/null \
               && [ -s "$out" ]; then
                echo "$out"
                return 0
            fi
            rm -f "$out"
        fi
    done
    return 1
}

# ── Verification helpers ─────────────────────────────────────────────────────

verify_patches_applied() {
    local dir="$1" kind="$2" bad=0

    grep -q 'per-architecture dynamic core selection' "$dir/include/dosbox.h" 2>/dev/null \
        || { warn "include/dosbox.h is missing the per-arch dynamic core override"; bad=1; }
    grep -q 'MAP_PRIVATE|MAP_ANON|MAP_JIT' "$dir/src/cpu/core_dynrec/cache.h" 2>/dev/null \
        || { warn "cache.h is missing the MAP_JIT allocation patch"; bad=1; }
    grep -q 'PAGESIZE_TEMP 16384' "$dir/src/cpu/core_dynrec/cache.h" 2>/dev/null \
        || { warn "cache.h is missing the 16 KiB page-size patch"; bad=1; }
    grep -q 'cache_jit_writable' "$dir/src/cpu/core_dynrec.cpp" 2>/dev/null \
        || { warn "core_dynrec.cpp is missing the W^X toggle patch"; bad=1; }

    if [ "$kind" = "gunstick" ]; then
        [ -f "$dir/src/cpu/core_dynrec/risc_armv8le.h" ] \
            || { warn "risc_armv8le.h graft is missing"; bad=1; }
        grep -q 'C_TARGETCPU == ARMV8LE' "$dir/src/cpu/core_dynrec.cpp" 2>/dev/null \
            || { warn "core_dynrec.cpp is missing the ARMv8 backend registration"; bad=1; }
        grep -q 'GunStick(motion->x - sdl.clip.x' "$dir/src/gui/sdlmain.cpp" 2>/dev/null \
            || { warn "sdlmain.cpp is missing the fullscreen lightgun fix"; bad=1; }
    fi

    [ $bad -eq 0 ] || die "Patches incomplete in $(basename "$dir") — aborting."
    ok "patches verified in source tree"
}

dump_core_defines() {
    local dir="$1" td out a
    td="$(mktemp -d)" || return 0
    printf '#include "dosbox.h"\nprobe dynrec=[C_DYNREC] dynx86=[C_DYNAMIC_X86] targetcpu=[C_TARGETCPU]\n' \
        > "$td/probe.c"
    for a in arm64 x86_64; do
        out="$("$CC" -arch "$a" -E -I"$dir" -I"$dir/include" "$td/probe.c" 2>/dev/null \
               | grep '^probe' | tail -1 || true)"
        msg "  preprocessor view ($a): ${out:-<probe failed>}"
    done
    rm -rf "$td"
}

verify_binary() {
    # NOTE: no `grep -q` on pipes — under pipefail, grep -q exits at the first
    # match and kills nm with SIGPIPE, turning success into failure.
    local bin="$1" bad=0

    lipo -archs "$bin" 2>/dev/null | grep 'arm64' >/dev/null \
        || { warn "binary is missing the arm64 slice"; bad=1; }
    lipo -archs "$bin" 2>/dev/null | grep 'x86_64' >/dev/null \
        || { warn "binary is missing the x86_64 slice"; bad=1; }

    # BOTH slices use core_dynrec here (risc_armv8le on arm64, risc_x64 on
    # x86_64): these bases' core_dyn_x86 is 32-bit-only (unlike ECE).
    local a
    for a in arm64 x86_64; do
        if nm -arch "$a" "$bin" 2>/dev/null | grep 'CPU_Core_Dynrec_Run' >/dev/null; then
            ok "$a slice: dynrec core present (CPU_Core_Dynrec_Run)"
        else
            warn "$a slice does NOT contain the dynrec core!"
            bad=1
        fi
    done

    local minos
    minos="$(otool -l "$bin" 2>/dev/null | awk '/minos/ {print $2}' | sort -u | tr '\n' ' ')"
    msg "minos of slices: ${minos:-unknown}"

    return $bad
}

# ── Which forks to build ─────────────────────────────────────────────────────

WANT_GRIDC=1
WANT_GUNSTICK=1
if [ $# -ge 1 ]; then
    WANT_GRIDC=0
    WANT_GUNSTICK=0
    for a in "$@"; do
        case "$a" in
            gridc)    WANT_GRIDC=1 ;;
            gunstick) WANT_GUNSTICK=1 ;;
            *) die "Unknown fork: $a (expected: gridc, gunstick)" ;;
        esac
    done
fi

# ── Download missing source tarballs ─────────────────────────────────────────

for t in $GRIDC_TARBALL $GUNSTICK_TARBALL; do
    if [ ! -f "$SCRIPT_DIR/$t" ]; then
        msg "downloading $t ..."
        curl -fL --retry 3 "$SOURCE_BASE/$t" -o "$SCRIPT_DIR/$t.tmp" \
            && mv "$SCRIPT_DIR/$t.tmp" "$SCRIPT_DIR/$t" \
            || { rm -f "$SCRIPT_DIR/$t.tmp"; die "could not download $t"; }
    fi
done

BUILT=""
FAILED=""

build_fork() {
    # $1 = dir  $2 = tarball  $3 = fix script  $4 = kind (gridc|gunstick)
    local dir="$1" tarball="$2" fixscript="$3" kind="$4"
    echo
    msg "=== Processing $(basename "$dir") ==="

    msg "extracting into $(basename "$dir") (clean)..."
    rm -rf "$dir"
    mkdir -p "$dir"
    tar --strip-components=1 -xzf "$SCRIPT_DIR/$tarball" -C "$dir"

    if [ "$kind" = "gunstick" ]; then
        msg "grafting risc_armv8le.h (0.74-3 predates the ARMv8 backend)..."
        local armv8
        armv8="$(find_armv8_backend)" \
            || die "risc_armv8le.h not found — build gridc first, or place an ece-r4301-source.tar.gz here."
        cp "$armv8" "$dir/src/cpu/core_dynrec/risc_armv8le.h"
        ok "risc_armv8le.h <- $armv8"
    fi

    cp "$SCRIPT_DIR/$fixscript" "$SCRIPT_DIR/dynrec_apple_silicon.py" "$dir/"
    msg "applying macOS patches and running configure..."
    cd "$dir"
    if ! DEPS_PREFIX="$DEPS_PREFIX" UNIVERSAL=1 python3 "$fixscript"; then
        warn "patch/configure FAILED: $(basename "$dir")"
        FAILED="$FAILED $(basename "$dir")"
        cd "$SCRIPT_DIR"
        return
    fi

    verify_patches_applied "$dir" "$kind"

    msg "building (-j$NPROC, universal, macOS-min=${MACOS_MIN})..."
    if make -j"$NPROC"; then
        if [ -x "$dir/src/dosbox" ]; then
            if verify_binary "$dir/src/dosbox"; then
                ok "built + verified: $(basename "$dir")"
                BUILT="$BUILT $dir"
            else
                warn "verification FAILED for $(basename "$dir") — see warnings above"
                dump_core_defines "$dir"
                FAILED="$FAILED $(basename "$dir")(verify)"
            fi
        else
            warn "make succeeded but src/dosbox is missing?!"
            FAILED="$FAILED $(basename "$dir")"
        fi
    else
        warn "build FAILED: $(basename "$dir")"
        FAILED="$FAILED $(basename "$dir")"
    fi
    cd "$SCRIPT_DIR"
}

# GridC first: it donates risc_armv8le.h to the Gunstick graft.
[ "$WANT_GRIDC" = "1" ]    && build_fork "$GRIDC_DIR"    "$GRIDC_TARBALL"    fix_gridc_build.py    gridc
[ "$WANT_GUNSTICK" = "1" ] && build_fork "$GUNSTICK_DIR" "$GUNSTICK_TARBALL" fix_gunstick_build.py gunstick

# ── Summary ──────────────────────────────────────────────────────────────────

echo
msg "=== Summary ==="
for d in $BUILT; do
    ok "✓ $(basename "$d")  →  $(basename "$d")/src/dosbox"
done
for n in $FAILED; do
    warn "✗ $n  →  FAILED"
done

if [ -n "$BUILT" ]; then
    echo
    msg "To package each fork as a portable .app + DMG:"
    for d in $BUILT; do
        printf "    ./package_fork_macos.sh %s\n" "$(basename "$d")"
    done
fi
echo
[ -z "$FAILED" ] || exit 1
