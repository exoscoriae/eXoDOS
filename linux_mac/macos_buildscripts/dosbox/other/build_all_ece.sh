#!/usr/bin/env bash
# build_all_ece.sh — Build all DOSBox ECE tarballs as universal (arm64 + x86_64)
# binaries targeting macOS 11.0, on a CURRENT macOS host (no VM needed).
#
# No Homebrew. No MacPorts. Build tools come from ./tools-prefix
# (bootstrap_tools.sh) and libraries from ./deps-prefix (build_deps.sh);
# both are created automatically if missing.
#
# Usage:
#   ./build_all_ece.sh
#
# The pipeline:
#   1. Bootstrap build tools from source if missing.
#   2. Build dependency libraries from source if missing.
#   3. Download and cache codec sources once (~134 MB).
#   4. For each ece-*-source.tar.gz:
#      a. Clean-extract into a sibling directory.
#      b. Copy and run fix_macos_build.py (patches + autogen + configure).
#         This includes the Apple Silicon dynamic-core fixes (arm64 host
#         detection, per-arch config.h, W^X/MAP_JIT/16K-page cache).
#      c. Verify the dynamic-core patches actually landed (hard failure if not).
#      d. Pre-populate codec sources into the decoder tree.
#      e. make -j
#   5. Verify each produced binary is universal AND that each slice contains
#      its dynamic core (dyn_x86 on x86_64, dynrec on arm64).
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

[ -f "$SCRIPT_DIR/fix_macos_build.py" ] \
    || die "fix_macos_build.py not found in $SCRIPT_DIR"

# ── Ensure build tools + dependency prefix exist ─────────────────────────────

if [ ! -x "$TOOLS_PREFIX/bin/cmake" ] || [ ! -x "$TOOLS_PREFIX/bin/autoconf" ]; then
    msg "Build tools missing — running bootstrap_tools.sh (first run: 20-40 min)..."
    [ -x "$SCRIPT_DIR/bootstrap_tools.sh" ] || die "bootstrap_tools.sh not found"
    TOOLS_PREFIX="$TOOLS_PREFIX" "$SCRIPT_DIR/bootstrap_tools.sh"
fi

# ALWAYS run build_deps.sh — it is stamp-based, so a complete prefix costs
# only a few seconds, while a partial one (e.g. from a previously failed run)
# resumes exactly where it stopped. Checking for the directory alone is not
# enough: a half-built prefix would silently break the ECE configure step.
[ -x "$SCRIPT_DIR/build_deps.sh" ] || die "build_deps.sh not found or not executable"
msg "Ensuring dependency libraries are complete (stamps make this fast)..."
DEPS_PREFIX="$DEPS_PREFIX" TOOLS_PREFIX="$TOOLS_PREFIX" "$SCRIPT_DIR/build_deps.sh" \
    || die "build_deps.sh failed — fix the reported dependency and re-run."

# Sanity: the two files the ECE configure step depends on most.
[ -x "$DEPS_PREFIX/bin/sdl-config" ] \
    || die "deps-prefix is incomplete: bin/sdl-config missing (sdl12-compat). Run ./build_deps.sh"
ls "$DEPS_PREFIX/lib/libSDL2"*.dylib >/dev/null 2>&1 \
    || die "deps-prefix is incomplete: libSDL2 missing. Run ./build_deps.sh"

# ── Export universal + macOS-min build flags ─────────────────────────────────

export MACOSX_DEPLOYMENT_TARGET="${MACOS_MIN}"
export DEPS_PREFIX

# ── Fully isolated build environment ─────────────────────────────────────────
# PATH contains ONLY: our tools prefix, our deps prefix, Xcode, and the base
# system. /usr/local, /opt/local, /opt/homebrew never appear, so nothing from
# a package manager can leak into configure or the link.
unset PKG_CONFIG_PATH
export PKG_CONFIG_LIBDIR="${DEPS_PREFIX}/lib/pkgconfig:${DEPS_PREFIX}/share/pkgconfig"
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH OBJCPLUS_INCLUDE_PATH
unset LIBRARY_PATH DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH
unset CMAKE_PREFIX_PATH CMAKE_FRAMEWORK_PATH

