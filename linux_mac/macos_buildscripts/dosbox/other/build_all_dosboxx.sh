#!/usr/bin/env bash
# build_all_dosboxx.sh — Build DOSBox-X v2024.07.01 / v2024.10.01 /
# v2025.02.01 / v2025.05.03 as universal (arm64 + x86_64) binaries targeting
# macOS 11.0, on a CURRENT macOS host (no VM needed).
#
# No Homebrew. No MacPorts. Build tools come from ./tools-prefix
# (bootstrap_tools.sh) and libraries from ./deps-prefix (build_deps.sh --all,
# which adds the DOSBox-X extras: SDL2_net, libslirp, freetype, ffmpeg);
# both are created automatically if missing.
#
# Usage:
#   ./build_all_dosboxx.sh                 # all four versions
#   ./build_all_dosboxx.sh v2025.05.03     # specific version(s)
#
# Dynamic core on Apple Silicon: every one of these DOSBox-X versions ships
# a W^X-safe dyncore allocator (Darwin mach_vm_remap dual-mapping), so no
# cache patching is needed. fix_dosbox_x_build.py injects a per-architecture
# override so the shared config of the universal build enables dynrec with
# the right backend for each slice (risc_x64 / risc_armv8le) and the Darwin
# dual-map path is always compiled in.
#
# Compatible with the stock /bin/bash 3.2 on macOS.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPS_PREFIX="${DEPS_PREFIX:-$SCRIPT_DIR/deps-prefix}"
TOOLS_PREFIX="${TOOLS_PREFIX:-$SCRIPT_DIR/tools-prefix}"
NPROC=$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)

MACOS_MIN=11.0
UARCH="-arch arm64 -arch x86_64"
UVER="-mmacosx-version-min=${MACOS_MIN}"

DOSBOXX_VERSIONS="v2024.07.01 v2024.10.01 v2025.02.01 v2025.05.03"
DOSBOXX_TAG_BASE="https://github.com/joncampbell123/dosbox-x/archive/refs/tags"

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

[ -f "$SCRIPT_DIR/fix_dosbox_x_build.py" ] \
    || die "fix_dosbox_x_build.py not found in $SCRIPT_DIR"

# ── Ensure build tools + dependency prefix exist ─────────────────────────────

if [ ! -x "$TOOLS_PREFIX/bin/cmake" ] || [ ! -x "$TOOLS_PREFIX/bin/autoconf" ]; then
    msg "Build tools missing — running bootstrap_tools.sh (first run: 20-40 min)..."
    [ -x "$SCRIPT_DIR/bootstrap_tools.sh" ] || die "bootstrap_tools.sh not found"
    TOOLS_PREFIX="$TOOLS_PREFIX" "$SCRIPT_DIR/bootstrap_tools.sh"
fi

# ALWAYS run build_deps.sh --all — stamp-based, so a complete prefix costs
# seconds while a partial one resumes where it stopped. --all adds the
# DOSBox-X extras (sdl2-net, libslirp, freetype, ffmpeg) on top of the ECE
# set (shared zlib/libpng/SDL2/fluidsynth/mt32emu/...).
[ -x "$SCRIPT_DIR/build_deps.sh" ] || die "build_deps.sh not found or not executable"
msg "Ensuring dependency libraries are complete (stamps make this fast)..."
DEPS_PREFIX="$DEPS_PREFIX" TOOLS_PREFIX="$TOOLS_PREFIX" "$SCRIPT_DIR/build_deps.sh" --all \
    || die "build_deps.sh --all failed — fix the reported dependency and re-run."

# Sanity: the libraries the DOSBox-X configure step depends on most.
ls "$DEPS_PREFIX/lib/libSDL2"*.dylib >/dev/null 2>&1 \
    || die "deps-prefix is incomplete: libSDL2 missing. Run ./build_deps.sh --all"
ls "$DEPS_PREFIX"/lib/libSDL2_net*.dylib >/dev/null 2>&1 \
    || die "deps-prefix is incomplete: libSDL2_net missing. Run ./build_deps.sh --all"

# ── Fully isolated build environment ─────────────────────────────────────────
# PATH contains ONLY: our tools prefix, our deps prefix, Xcode, and the base
# system. /usr/local, /opt/local, /opt/homebrew never appear.

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

COMPAT_CFLAGS="-Wno-error=implicit-function-declaration -Wno-implicit-function-declaration -Wno-implicit-int"

export CPPFLAGS="-I${DEPS_PREFIX}/include ${UVER}"
export CFLAGS="${UARCH} ${UVER} -O2 ${COMPAT_CFLAGS} -I${DEPS_PREFIX}/include"
export CXXFLAGS="${UARCH} ${UVER} -O2 -I${DEPS_PREFIX}/include"
export OBJCFLAGS="${CFLAGS}"
export OBJCXXFLAGS="${CXXFLAGS}"
export LDFLAGS="${UARCH} ${UVER} -L${DEPS_PREFIX}/lib -Wl,-rpath,${DEPS_PREFIX}/lib -Wl,-rpath,@executable_path/../Frameworks"
export DYLD_FALLBACK_LIBRARY_PATH="${DEPS_PREFIX}/lib"

if [ -z "${SDKROOT:-}" ]; then
    SDKROOT_VAL="$(xcrun --show-sdk-path 2>/dev/null || true)"
    [ -n "$SDKROOT_VAL" ] && export SDKROOT="$SDKROOT_VAL"
