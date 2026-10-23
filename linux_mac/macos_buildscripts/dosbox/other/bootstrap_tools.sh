#!/usr/bin/env bash
# bootstrap_tools.sh — Build every build-time tool from official source
# tarballs into a local prefix (./tools-prefix). NO Homebrew, NO MacPorts.
#
# The only prerequisite is the Xcode Command Line Tools:
#     xcode-select --install
#
# Tools built (host-arch only — these NEVER ship in the final .app):
#   m4, autoconf, automake, libtool     — for ECE's autogen.sh / configure
#   pkgconf (as pkg-config)             — dependency discovery
#   cmake                               — SDL2, sdl12-compat, mt32emu,
#                                         libsamplerate, fluidsynth
#   ninja + meson                       — glib (needed by fluidsynth)
#
# Everything is compiled with the stock Apple clang from the CLT. The first
# run takes roughly 20–40 minutes (cmake dominates); later runs are instant
# thanks to stamp files.
#
# Usage:
#   ./bootstrap_tools.sh            # build everything missing
#   ./bootstrap_tools.sh --clean    # wipe tools-prefix and rebuild
#   ./bootstrap_tools.sh cmake      # force-rebuild one tool
#
# Compatible with the stock /bin/bash 3.2 on macOS.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOLS_PREFIX="${TOOLS_PREFIX:-$SCRIPT_DIR/tools-prefix}"
CACHE="$SCRIPT_DIR/tools-cache"
BUILD="$SCRIPT_DIR/tools-build"
NPROC=$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)

# ── Helpers ───────────────────────────────────────────────────────────────────

msg()  { printf "\033[36m[tools]\033[0m %s\n" "$*"; }
ok()   { printf "\033[32m[ ok  ]\033[0m %s\n" "$*"; }
warn() { printf "\033[33m[warn ]\033[0m %s\n" "$*" >&2; }
die()  { printf "\033[31m[err  ]\033[0m %s\n" "$*" >&2; exit 1; }

stamp_done() { [ -f "$TOOLS_PREFIX/.stamps/$1" ]; }
stamp_ok()   { mkdir -p "$TOOLS_PREFIX/.stamps"; date -u "+%FT%TZ" > "$TOOLS_PREFIX/.stamps/$1"; }

dl() {
    # dl <url> <output-filename>
    local url="$1" out="$2"
    if [ -f "$CACHE/$out" ]; then return 0; fi
    msg "fetching: $out"
    curl -fL --retry 3 --retry-delay 2 "$url" -o "$CACHE/$out.tmp" \
        || die "Download failed: $url"
    mv "$CACHE/$out.tmp" "$CACHE/$out"
}

extract_to() {
    # extract_to <archive-filename-in-cache> <dest-dir>  (strip 1 component)
    local archive="$1" dest="$2"
    rm -rf "$dest"
    mkdir -p "$dest"
    case "$archive" in
        *.tar.gz|*.tgz) tar --strip-components=1 -xzf "$CACHE/$archive" -C "$dest" ;;
        *.tar.xz)       tar --strip-components=1 -xJf "$CACHE/$archive" -C "$dest" ;;
        *.tar.bz2)      tar --strip-components=1 -xjf "$CACHE/$archive" -C "$dest" ;;
        *) die "Unknown archive format: $archive" ;;
    esac
}

# ── Sanity: Xcode Command Line Tools ─────────────────────────────────────────

if ! xcode-select -p >/dev/null 2>&1; then
    die "Xcode Command Line Tools not installed. Run: xcode-select --install"
fi
for t in clang clang++ make curl tar python3 perl; do
    command -v "$t" >/dev/null 2>&1 || die "Missing required tool: $t"
done

# ── Clean, isolated build environment ────────────────────────────────────────
# Host tools: build for the host arch only, no deployment target games.
# Keep /usr/local, /opt/local and /opt/homebrew OFF the PATH entirely.