export CC="$(xcrun -f clang 2>/dev/null || echo /usr/bin/clang)"
export CXX="$(xcrun -f clang++ 2>/dev/null || echo /usr/bin/clang++)"

_xcode_bin="$(dirname "$(xcrun -f clang 2>/dev/null || echo /usr/bin/clang)")"
export PATH="${TOOLS_PREFIX}/bin:${DEPS_PREFIX}/bin:${_xcode_bin}:/usr/bin:/bin:/usr/sbin:/sbin"

# Newer clang hard-errors on implicit function declarations; the bundled
# codec sub-builds contain old C that trips this. Downgrade to warnings.
COMPAT_CFLAGS="-Wno-error=implicit-function-declaration -Wno-implicit-function-declaration -Wno-implicit-int"

export CPPFLAGS="-I${DEPS_PREFIX}/include ${UVER}"
export CFLAGS="${UARCH} ${UVER} -O2 ${COMPAT_CFLAGS} -I${DEPS_PREFIX}/include"
export CXXFLAGS="${UARCH} ${UVER} -O2 -I${DEPS_PREFIX}/include"
# Two rpaths: deps-prefix/lib (so configure's AC_TRY_RUN test programs can
# find our dylibs) and the final bundle layout. The first one is stripped by
# bundle_dylibs.py at packaging time.
export LDFLAGS="${UARCH} ${UVER} -L${DEPS_PREFIX}/lib -Wl,-rpath,${DEPS_PREFIX}/lib -Wl,-rpath,@executable_path/../Frameworks"
export DYLD_FALLBACK_LIBRARY_PATH="${DEPS_PREFIX}/lib"

if [ -z "${SDKROOT:-}" ]; then
    SDKROOT_VAL="$(xcrun --show-sdk-path 2>/dev/null || true)"
    [ -n "$SDKROOT_VAL" ] && export SDKROOT="$SDKROOT_VAL"
fi

# ── Codec source cache ────────────────────────────────────────────────────────
# The ECE decoder Makefile downloads these from xiph.org / GitHub at build
# time. We download them once and pre-populate each build.
# (bash 3.2 has no associative arrays — use parallel lists.)

CODEC_CACHE="$SCRIPT_DIR/codec-cache"
mkdir -p "$CODEC_CACHE"

OPUS_DNN_HASH="a5177ec6fb7d15058e99e57029746100121f68e4890b1467d4094aa336b6013e"
OPUS_DNN_FILE="opus_data-${OPUS_DNN_HASH}.tar.gz"
OPUS_DNN_URL="https://media.xiph.org/opus/models/${OPUS_DNN_FILE}"

CODEC_FILES="ogg-master.tar.gz opus-master.tar.gz opusfile-master.tar.gz speexdsp-master.tar.gz pkg.m4"

codec_url_for() {
    case "$1" in
        ogg-master.tar.gz)      echo "https://github.com/xiph/ogg/archive/master.tar.gz" ;;
        opus-master.tar.gz)     echo "https://github.com/xiph/opus/archive/master.tar.gz" ;;
        opusfile-master.tar.gz) echo "https://github.com/xiph/opusfile/archive/master.tar.gz" ;;
        speexdsp-master.tar.gz) echo "https://github.com/xiph/speexdsp/archive/master.tar.gz" ;;
        pkg.m4)                 echo "https://raw.githubusercontent.com/xiph/speex/master/m4/pkg.m4" ;;
        *) die "Unknown codec file: $1" ;;
    esac
}

msg "Checking codec source cache..."
for filename in $CODEC_FILES; do
    cached="$CODEC_CACHE/$filename"
    if [ -f "$cached" ]; then
        ok "codec cached: $filename"
    else
        msg "downloading: $filename"
        curl -fsSL --retry 3 "$(codec_url_for "$filename")" -o "$cached" \
            || die "Failed to download $filename"
    fi
done

if [ -f "$CODEC_CACHE/$OPUS_DNN_FILE" ]; then
    ok "codec cached: $OPUS_DNN_FILE"