fi

# ── Verification helpers ─────────────────────────────────────────────────────

verify_patches_applied() {
    local dir="$1" bad=0

    # Primary override lives in include/dosbox.h; config.h carries a copy.
    if ! grep -q 'per-architecture dynamic core selection' "$dir/include/dosbox.h" 2>/dev/null \
       && ! grep -q 'per-architecture dynamic core selection' "$dir/config.h" 2>/dev/null; then
        warn "per-arch dynamic core override missing from dosbox.h AND config.h"
        bad=1
    fi
    # The Darwin dual-mapping allocator must exist in this source.
    [ -f "$dir/src/cpu/dynamic_alloc_common.h" ] \
        || { warn "src/cpu/dynamic_alloc_common.h missing — unexpected DOSBox-X layout"; bad=1; }
    grep -q 'mach_vm_remap' "$dir/src/cpu/dynamic_alloc_common.h" 2>/dev/null \
        || { warn "dyncore allocator lacks the Darwin mach_vm_remap path"; bad=1; }

    [ $bad -eq 0 ] || die "Dynamic-core preparation incomplete in $(basename "$dir") — aborting."
    ok "dynamic-core override + Darwin dual-map allocator verified"
}

dump_core_defines() {
    # Diagnostic on verify failure: what each slice's preprocessor sees.
    local dir="$1" td out a
    td="$(mktemp -d)" || return 0
    printf '#include "dosbox.h"\nprobe dynrec=[C_DYNREC] dynx86=[C_DYNAMIC_X86] targetcpu=[C_TARGETCPU] machremap=[C_HAVE_MACH_VM_REMAP]\n' \
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

    # Both slices use dynrec (risc_armv8le on arm64, risc_x64 on x86_64).
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

# ── Main loop ────────────────────────────────────────────────────────────────

if [ $# -ge 1 ]; then
    VERSIONS="$*"
else
    VERSIONS="$DOSBOXX_VERSIONS"
fi

# Download missing source tarballs (GitHub tag archives).
for v in $VERSIONS; do
    t="$SCRIPT_DIR/dosbox-x-${v}.tar.gz"
    if [ ! -f "$t" ]; then
        msg "downloading dosbox-x-${v}.tar.gz ..."
        curl -fL --retry 3 "$DOSBOXX_TAG_BASE/dosbox-x-${v}.tar.gz" -o "$t.tmp" \
            && mv "$t.tmp" "$t" \
            || { rm -f "$t.tmp"; die "could not download dosbox-x ${v} source"; }
    fi
done

BUILT=""
FAILED=""

for v in $VERSIONS; do
    tarball="$SCRIPT_DIR/dosbox-x-${v}.tar.gz"
    dir="$SCRIPT_DIR/dosbox-x-${v}"
    echo
    msg "=== Processing dosbox-x-${v} ==="

    # ── Clean extract (GitHub archive top dir is dosbox-x-dosbox-x-vX.Y.Z) ──
    msg "extracting into $(basename "$dir") (clean)..."
    rm -rf "$dir"
    mkdir -p "$dir"
    tar --strip-components=1 -xzf "$tarball" -C "$dir"

    # ── Patch + autogen + configure ──────────────────────────────────────────
    cp "$SCRIPT_DIR/fix_dosbox_x_build.py" "$dir/"
    msg "applying macOS patches and running configure..."
    cd "$dir"
    if ! DEPS_PREFIX="$DEPS_PREFIX" UNIVERSAL=1 python3 fix_dosbox_x_build.py; then
        warn "patch/configure FAILED: $(basename "$dir")"
        FAILED="$FAILED $(basename "$dir")"
        cd "$SCRIPT_DIR"
        continue
    fi

    verify_patches_applied "$dir"

    # ── Build ────────────────────────────────────────────────────────────────
    msg "building (-j$NPROC, universal, macOS-min=${MACOS_MIN})..."
    if make -j"$NPROC"; then
        if [ -x "$dir/src/dosbox-x" ]; then
            if verify_binary "$dir/src/dosbox-x"; then
                ok "built + verified: $(basename "$dir")"
                BUILT="$BUILT $dir"
            else
                warn "verification FAILED for $(basename "$dir") — see warnings above"
                dump_core_defines "$dir"
                FAILED="$FAILED $(basename "$dir")(verify)"
            fi
        else
            warn "make succeeded but src/dosbox-x is missing?!"
            FAILED="$FAILED $(basename "$dir")"
        fi
    else
        warn "build FAILED: $(basename "$dir")"
        FAILED="$FAILED $(basename "$dir")"
    fi
    cd "$SCRIPT_DIR"
done

# ── Summary ──────────────────────────────────────────────────────────────────

echo
msg "=== Summary ==="
for d in $BUILT; do
    ok "✓ $(basename "$d")  →  $(basename "$d")/src/dosbox-x"
done
for n in $FAILED; do
    warn "✗ $n  →  FAILED"
done

if [ -n "$BUILT" ]; then
    echo
    msg "To package each version as a portable .app + DMG:"
    for d in $BUILT; do
        printf "    ./package_dosbox_x_macos.sh %s\n" "$(basename "$d")"
    done
fi
echo
[ -z "$FAILED" ] || exit 1