_xcode_bin="$(dirname "$(xcrun -f clang 2>/dev/null || echo /usr/bin/clang)")"
export PATH="$TOOLS_PREFIX/bin:$_xcode_bin:/usr/bin:/bin:/usr/sbin:/sbin"
export CC="$(xcrun -f clang)"
export CXX="$(xcrun -f clang++)"
unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS
unset PKG_CONFIG_PATH PKG_CONFIG_LIBDIR
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH
unset LIBRARY_PATH DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH
unset CMAKE_PREFIX_PATH CMAKE_FRAMEWORK_PATH
SDKROOT_VAL="$(xcrun --show-sdk-path 2>/dev/null || true)"
[ -n "$SDKROOT_VAL" ] && export SDKROOT="$SDKROOT_VAL"

# Newer clang hard-errors on K&R-isms in some older tool sources.
COMPAT_CFLAGS="-Wno-error=implicit-function-declaration -Wno-implicit-function-declaration -Wno-implicit-int"

# ── Generic GNU-style builder ─────────────────────────────────────────────────

gnu_build() {
    # gnu_build <name> <archive> [configure-arg...]
    local name="$1" archive="$2"
    shift 2
    local src="$BUILD/$name"
    extract_to "$archive" "$src"
    ( cd "$src" && \
      CFLAGS="-O2 $COMPAT_CFLAGS" \
      ./configure --prefix="$TOOLS_PREFIX" "$@" && \
      make -j"$NPROC" && \
      make install )
}

# ── Individual tools ─────────────────────────────────────────────────────────

build_m4() {
    stamp_done m4 && { ok "m4 (cached)"; return; }
    local v=1.4.19 a="m4-1.4.19.tar.xz"
    dl "https://ftpmirror.gnu.org/gnu/m4/${a}" "$a"
    gnu_build m4 "$a"
    stamp_ok m4; ok "m4 $v"
}

build_autoconf() {
    stamp_done autoconf && { ok "autoconf (cached)"; return; }
    local v=2.72 a="autoconf-2.72.tar.xz"
    dl "https://ftpmirror.gnu.org/gnu/autoconf/${a}" "$a"
    gnu_build autoconf "$a"
    stamp_ok autoconf; ok "autoconf $v"
}

build_automake() {
    stamp_done automake && { ok "automake (cached)"; return; }
    local v=1.17 a="automake-1.17.tar.xz"
    dl "https://ftpmirror.gnu.org/gnu/automake/${a}" "$a"
    gnu_build automake "$a"
    stamp_ok automake; ok "automake $v"
}

build_libtool() {
    stamp_done libtool && { ok "libtool (cached)"; return; }
    local v=2.5.4 a="libtool-2.5.4.tar.xz"
    dl "https://ftpmirror.gnu.org/gnu/libtool/${a}" "$a"
    # Prefix the binaries with 'g' (glibtool/glibtoolize) so GNU libtool does
    # NOT shadow Apple's /usr/bin/libtool, which clang/cmake use to create
    # static archives on macOS. Autotools projects only need libtoolize, so
    # expose that one under its plain name too.
    gnu_build libtool "$a" --program-prefix=g
    ln -sf glibtoolize "$TOOLS_PREFIX/bin/libtoolize"
    stamp_ok libtool; ok "libtool $v"
}

build_pkgconf() {
    stamp_done pkgconf && { ok "pkgconf (cached)"; return; }
    local v=2.3.0 a="pkgconf-2.3.0.tar.xz"
    dl "https://distfiles.ariadne.space/pkgconf/${a}" "$a"
    gnu_build pkgconf "$a" \
        --with-system-libdir=/usr/lib \
        --with-system-includedir=/usr/include
    ln -sf pkgconf "$TOOLS_PREFIX/bin/pkg-config"
    stamp_ok pkgconf; ok "pkgconf $v (installed as pkg-config)"
}