else
    msg "downloading: $OPUS_DNN_FILE (128 MB)..."
    curl -fSL --retry 3 "$OPUS_DNN_URL" -o "$CODEC_CACHE/$OPUS_DNN_FILE" \
        || die "Failed to download $OPUS_DNN_FILE"
fi
echo

# ── Verification helpers ─────────────────────────────────────────────────────

verify_patches_applied() {
    # Hard-fail if the Apple Silicon dynamic-core patches did not land.
    # Running a build whose dynamic core is silently broken is exactly the
    # failure mode we're fixing, so refuse to continue.
    local dir="$1" bad=0

    # r4301/r4358: src/cpu/core_dynrec/cache.h; r4482+: shared src/cpu/dyn_cache.h
    local cache_h="$dir/src/cpu/core_dynrec/cache.h"
    [ -f "$cache_h" ] || cache_h="$dir/src/cpu/dyn_cache.h"

    # The override that matters lives in include/dosbox.h — it survives even
    # if make re-runs config.status and regenerates config.h (which drops
    # anything appended to it; that silently disabled both dynamic cores).
    grep -q 'per-architecture dynamic core selection' "$dir/include/dosbox.h" 2>/dev/null \
        || { warn "include/dosbox.h is missing the per-arch dynamic core override"; bad=1; }
    grep -q 'per-architecture dynamic core selection' "$dir/config.h" 2>/dev/null \
        || warn "config.h lacks the per-arch override copy (non-fatal: dosbox.h carries it)"
    grep -q 'MAP_JIT' "$cache_h" 2>/dev/null \
        || { warn "$(basename "$cache_h") is missing the MAP_JIT allocation patch"; bad=1; }
    grep -q 'PAGESIZE_TEMP 16384' "$cache_h" 2>/dev/null \
        || { warn "$(basename "$cache_h") is missing the 16 KiB page-size patch"; bad=1; }
    grep -q 'cache_jit_writable' "$dir/src/cpu/core_dynrec.cpp" 2>/dev/null \
        || { warn "core_dynrec.cpp is missing the W^X toggle patch"; bad=1; }

    [ $bad -eq 0 ] || die "Dynamic-core patches incomplete in $(basename "$dir") — aborting."
    ok "dynamic-core patches verified in source tree"
}

dump_core_defines() {
    # Diagnostic: show what each slice's preprocessor ACTUALLY sees for the
    # dynamic-core macros after including dosbox.h (undefined macros stay
    # as literal [C_...] text; defined ones show their value).
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
    # 1. universal?  2. does each slice carry its dynamic core?
    local bin="$1" bad=0

    # NOTE: no `grep -q` on pipes here! This script runs under pipefail, and
    # `grep -q` exits at the FIRST match, killing the producer (nm) with
    # SIGPIPE — which pipefail then reports as pipeline failure. That made
    # every symbol check below fail precisely when the symbol WAS present.
    # Plain grep >/dev/null consumes all input and avoids the SIGPIPE.
    lipo -archs "$bin" 2>/dev/null | grep 'arm64' >/dev/null \
        || { warn "binary is missing the arm64 slice"; bad=1; }
    lipo -archs "$bin" 2>/dev/null | grep 'x86_64' >/dev/null \
        || { warn "binary is missing the x86_64 slice"; bad=1; }

    if nm -arch arm64 "$bin" 2>/dev/null | grep 'CPU_Core_Dynrec_Run' >/dev/null; then
        ok "arm64 slice: dynrec core present (CPU_Core_Dynrec_Run)"
    else
        warn "arm64 slice does NOT contain the dynrec core!"
        bad=1
    fi
    if nm -arch x86_64 "$bin" 2>/dev/null | grep 'CPU_Core_Dyn_X86_Run' >/dev/null; then
        ok "x86_64 slice: dynamic core present (CPU_Core_Dyn_X86_Run)"
    else
        warn "x86_64 slice does NOT contain the x86 dynamic core!"
        bad=1
    fi

    # minos check: every slice must target macOS 11.0
    local minos
    minos="$(otool -l "$bin" 2>/dev/null | awk '/minos/ {print $2}' | sort -u | tr '\n' ' ')"
    msg "minos of slices: ${minos:-unknown}"

    return $bad
}

# ── Main loop ────────────────────────────────────────────────────────────────

# Download the ECE source tarballs if they aren't here yet.
ECE_SOURCE_BASE="https://github.com/jonesaaronj/exo_flatpaks/releases/download/source_bundles"
for rev in r4301 r4358 r4482; do
    t="$SCRIPT_DIR/ece-${rev}-source.tar.gz"
    if [ ! -f "$t" ]; then
        msg "downloading ece-${rev}-source.tar.gz ..."
        curl -fL --retry 3 "$ECE_SOURCE_BASE/ece-${rev}-source.tar.gz" -o "$t.tmp" \
            && mv "$t.tmp" "$t" \
            || { rm -f "$t.tmp"; warn "could not download ece-${rev} source"; }
    fi
done

TARBALLS=""
for t in "$SCRIPT_DIR"/ece-*-source.tar.gz; do
    [ -e "$t" ] && TARBALLS="$TARBALLS $t"
done
[ -n "$TARBALLS" ] || die "No ece-*-source.tar.gz tarballs found in $SCRIPT_DIR
Download them from:
  https://github.com/jonesaaronj/exo_flatpaks/releases/tag/source_bundles"

BUILT=""
FAILED=""

for tarball in $TARBALLS; do
    filename=$(basename "$tarball")
    dir="$SCRIPT_DIR/${filename%-source.tar.gz}"
    echo
    msg "=== Processing $filename ==="

    # ── Clean extract ────────────────────────────────────────────────────────
    msg "extracting into $(basename "$dir") (clean)..."
    rm -rf "$dir"
    mkdir -p "$dir"
    tar --strip-components=1 -xzf "$tarball" -C "$dir"

    # ── Apply patches and run configure ──────────────────────────────────────
    cp "$SCRIPT_DIR/fix_macos_build.py" "$dir/"
    msg "applying macOS patches and running configure..."
    cd "$dir"
    if ! DEPS_PREFIX="$DEPS_PREFIX" UNIVERSAL=1 python3 fix_macos_build.py; then
        warn "patch/configure FAILED: $(basename "$dir")"
        FAILED="$FAILED $(basename "$dir")"
        cd "$SCRIPT_DIR"
        continue
    fi

    # ── Verify the dynamic-core patches landed ───────────────────────────────
    verify_patches_applied "$dir"

    # ── Pre-populate codec sources to avoid build-time downloads ─────────────
    DECODER_DIR="$dir/src/libs/decoders/internal"
    if [ -d "$DECODER_DIR" ]; then
        msg "pre-populating codec sources from cache..."
        for codec_file in $CODEC_FILES; do
            cp "$CODEC_CACHE/$codec_file" "$DECODER_DIR/$codec_file"
        done
        OPUS_SRC="$DECODER_DIR/opus"
        if [ ! -d "$OPUS_SRC" ]; then
            mkdir -p "$OPUS_SRC"
            tar --strip-components=1 -zxof "$CODEC_CACHE/opus-master.tar.gz" -C "$OPUS_SRC"
        fi
        cp "$CODEC_CACHE/$OPUS_DNN_FILE" "$OPUS_SRC/$OPUS_DNN_FILE"
        ok "Opus DNN model pre-placed"
    fi

    # ── Build ─────────────────────────────────────────────────────────────────
    msg "building (-j$NPROC, universal, macOS-min=${MACOS_MIN})..."
    if make -j"$NPROC"; then
        if [ -x "$dir/src/dosbox" ]; then
            if verify_binary "$dir/src/dosbox"; then
                ok "built + verified: $(basename "$dir")"
                BUILT="$BUILT $dir"
            else
                warn "verification FAILED for $(basename "$dir") — see warnings above"
                grep -q 'per-architecture dynamic core selection' "$dir/config.h" 2>/dev/null \
                    || warn "config.h no longer contains the override — make regenerated it"
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
done

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
    msg "To package each version as a portable .app + DMG:"
    for d in $BUILT; do
        printf "    ./package_macos.sh %s\n" "$(basename "$d")"
    done
fi
echo
[ -z "$FAILED" ] || exit 1