build_cmake() {
    stamp_done cmake && { ok "cmake (cached)"; return; }
    local v=3.31.7 a="cmake-3.31.7.tar.gz"
    dl "https://github.com/Kitware/CMake/releases/download/v${v}/${a}" "$a"
    local src="$BUILD/cmake"
    extract_to "$a" "$src"
    msg "bootstrapping cmake $v (this is the slow one — 15-30 min)..."
    ( cd "$src" && \
      ./bootstrap --prefix="$TOOLS_PREFIX" --parallel="$NPROC" \
                  -- -DCMAKE_USE_OPENSSL=OFF -DCMAKE_BUILD_TYPE=Release && \
      make -j"$NPROC" && \
      make install )
    stamp_ok cmake; ok "cmake $v"
}

build_ninja() {
    stamp_done ninja && { ok "ninja (cached)"; return; }
    local v=1.12.1 a="ninja-v1.12.1.tar.gz"
    dl "https://github.com/ninja-build/ninja/archive/refs/tags/v${v}.tar.gz" "$a"
    local src="$BUILD/ninja"
    extract_to "$a" "$src"
    ( cd "$src" && python3 configure.py --bootstrap )
    mkdir -p "$TOOLS_PREFIX/bin"
    cp "$src/ninja" "$TOOLS_PREFIX/bin/ninja"
    stamp_ok ninja; ok "ninja $v"
}

build_meson() {
    stamp_done meson && { ok "meson (cached)"; return; }
    local v=1.6.1 a="meson-1.6.1.tar.gz"
    dl "https://github.com/mesonbuild/meson/releases/download/${v}/${a}" "$a"
    local dest="$TOOLS_PREFIX/share/meson-$v"
    rm -rf "$dest"
    mkdir -p "$dest"
    tar --strip-components=1 -xzf "$CACHE/$a" -C "$dest"
    mkdir -p "$TOOLS_PREFIX/bin"
    cat > "$TOOLS_PREFIX/bin/meson" <<EOF
#!/bin/sh
# meson shim — runs meson straight from its source tree (pure python)
exec /usr/bin/env python3 "$dest/meson.py" "\$@"
EOF
    chmod +x "$TOOLS_PREFIX/bin/meson"
    stamp_ok meson; ok "meson $v"
}

# ── Main ─────────────────────────────────────────────────────────────────────

ALL_TOOLS="m4 autoconf automake libtool pkgconf cmake ninja meson"

usage() {
    cat <<EOF
Usage: $0 [--clean] [--list] [tool-name...]

With no arguments, builds every missing tool into:
    $TOOLS_PREFIX
EOF
}

main() {
    REBUILD=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --clean) msg "Removing $TOOLS_PREFIX and $BUILD (cache kept)"; rm -rf "$TOOLS_PREFIX" "$BUILD"; shift ;;
            --list)  printf "%s\n" $ALL_TOOLS; exit 0 ;;
            -h|--help) usage; exit 0 ;;
            -*) die "Unknown option: $1" ;;
            *)  REBUILD="$REBUILD $1"; shift ;;
        esac
    done

    mkdir -p "$TOOLS_PREFIX" "$TOOLS_PREFIX/bin" "$TOOLS_PREFIX/.stamps" "$CACHE" "$BUILD"

    for n in $REBUILD; do
        rm -f "$TOOLS_PREFIX/.stamps/$n"
    done

    echo "=== DOSBox ECE build-tools bootstrap (no Homebrew / no MacPorts) ==="
    echo "   Prefix:  $TOOLS_PREFIX"
    echo "   Cache:   $CACHE"
    echo "   SDK:     ${SDKROOT:-<auto>}"
    echo

    if [ -n "$REBUILD" ]; then
        for name in $REBUILD; do
            "build_$name"
        done
    else
        for name in $ALL_TOOLS; do
            "build_$name"
        done
    fi

    echo
    ok "Build tools ready at: $TOOLS_PREFIX/bin"
    echo
    echo "Installed:"
    for t in m4 autoconf automake libtool pkg-config cmake ninja meson; do
        if [ -x "$TOOLS_PREFIX/bin/$t" ]; then
            printf "  %-12s %s\n" "$t" "$("$TOOLS_PREFIX/bin/$t" --version 2>/dev/null | head -1)"
        fi
    done
    echo
    echo "Next: ./build_deps.sh   (it puts tools-prefix/bin on PATH automatically)"
}

main "$@"
