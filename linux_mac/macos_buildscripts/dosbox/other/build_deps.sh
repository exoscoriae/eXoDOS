#!/usr/bin/env bash
# build_deps.sh — Build all DOSBox ECE dependencies as universal (arm64 + x86_64)
# binaries targeting macOS 11.0, installed into a local prefix. No Homebrew.
#
# Every library is built ONCE PER ARCHITECTURE into its own DESTDIR staging
# directory, then the resulting Mach-O files are merged with `lipo -create`
# into $PREFIX. This avoids the classic autotools pitfall where a single
# ./configure run (on an x86_64 host) disables ARM NEON code paths for the
# arm64 slice — which is exactly the libpng linker failure we saw before.
#
# Build tools come from ./tools-prefix, produced by bootstrap_tools.sh —
# NO Homebrew and NO MacPorts, ever. If tools-prefix is missing, this script
# runs bootstrap_tools.sh automatically. The only system prerequisite is the
# Xcode Command Line Tools (xcode-select --install).
#
# Usage:
#   ./build_deps.sh                 # build the ECE dependency set
#   ./build_deps.sh --all           # also build gridc/dosbox-x extras
#   ./build_deps.sh --clean         # wipe prefix and rebuild from scratch
#   ./build_deps.sh <name>          # force rebuild a single dep

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${DEPS_PREFIX:-$SCRIPT_DIR/deps-prefix}"
TOOLS_PREFIX="${TOOLS_PREFIX:-$SCRIPT_DIR/tools-prefix}"
CACHE="$SCRIPT_DIR/deps-cache"
BUILD="$SCRIPT_DIR/deps-build"

# ── Configuration ─────────────────────────────────────────────────────────────

MACOS_MIN=11.0
ARCHS=(arm64 x86_64)
UVER="-mmacosx-version-min=${MACOS_MIN}"

export MACOSX_DEPLOYMENT_TARGET="${MACOS_MIN}"

# --- Isolate the build from MacPorts / Homebrew / system prefixes ------------
# The user's build VM has MacPorts installed at /opt/local. Without this
# isolation, MacPorts' pkg-config (built with --with-pc-path=/opt/local/lib
# /pkgconfig) will silently hand every build a single-arch libz/libffi/etc.
# from /opt/local — which explodes at link-time when producing a universal
# dylib. We use PKG_CONFIG_LIBDIR (which REPLACES pkg-config's search path,
# unlike PKG_CONFIG_PATH which only prepends) to pin it to our own prefix.
unset PKG_CONFIG_PATH
export PKG_CONFIG_LIBDIR="${PREFIX}/lib/pkgconfig:${PREFIX}/share/pkgconfig"

# Clear compiler/linker env vars that some shell inits (or MacPorts' own
# /opt/local/share/macports/setupenv.bash) may populate, pointing clang at
# /opt/local headers/libs implicitly.
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH
unset LIBRARY_PATH DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH
unset CMAKE_PREFIX_PATH CMAKE_FRAMEWORK_PATH

# Fixed, sanitized PATH: our tool prefix + our dep prefix + Xcode + system.
# /usr/local, /opt/local and /opt/homebrew are deliberately EXCLUDED so no
# package-manager binary or library can leak into the build.
_xcode_bin="$(dirname "$(xcrun -f clang 2>/dev/null || echo /usr/bin/clang)")"
export PATH="${TOOLS_PREFIX}/bin:${PREFIX}/bin:${_xcode_bin}:/usr/bin:/bin:/usr/sbin:/sbin"

# Newer clang (Xcode 15+) errors out on implicit function declarations, which
# breaks configure feature tests and some old C sources (SDL_net 1.2.8 etc.).
# Downgrade back to warnings for these mature, known-good libraries.
COMPAT_CFLAGS="-Wno-error=implicit-function-declaration -Wno-implicit-function-declaration -Wno-implicit-int"

# Paths we want CMake / pkg-config / compilers to pretend don't exist.
# Used below when driving CMake and referenced elsewhere for sanity.
IGNORED_PREFIXES=(/opt/local /usr/local /opt/homebrew)

SDKROOT_VAL="$(xcrun --show-sdk-path 2>/dev/null || true)"
if [[ -n "$SDKROOT_VAL" ]]; then
    export SDKROOT="$SDKROOT_VAL"
fi

NPROC=$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)

HOST_ARCH=$(uname -m)   # arm64 or x86_64

# ── Helpers ───────────────────────────────────────────────────────────────────

msg()  { printf "\033[36m[deps]\033[0m %s\n" "$*"; }
ok()   { printf "\033[32m[ ok ]\033[0m %s\n" "$*"; }
warn() { printf "\033[33m[warn]\033[0m %s\n" "$*" >&2; }
die()  { printf "\033[31m[err ]\033[0m %s\n" "$*" >&2; exit 1; }

ensure_tool() {
    command -v "$1" >/dev/null 2>&1 || die "Missing build tool: $1 — see header of this script for install hints"
}

dl() {
    local url="$1" out="$2"
    if [[ -f "$CACHE/$out" ]]; then return 0; fi
    msg "fetching: $out"
    curl -fL --retry 3 --retry-delay 2 "$url" -o "$CACHE/$out.tmp" \
        || die "Download failed: $url"
    mv "$CACHE/$out.tmp" "$CACHE/$out"
}

extract() {
    local archive="$1" destname="$2"
    extract_stripped_to "$archive" "$BUILD/$destname"
}

# Extract an archive into $dest so that $dest contains the source tree directly
# (equivalent to tar's --strip-components=1 behaviour). Handles tarballs and
# zip archives (GitHub release zips wrap everything in a single top-level dir).
extract_stripped_to() {
    local archive="$1" dest="$2"
    rm -rf "$dest"
    mkdir -p "$dest"
    case "$archive" in
        *.tar.gz|*.tgz) tar --strip-components=1 -xzf "$CACHE/$archive" -C "$dest" ;;
        *.tar.xz)       tar --strip-components=1 -xJf "$CACHE/$archive" -C "$dest" ;;
        *.tar.bz2)      tar --strip-components=1 -xjf "$CACHE/$archive" -C "$dest" ;;
        *.tar)          tar --strip-components=1 -xf  "$CACHE/$archive" -C "$dest" ;;
        *.zip)
            local tmp="${dest}.extract-tmp"
            rm -rf "$tmp"; mkdir -p "$tmp"
            unzip -q "$CACHE/$archive" -d "$tmp"
            # GitHub zips wrap the source in a single top-level directory;
            # strip it to mirror tar --strip-components=1.
            local entries=("$tmp"/*)
            if [[ ${#entries[@]} -eq 1 && -d "${entries[0]}" ]]; then
                rmdir "$dest"
                mv "${entries[0]}" "$dest"
            else
                # Multiple top-level entries (rare): move them all.
                shopt -s dotglob
                mv "$tmp"/* "$dest"/
                shopt -u dotglob
            fi
            rm -rf "$tmp"
            ;;
        *) die "Unknown archive format: $archive" ;;
    esac
}

stamp_done() { [[ -f "$PREFIX/.stamps/$1" ]]; }
stamp_ok()   { mkdir -p "$PREFIX/.stamps"; echo "$(date -u +%FT%TZ)" > "$PREFIX/.stamps/$1"; }

host_triplet_for() {
    case "$1" in
        arm64)  echo "aarch64-apple-darwin" ;;
        x86_64) echo "x86_64-apple-darwin" ;;
        *) die "Unknown arch: $1" ;;
    esac
}

verify_universal() {
    local f="$1"
    local info
    info="$(lipo -info "$f" 2>/dev/null || true)"
    for a in "${ARCHS[@]}"; do
        if [[ "$info" != *"$a"* ]]; then
            warn "Not universal (missing $a): $f — $info"
            return 1
        fi
    done
    return 0
}

verify_prefix_universal() {
    local bad=0
    while IFS= read -r f; do
        if file "$f" 2>/dev/null | grep -qE 'Mach-O|current ar archive'; then
            verify_universal "$f" || bad=$((bad + 1))
        fi
    done < <(find "$PREFIX/lib" -maxdepth 2 \( -name "*.dylib" -o -name "*.a" \) -type f 2>/dev/null)
    if [[ $bad -gt 0 ]]; then
        warn "$bad library file(s) are not universal — see warnings above."
        return 1
    fi
    ok "All installed dylibs and static archives verified universal (arm64 + x86_64)."
}

# ── Fresh config.sub / config.guess ───────────────────────────────────────────
# Older autotools tarballs (e.g. SDL_net 1.2.8 from 2011) ship a config.sub
# that doesn't recognize aarch64-apple-darwin. Overlay modern versions.

download_autotools_helpers() {
    dl "https://git.savannah.gnu.org/cgit/config.git/plain/config.sub"   "config.sub"
    dl "https://git.savannah.gnu.org/cgit/config.git/plain/config.guess" "config.guess"
    chmod +x "$CACHE/config.sub" "$CACHE/config.guess"
}

refresh_autotools_helpers() {
    local src_dir="$1"
    for f in config.sub config.guess; do
        while IFS= read -r path; do
            cp -f "$CACHE/$f" "$path"
            chmod +x "$path"
        done < <(find "$src_dir" -name "$f" -type f 2>/dev/null)
    done
}

# ── Merge per-arch stages into $PREFIX via lipo ───────────────────────────────
# For each file in the first stage:
#   - symlink  → recreate as symlink
#   - Mach-O   → lipo all arch copies into one universal file at $PREFIX
#   - regular  → copy first-stage copy (arch-independent file, e.g. headers,
#                pkg-config files, CMake configs)
# The staged install directories were created with `make install DESTDIR=$stage`
# while `--prefix=$PREFIX`, so each stage's tree mirrors $PREFIX.
merge_arch_stages() {
    local -a stages=("$@")
    local first="${stages[0]}"
    local src_root="${first}${PREFIX}"

    if [[ ! -d "$src_root" ]]; then
        warn "No install tree at $src_root (did make install use DESTDIR?)"
        return 1
    fi

    # Files and symlinks in the first stage drive the merge. Use -print0 to
    # handle the (unlikely) case of spaces in paths.
    while IFS= read -r -d '' rel; do
        rel="${rel#./}"
        local src="$src_root/$rel"
        local dest="$PREFIX/$rel"
        mkdir -p "$(dirname "$dest")"

        if [[ -L "$src" ]]; then
            local target
            target="$(readlink "$src")"
            rm -f "$dest"
            ln -s "$target" "$dest"
            continue
        fi

        # Anything lipo can combine: Mach-O binaries/dylibs AND ar static
        # archives of Mach-O objects. file(1) reports the latter as
        # "current ar archive", which doesn't match "Mach-O" — so we also
        # key off the .a / .dylib / .so extensions to be safe.
        local is_lipo_target=0
        case "$src" in
            *.dylib|*.a|*.so) is_lipo_target=1 ;;
        esac
        if [[ $is_lipo_target -eq 0 ]] \
           && file "$src" 2>/dev/null | grep -qE 'Mach-O|current ar archive'; then
            is_lipo_target=1
        fi

        if [[ $is_lipo_target -eq 1 ]]; then
            local -a inputs=()
            for s in "${stages[@]}"; do
                local sf="${s}${PREFIX}/${rel}"
                [[ -f "$sf" ]] && inputs+=("$sf")
            done
            if [[ ${#inputs[@]} -ge 2 ]]; then
                lipo -create "${inputs[@]}" -output "$dest"
            elif [[ ${#inputs[@]} -eq 1 ]]; then
                cp -f "${inputs[0]}" "$dest"
            else
                cp -f "$src" "$dest"
            fi
            # Preserve executability (.a should stay 644, .dylib/binaries 755).
            if [[ -x "$src" ]]; then chmod 755 "$dest"; else chmod 644 "$dest"; fi
        else
            cp -f "$src" "$dest"
        fi
    done < <(cd "$src_root" && find . \( -type f -o -type l \) -print0)
}

# ── Autotools universal build driver ─────────────────────────────────────────
# Extracts the source once per arch into $BUILD/<name>-<arch>, runs
# ./configure (with --host=<arch>-apple-darwin and per-arch CFLAGS) into its
# own stage, then lipos everything into $PREFIX.
#
# Args: name  archive_filename  configure_flag ...
autotools_universal() {
    local name="$1"; shift
    local archive="$1"; shift
    local -a cfg=("$@")

    local -a stages=()
    for arch in "${ARCHS[@]}"; do
        local arch_src="$BUILD/${name}-${arch}"
        extract_stripped_to "$archive" "$arch_src"
        refresh_autotools_helpers "$arch_src"

        # Per-package source fixups (e.g. strip linker flags that the modern
        # Xcode linker no longer understands). Runs on the freshly extracted
        # tree, before configure.
        local hook="preconfigure_${name//-/_}"
        if declare -F "$hook" >/dev/null; then
            "$hook" "$arch_src"
        fi

        local stage="$BUILD/.stage-${name}-${arch}"
        rm -rf "$stage"
        mkdir -p "$stage"
        stages+=("$stage")

        local triplet
        triplet="$(host_triplet_for "$arch")"

        pushd "$arch_src" >/dev/null
        # CPPFLAGS is required in addition to CFLAGS: autotools projects
        # often preprocess generated sources with `$(CPP)` standalone
        # (libpng's pnglibconf.c is one), which uses CPPFLAGS but NOT
        # CFLAGS. Without this, such steps pick up the system SDK's zlib.h
        # instead of ours, and libpng errors out with
        # `ZLIB_VERNUM != PNG_ZLIB_VERNUM`.
        CC="clang" CXX="clang++" \
        CPPFLAGS="-I${PREFIX}/include" \
        CFLAGS="-arch $arch ${UVER} -O2 ${COMPAT_CFLAGS} -I${PREFIX}/include" \
        CXXFLAGS="-arch $arch ${UVER} -O2 -I${PREFIX}/include" \
        OBJCFLAGS="-arch $arch ${UVER} -O2 -I${PREFIX}/include" \
        LDFLAGS="-arch $arch ${UVER} -L${PREFIX}/lib" \
        ./configure \
            --prefix="$PREFIX" \
            --host="$triplet" \
            --build="$triplet" \
            "${cfg[@]}"
        make -j"$NPROC"
        make install DESTDIR="$stage"
        popd >/dev/null
    done

    merge_arch_stages "${stages[@]}"
}

# ── CMake universal build driver ─────────────────────────────────────────────
# Runs cmake+make once per arch (with CMAKE_OSX_ARCHITECTURES=<one arch> so
# features like NEON/SSE are detected per slice), installs via DESTDIR, then
# lipos into $PREFIX.
#
# Args: name  archive_filename  subdir_after_extract  cmake_flag ...
cmake_universal() {
    local name="$1"; shift
    local archive="$1"; shift
    local subdir="$1"; shift      # "" means the archive's top level
    local -a cmake_args=("$@")

    local -a stages=()
    for arch in "${ARCHS[@]}"; do
        local arch_src="$BUILD/${name}-${arch}"
        extract_stripped_to "$archive" "$arch_src"

        local stage="$BUILD/.stage-${name}-${arch}"
        rm -rf "$stage"
        mkdir -p "$stage"
        stages+=("$stage")

        local cfg_dir="$arch_src"
        if [[ -n "$subdir" ]]; then
            cfg_dir="$arch_src/$subdir"
        fi

        pushd "$cfg_dir" >/dev/null
        rm -rf _b
        mkdir _b && cd _b
        # CMAKE_IGNORE_PREFIX_PATH/PATH stop find_package + find_library +
        # find_path from silently picking up /opt/local/lib/libz.dylib,
        # /opt/local/include/zlib.h, etc. when the host has MacPorts
        # (or Homebrew) installed. CMAKE_FIND_FRAMEWORK=LAST prevents
        # the system frameworks from shadowing our own libs.
        cmake .. \
            -DCMAKE_INSTALL_PREFIX="$PREFIX" \
            -DCMAKE_PREFIX_PATH="$PREFIX" \
            -DCMAKE_IGNORE_PREFIX_PATH="/opt/local;/usr/local;/opt/homebrew" \
            -DCMAKE_IGNORE_PATH="/opt/local/bin;/opt/local/lib;/opt/local/include;/usr/local/bin;/usr/local/lib;/usr/local/include;/opt/homebrew/bin;/opt/homebrew/lib;/opt/homebrew/include" \
            -DCMAKE_FIND_FRAMEWORK=LAST \
            -DCMAKE_FIND_APPBUNDLE=LAST \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_OSX_ARCHITECTURES="$arch" \
            -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOS_MIN}" \
            -DBUILD_SHARED_LIBS=ON \
            "${cmake_args[@]}"
        make -j"$NPROC"
        make install DESTDIR="$stage"
        popd >/dev/null
    done

    merge_arch_stages "${stages[@]}"
}

# ── Meson universal build driver (for glib) ───────────────────────────────────
# Writes a per-arch cross-file so meson uses the target's CPU family
# everywhere, builds separately for each arch, and lipos the results.
# Running with a cross-file prevents meson from executing the built helper
# binaries during configure — important since we can't run arm64 on x86_64.
meson_universal() {
    local name="$1"; shift
    local archive="$1"; shift
    local -a meson_args=("$@")

    local -a stages=()
    for arch in "${ARCHS[@]}"; do
        local arch_src="$BUILD/${name}-${arch}"
        extract_stripped_to "$archive" "$arch_src"

        local stage="$BUILD/.stage-${name}-${arch}"
        rm -rf "$stage"
        mkdir -p "$stage"
        stages+=("$stage")

        local cpu_family
        case "$arch" in
            arm64)  cpu_family="aarch64" ;;
            x86_64) cpu_family="x86_64" ;;
        esac

        local cf="$arch_src/cross-${arch}.ini"
        cat > "$cf" <<EOF
[binaries]
c = ['clang', '-arch', '${arch}']
cpp = ['clang++', '-arch', '${arch}']
objc = ['clang', '-arch', '${arch}']
ar = 'ar'
strip = 'strip'
pkg-config = 'pkg-config'

[built-in options]
c_args = ['-arch', '${arch}', '-mmacosx-version-min=${MACOS_MIN}', '-O2', '-I${PREFIX}/include']
cpp_args = ['-arch', '${arch}', '-mmacosx-version-min=${MACOS_MIN}', '-O2', '-I${PREFIX}/include']
c_link_args = ['-arch', '${arch}', '-mmacosx-version-min=${MACOS_MIN}', '-L${PREFIX}/lib']
cpp_link_args = ['-arch', '${arch}', '-mmacosx-version-min=${MACOS_MIN}', '-L${PREFIX}/lib']

[host_machine]
system = 'darwin'
cpu_family = '${cpu_family}'
cpu = '${arch}'
endian = 'little'
EOF

        pushd "$arch_src" >/dev/null
        meson setup _b \
            --prefix="$PREFIX" \
            --cross-file="$cf" \
            --buildtype=release \
            --default-library=shared \
            ${meson_args[@]+"${meson_args[@]}"}
        DESTDIR="$stage" ninja -C _b install
        popd >/dev/null
    done

    merge_arch_stages "${stages[@]}"
}

# ── Tool sanity ───────────────────────────────────────────────────────────────

check_build_tools() {
    msg "Checking build tools..."
    # Bootstrap the local toolchain (autotools, cmake, meson, ninja,
    # pkg-config) from source if it isn't there yet — no Homebrew/MacPorts.
    local need_bootstrap=0
    for t in cmake autoconf automake pkg-config meson ninja; do
        command -v "$t" >/dev/null 2>&1 || need_bootstrap=1
    done
    if [[ $need_bootstrap -eq 1 ]]; then
        if [[ -x "$SCRIPT_DIR/bootstrap_tools.sh" ]]; then
            msg "Local build tools missing — running bootstrap_tools.sh (first run: 20-40 min)..."
            TOOLS_PREFIX="$TOOLS_PREFIX" "$SCRIPT_DIR/bootstrap_tools.sh"
            hash -r
        else
            die "Build tools missing and bootstrap_tools.sh not found next to this script."
        fi
    fi
    for t in clang make cmake autoconf automake libtoolize pkg-config meson ninja curl tar unzip git lipo otool install_name_tool file; do
        ensure_tool "$t"
    done
    ok "Build tools present (from $TOOLS_PREFIX)"
}

# ─────────────────────────────────────────────────────────────────────────────
# Per-dependency builders
# ─────────────────────────────────────────────────────────────────────────────

build_zlib() {
    stamp_done zlib && { ok "zlib (cached)"; return; }
    local v=1.3.1 a="zlib-1.3.1.tar.gz"
    dl "https://zlib.net/fossils/zlib-1.3.1.tar.gz" "$a"

    # zlib's configure script is hand-rolled and does NOT accept
    # `--host=`/autoconf-style cross-compilation. Drive it per-arch
    # via CHOST + CC/CFLAGS overrides, stage, then lipo merge.
    local -a stages=()
    for arch in "${ARCHS[@]}"; do
        local arch_src="$BUILD/zlib-${arch}"
        extract_stripped_to "$a" "$arch_src"

        local stage="$BUILD/.stage-zlib-${arch}"
        rm -rf "$stage"
        mkdir -p "$stage"
        stages+=("$stage")

        pushd "$arch_src" >/dev/null
        CC="clang -arch $arch ${UVER}" \
        CFLAGS="-O2 ${COMPAT_CFLAGS}" \
        LDFLAGS="-arch $arch ${UVER}" \
        ./configure --prefix="$PREFIX"
        make -j"$NPROC"
        make install DESTDIR="$stage"
        popd >/dev/null
    done

    merge_arch_stages "${stages[@]}"

    # Remove the static archive so downstream builds unambiguously link
    # against the dylib (which is what gets bundled into the .app).
    rm -f "$PREFIX/lib/libz.a"

    stamp_ok zlib
    ok "zlib $v"
}

build_libpng() {
    stamp_done libpng && { ok "libpng (cached)"; return; }
    local v=1.6.43 a="libpng-1.6.43.tar.gz"
    dl "https://downloads.sourceforge.net/project/libpng/libpng16/${v}/${a}" "$a"
    autotools_universal "libpng" "$a" \
        --disable-static --enable-shared \
        --disable-dependency-tracking
    stamp_ok libpng
    ok "libpng $v"
}

build_libogg() {
    stamp_done libogg && { ok "libogg (cached)"; return; }
    local v=1.3.5 a="libogg-1.3.5.tar.gz"
    dl "https://downloads.xiph.org/releases/ogg/${a}" "$a"
    autotools_universal "libogg" "$a" \
        --disable-static --enable-shared \
        --disable-dependency-tracking
    stamp_ok libogg
    ok "libogg $v"
}

# libvorbis 1.3.7's configure/Makefiles pass -force_cpusubtype_ALL to the
# linker on Darwin — an option the modern Xcode linker (ld-prime, Xcode 15+)
# removed, so every test-program link dies with "ld: unknown options".
# The flag was only ever meaningful for PowerPC fat binaries; strip it.
preconfigure_libvorbis() {
    local src="$1"
    find "$src" \( -name configure -o -name 'Makefile.in' -o -name 'Makefile.am' \) -type f \
        -exec sed -i '' 's/-force_cpusubtype_ALL//g' {} +
}

build_libvorbis() {
    stamp_done libvorbis && { ok "libvorbis (cached)"; return; }
    local v=1.3.7 a="libvorbis-1.3.7.tar.gz"
    dl "https://downloads.xiph.org/releases/vorbis/${a}" "$a"
    autotools_universal "libvorbis" "$a" \
        --disable-static --enable-shared \
        --disable-dependency-tracking --disable-oggtest
    stamp_ok libvorbis
    ok "libvorbis $v"
}

build_libsamplerate() {
    stamp_done libsamplerate && { ok "libsamplerate (cached)"; return; }
    local v=0.2.2 a="libsamplerate-0.2.2.tar.xz"
    dl "https://github.com/libsndfile/libsamplerate/releases/download/${v}/${a}" "$a"
    cmake_universal "libsamplerate" "$a" "" \
        -DBUILD_TESTING=OFF \
        -DLIBSAMPLERATE_EXAMPLES=OFF \
        -DLIBSAMPLERATE_INSTALL_PKGCONFIG=ON
    stamp_ok libsamplerate
    ok "libsamplerate $v"
}

build_mt32emu() {
    stamp_done mt32emu && { ok "mt32emu (cached)"; return; }
    local v=2.7.3
    local a="munt-libmt32emu_${v//./_}.tar.gz"
    dl "https://github.com/munt/munt/archive/refs/tags/libmt32emu_${v//./_}.tar.gz" "$a"
    cmake_universal "mt32emu" "$a" "mt32emu" \
        -Dlibmt32emu_SHARED=ON
    stamp_ok mt32emu
    ok "mt32emu $v"
}

build_sdl2() {
    stamp_done sdl2 && { ok "SDL2 (cached)"; return; }
    local v=2.30.10 a="SDL2-2.30.10.tar.gz"
    dl "https://github.com/libsdl-org/SDL/releases/download/release-${v}/${a}" "$a"

    # SDL2 has arch-specific SIMD knobs (SDL_ARMNEON for arm64; SDL_SSE*
    # for x86_64) that must be toggled per-arch slice. Inlined here rather
    # than going through cmake_universal so we can hand each arch its own
    # flags.
    local -a stages=()
    for arch in "${ARCHS[@]}"; do
        local arch_src="$BUILD/sdl2-${arch}"
        extract_stripped_to "$a" "$arch_src"

        local stage="$BUILD/.stage-sdl2-${arch}"
        rm -rf "$stage"; mkdir -p "$stage"
        stages+=("$stage")

        local -a simd_args=()
        case "$arch" in
            arm64)
                simd_args=(
                    -DSDL_ARMNEON=ON
                    -DSDL_ARMSIMD=ON
                    -DSDL_SSE=OFF -DSDL_SSE2=OFF -DSDL_SSE3=OFF -DSDL_SSEMATH=OFF
                    -DSDL_MMX=OFF -DSDL_3DNOW=OFF
                )
                ;;
            x86_64)
                simd_args=(
                    -DSDL_ARMNEON=OFF -DSDL_ARMSIMD=OFF
                    -DSDL_SSE=ON -DSDL_SSE2=ON -DSDL_SSE3=ON -DSDL_SSEMATH=ON
                    -DSDL_MMX=ON
                )
                ;;
        esac

        pushd "$arch_src" >/dev/null
        rm -rf _b && mkdir _b && cd _b
        cmake .. \
            -DCMAKE_INSTALL_PREFIX="$PREFIX" \
            -DCMAKE_PREFIX_PATH="$PREFIX" \
            -DCMAKE_IGNORE_PREFIX_PATH="/opt/local;/usr/local;/opt/homebrew" \
            -DCMAKE_IGNORE_PATH="/opt/local/bin;/opt/local/lib;/opt/local/include;/usr/local/bin;/usr/local/lib;/usr/local/include;/opt/homebrew/bin;/opt/homebrew/lib;/opt/homebrew/include" \
            -DCMAKE_FIND_FRAMEWORK=LAST \
            -DCMAKE_FIND_APPBUNDLE=LAST \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_OSX_ARCHITECTURES="$arch" \
            -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOS_MIN}" \
            -DBUILD_SHARED_LIBS=ON \
            -DSDL_SHARED=ON -DSDL_STATIC=OFF \
            -DSDL_TEST=OFF -DSDL_TESTS=OFF \
            -DSDL_RENDER_METAL=ON \
            -DSDL_VIDEO_METAL=ON \
            -DSDL_ASSEMBLY=ON \
            "${simd_args[@]}"
        make -j"$NPROC"
        make install DESTDIR="$stage"
        popd >/dev/null
    done

    merge_arch_stages "${stages[@]}"
    stamp_ok sdl2
    ok "SDL2 $v"
}

build_sdl12_compat() {
    stamp_done sdl12-compat && { ok "sdl12-compat (cached)"; return; }
    local v=1.2.76 a="sdl12-compat-release-1.2.76.tar.gz"
    dl "https://github.com/libsdl-org/sdl12-compat/archive/refs/tags/release-${v}.tar.gz" "$a"
    cmake_universal "sdl12-compat" "$a" "" \
        -DSDL12TESTS=OFF \
        -DSDL12DEVEL=ON
    if [[ -f "$PREFIX/bin/sdl-config" ]]; then
        chmod +x "$PREFIX/bin/sdl-config"
    fi
    stamp_ok sdl12-compat
    ok "sdl12-compat $v"
}

build_sdl_net() {
    stamp_done sdl-net && { ok "SDL_net (cached)"; return; }
    local v=1.2.8 a="SDL_net-1.2.8.tar.gz"
    dl "https://www.libsdl.org/projects/SDL_net/release/${a}" "$a"
    autotools_universal "sdl-net" "$a" \
        --disable-static --enable-shared \
        --disable-dependency-tracking \
        --disable-sdltest \
        --with-sdl-prefix="$PREFIX"
    stamp_ok sdl-net
    ok "SDL_net $v"
}

# SDL_sound 1.0.3 — required by dosbox-gridc for CDROM audio decoding.
# Patches:
#   - config.sub/config.guess need to be refreshed for aarch64-apple-darwin
#     (handled automatically by autotools_universal → refresh_autotools_helpers).
#   - SDL_sound 1.0.3's configure.in runs `libtoolize --force` directly in
#     autogen.sh, which fails under modern libtool if the project doesn't
#     already have the m4 macros it needs. We regenerate via autoreconf -fiv
#     after extract (consistent with the flatpak manifest).
#   - SDL_sound's configure tries to detect SMPEG / FLAC / physfs and silently
#     disables decoders if missing. For DOSBox CDROM audio we need MP3/OGG/WAV
#     support at minimum, which are built-in. We pass --disable-* for every
#     optional external decoder to keep the build deterministic (no host lib
#     sniffing).
build_sdl_sound() {
    stamp_done sdl-sound && { ok "SDL_sound (cached)"; return; }
    local v=1.0.3 a="SDL_sound-1.0.3.tar.gz"
    dl "https://icculus.org/SDL_sound/downloads/${a}" "$a"

    local -a stages=()
    for arch in "${ARCHS[@]}"; do
        local arch_src="$BUILD/sdl-sound-${arch}"
        extract_stripped_to "$a" "$arch_src"
        refresh_autotools_helpers "$arch_src"

        local stage="$BUILD/.stage-sdl-sound-${arch}"
        rm -rf "$stage"; mkdir -p "$stage"
        stages+=("$stage")

        local triplet
        triplet="$(host_triplet_for "$arch")"

        pushd "$arch_src" >/dev/null
        # SDL_sound 1.0.3 ships pre-generated configure but the bundled
        # config.sub is from ~2007 and doesn't know aarch64. refresh_autotools
        # already overlaid new copies; just re-run autoreconf to pick them up
        # and regenerate ltmain.sh against our modern libtool.
        AUTOMAKE="automake --foreign" autoreconf -fiv 2>/dev/null || \
            AUTOMAKE="automake --foreign" autoreconf -fiv

        CC="clang" CXX="clang++" \
        CPPFLAGS="-I${PREFIX}/include" \
        CFLAGS="-arch $arch ${UVER} -O2 ${COMPAT_CFLAGS} -I${PREFIX}/include" \
        CXXFLAGS="-arch $arch ${UVER} -O2 -I${PREFIX}/include" \
        LDFLAGS="-arch $arch ${UVER} -L${PREFIX}/lib -Wl,-rpath,${PREFIX}/lib" \
        ./configure \
            --prefix="$PREFIX" \
            --host="$triplet" \
            --build="$triplet" \
            --disable-static --enable-shared \
            --disable-dependency-tracking \
            --disable-sdltest \
            --with-sdl-prefix="$PREFIX" \
            --disable-smpeg \
            --disable-flac \
            --disable-physfs \
            --disable-speex \
            --disable-modplug \
            --disable-mikmod
        make -j"$NPROC"
        make install DESTDIR="$stage"
        popd >/dev/null
    done

    merge_arch_stages "${stages[@]}"
    stamp_ok sdl-sound
    ok "SDL_sound $v"
}

build_libffi() {
    stamp_done libffi && { ok "libffi (cached)"; return; }
    # 3.4.8+ required: 3.4.6's aarch64 sysv.S hits "invalid CFI advance_loc
    # expression" with the newer Xcode assembler (clang 17+, libffi #852).
    local v=3.4.8 a="libffi-3.4.8.tar.gz"
    dl "https://github.com/libffi/libffi/releases/download/v${v}/${a}" "$a"
    autotools_universal "libffi" "$a" \
        --disable-static --enable-shared \
        --disable-dependency-tracking --disable-docs
    stamp_ok libffi
    ok "libffi $v"
}

build_pcre2() {
    stamp_done pcre2 && { ok "pcre2 (cached)"; return; }
    local v=10.43 a="pcre2-10.43.tar.gz"
    dl "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${v}/${a}" "$a"
    autotools_universal "pcre2" "$a" \
        --disable-static --enable-shared \
        --disable-dependency-tracking \
        --enable-pcre2-8 --enable-pcre2-16 --enable-pcre2-32 \
        --enable-unicode
    stamp_ok pcre2
    ok "pcre2 $v"
}

build_glib() {
    stamp_done glib && { ok "glib (cached)"; return; }
    ensure_tool meson
    ensure_tool ninja
    local v=2.78.6 a="glib-2.78.6.tar.xz"
    dl "https://download.gnome.org/sources/glib/2.78/${a}" "$a"
    # Note: glib 2.78 does not expose `introspection`, `man`, or `man-pages`
    # meson options — introspection is built by the separate
    # gobject-introspection project (auto-skipped when g-ir-scanner is
    # absent, which it is on the build VM), and man page generation is
    # auto-skipped when xsltproc is absent. Keep only options known to
    # exist in 2.78.
    meson_universal "glib" "$a" \
        -Dtests=false \
        -Dnls=disabled \
        -Dselinux=disabled \
        -Dlibmount=disabled \
        -Dxattr=false
    stamp_ok glib
    ok "glib $v"
}

build_fluidsynth() {
    stamp_done fluidsynth && { ok "fluidsynth (cached)"; return; }
    local v=2.3.5 a="fluidsynth-2.3.5.tar.gz"
    dl "https://github.com/FluidSynth/fluidsynth/archive/refs/tags/v${v}.tar.gz" "$a"
    # enable-framework=OFF forces fluidsynth to install a plain
    # libfluidsynth.dylib into $PREFIX/lib instead of a
    # FluidSynth.framework under $PREFIX/Library/Frameworks. The framework
    # layout would require special-casing in bundle_dylibs.py and would
    # skip our universal-verification pass (which scans $PREFIX/lib only).
    cmake_universal "fluidsynth" "$a" "" \
        -Denable-framework=OFF \
        -Denable-sdl2=OFF \
        -Denable-libsndfile=OFF \
        -Denable-readline=OFF \
        -Denable-alsa=OFF \
        -Denable-pulseaudio=OFF \
        -Denable-jack=OFF \
        -Denable-portaudio=OFF \
        -Denable-coreaudio=ON \
        -Denable-coremidi=ON \
        -Denable-dbus=OFF \
        -Denable-libinstpatch=OFF \
        -Denable-lash=OFF \
        -Denable-midishare=OFF \
        -Denable-opensles=OFF \
        -Denable-oboe=OFF \
        -Denable-oss=OFF \
        -Denable-threads=ON \
        -Denable-ipv6=ON \
        -Denable-network=ON \
        -Denable-dsound=OFF \
        -Denable-waveout=OFF \
        -Denable-winmidi=OFF
    stamp_ok fluidsynth
    ok "fluidsynth $v"
}

# SDL2_net — required by dosbox-x (AC_CHECK_LIB(SDL2_net, SDLNet_Init)).
# Note: this is a different library from SDL_net 1.x (which gridc uses).
# DOSBox-X's configure probes for SDL2_net first, then falls back to SDL_net.
# We build both — SDL2_net for dosbox-x, SDL_net 1.x for gridc.
#
# SDL2_net 2.2.0 dropped autotools; CMake is the only supported build system.
build_sdl2_net() {
    stamp_done sdl2-net && { ok "SDL2_net (cached)"; return; }
    local v=2.2.0 a="SDL2_net-2.2.0.tar.gz"
    dl "https://github.com/libsdl-org/SDL_net/releases/download/release-${v}/${a}" "$a"
    cmake_universal "sdl2-net" "$a" "" \
        -DSDL2NET_SAMPLES=OFF \
        -DSDL2NET_TEST=OFF \
        -DSDL2NET_INSTALL=ON \
        -DBUILD_SHARED_LIBS=ON
    stamp_ok sdl2-net
    ok "SDL2_net $v"
}

# libslirp — user-mode TCP/IP stack. Used by dosbox-x for NE2000 NAT
# networking (the `slirp` backend). We build it the same way the flatpak
# manifest does, via meson + ninja.
build_libslirp() {
    stamp_done libslirp && { ok "libslirp (cached)"; return; }
    local v=4.9.1 a="libslirp-v4.9.1.tar.gz"
    dl "https://gitlab.freedesktop.org/slirp/libslirp/-/archive/v${v}/libslirp-v${v}.tar.gz" "$a"
    # libslirp depends on glib (GLib), which we've already built as a dep
    # of fluidsynth. Meson finds glib via pkg-config from PKG_CONFIG_LIBDIR.
    meson_universal "libslirp" "$a"
    stamp_ok libslirp
    ok "libslirp $v"
}

# freetype — TrueType font rendering. Used by dosbox-x for on-screen
# Unicode / CJK / PC-98 glyph rendering. Built universal so the single
# .app works on both slices.
build_freetype() {
    stamp_done freetype && { ok "freetype (cached)"; return; }
    local v=2.13.2 a="freetype-2.13.2.tar.xz"
    dl "https://downloads.sourceforge.net/project/freetype/freetype2/${v}/${a}" "$a"
    autotools_universal "freetype" "$a" \
        --disable-static --enable-shared \
        --disable-dependency-tracking \
        --without-harfbuzz --without-brotli --without-bzip2
    stamp_ok freetype
    ok "freetype $v"
}

# FFmpeg — used by DOSBox-X for high-quality video capture (H.264/MPEG
# AVI/MP4). DOSBox-X's configure probes for libavcodec/libavformat/
# libavutil/libswscale/libswresample via pkg-config and enables the
# "capture" feature if all are present. Without FFmpeg the built-in ZMBV
# codec still works but limits users to .avi-ZMBV captures only.
#
# Why 5.1.4 (instead of 6.x or 4.4): the 5.1 line is the most recent
# stable FFmpeg that all the DOSBox-X versions we're building compile
# against without patching. v6.x drops APIs that older capture code
# still uses; v4.4 is out of support.
#
# Build notes:
#   - FFmpeg's configure is hand-rolled (not autoconf). It uses $cc
#     standalone to probe features, so per-arch `-arch $arch` goes on
#     --cc / --cxx directly, NOT via --extra-cflags alone.
#   - --enable-cross-compile skips configure-time execution of compiled
#     test programs — required because the arm64-slice tests can't run
#     on an x86_64 host and vice-versa.
#   - --disable-x86asm falls back to C kernels on the x86_64 slice if
#     nasm/yasm aren't installed on the build host. The x86_64 binary
#     still functions; video encoding just runs slower. arm64 uses
#     inline NEON intrinsics and doesn't need an external assembler.
#   - --disable-network strips RTSP/HTTP/etc. protocols we don't use,
#     shrinking the dylibs by ~1.5 MB per arch.
#   - --disable-programs / --disable-doc drop the ffmpeg/ffprobe CLIs
#     and manpages (DOSBox-X only uses the libraries).
build_ffmpeg() {
    stamp_done ffmpeg && { ok "ffmpeg (cached)"; return; }
    local v=5.1.4 a="ffmpeg-5.1.4.tar.xz"
    dl "https://ffmpeg.org/releases/${a}" "$a"

    local x86asm_flag=""
    if ! command -v nasm >/dev/null 2>&1 \
       && ! command -v yasm >/dev/null 2>&1; then
        x86asm_flag="--disable-x86asm"
        warn "Neither nasm nor yasm found — x86_64 ffmpeg slice will build without SIMD."
        warn "  (arm64 slice uses NEON intrinsics and is unaffected; this only"
        warn "   matters for the optional DOSBox-X video-capture feature.)"
    fi

    local -a stages=()
    for arch in "${ARCHS[@]}"; do
        local arch_src="$BUILD/ffmpeg-${arch}"
        extract_stripped_to "$a" "$arch_src"

        local stage="$BUILD/.stage-ffmpeg-${arch}"
        rm -rf "$stage"; mkdir -p "$stage"
        stages+=("$stage")

        local ff_arch
        case "$arch" in
            arm64)  ff_arch=arm64 ;;
            x86_64) ff_arch=x86_64 ;;
        esac

        pushd "$arch_src" >/dev/null
        # Use an array so --disable-x86asm is either a single extra arg
        # or nothing — passing empty-string to configure is a parse error.
        local -a extra_flags=()
        [[ -n "$x86asm_flag" ]] && extra_flags+=("$x86asm_flag")

        ./configure \
            --prefix="$PREFIX" \
            --arch="$ff_arch" \
            --target-os=darwin \
            --enable-cross-compile \
            --cc="clang -arch $arch ${UVER}" \
            --cxx="clang++ -arch $arch ${UVER}" \
            --extra-cflags="-I${PREFIX}/include -O2" \
            --extra-cxxflags="-I${PREFIX}/include -O2" \
            --extra-ldflags="-L${PREFIX}/lib -Wl,-rpath,${PREFIX}/lib" \
            --enable-shared --disable-static \
            --enable-pic \
            --enable-pthreads \
            --enable-avcodec --enable-avformat --enable-avutil \
            --enable-swscale --enable-swresample \
            --disable-programs \
            --disable-doc \
            --disable-debug \
            --disable-network \
            --disable-postproc \
            --disable-avfilter \
            --disable-avdevice \
            --disable-sdl2 \
            --disable-vulkan \
            --disable-videotoolbox \
            ${extra_flags[@]+"${extra_flags[@]}"}
        make -j"$NPROC"
        make install DESTDIR="$stage"
        popd >/dev/null
    done

    merge_arch_stages "${stages[@]}"
    stamp_ok ffmpeg
    ok "ffmpeg $v"
}

install_openglide_headers() {
    stamp_done openglide-headers && { ok "OpenGlide headers (cached)"; return; }
    local clone="$BUILD/openglide"
    if [[ ! -d "$clone/.git" ]]; then
        rm -rf "$clone"
        git clone --depth=1 https://github.com/voyageur/openglide.git "$clone"
    fi
    mkdir -p "$PREFIX/include"
    cp "$clone"/sdk2*.h "$PREFIX/include/"
    stamp_ok openglide-headers
    ok "OpenGlide SDK headers"
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

# Everything DOSBox ECE needs. (Default set.)
declare -a ECE_BUILDERS=(
    zlib
    libpng
    libogg
    libvorbis
    libsamplerate
    mt32emu
    sdl2
    sdl12-compat
    sdl-net
    libffi
    pcre2
    glib
    fluidsynth
    openglide-headers
)

# Extras only needed by the gridc / gunstick / DOSBox-X pipelines.
# Built with `./build_deps.sh --all` (or individually by name).
declare -a EXTRA_BUILDERS=(
    sdl2-net
    sdl-sound
    libslirp
    freetype
    ffmpeg
)

declare -a ALL_BUILDERS=("${ECE_BUILDERS[@]}" "${EXTRA_BUILDERS[@]}")

clean_all() {
    msg "Removing $PREFIX and $BUILD (cache preserved in $CACHE)"
    rm -rf "$PREFIX" "$BUILD"
}

usage() {
    cat <<EOF
Usage: $0 [options] [dep-name...]

Options:
  --clean           Wipe prefix and build dir (cache preserved), then build.
  --all             Also build the gridc/dosbox-x extras (SDL2_net, SDL_sound,
                    libslirp, freetype, ffmpeg). Default is the ECE set only.
  --list            List all deps and exit.
  -h, --help        Show this help.

With no arguments, builds the ECE dependency set (resuming via stamp files).
With dep-name arguments, force-rebuilds only those deps (clears their stamp).
EOF
}

main() {
    local rebuild_specific=()
    local build_set="ece"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --clean) clean_all; shift ;;
            --all) build_set="all"; shift ;;
            --list) printf "%s\n" "${ALL_BUILDERS[@]}"; exit 0 ;;
            -h|--help) usage; exit 0 ;;
            -*) die "Unknown option: $1" ;;
            *)  rebuild_specific+=("$1"); shift ;;
        esac
    done

    local -a builders=("${ECE_BUILDERS[@]}")
    if [[ "$build_set" == "all" ]]; then
        builders=("${ALL_BUILDERS[@]}")
    fi

    check_build_tools
    # Pre-create lib/include/bin so the very first dep doesn't trip
    # `ld: warning: directory not found for option '-L…/deps-prefix/lib'`.
    mkdir -p "$PREFIX" "$CACHE" "$BUILD" \
             "$PREFIX/.stamps" "$PREFIX/lib" "$PREFIX/include" "$PREFIX/bin"

    # Fetch fresh config.sub/config.guess once per run — needed for old
    # autotools projects (SDL_net in particular) to accept aarch64-apple-darwin.
    msg "Fetching fresh config.sub / config.guess..."
    download_autotools_helpers

    for n in ${rebuild_specific[@]+"${rebuild_specific[@]}"}; do
        rm -f "$PREFIX/.stamps/$n"
    done

    echo "=== DOSBox ECE dependency build ==="
    echo "   Prefix:    $PREFIX"
    echo "   Archs:     ${ARCHS[*]}  (built separately per-arch, then lipo'd)"
    echo "   Host arch: $HOST_ARCH"
    echo "   Target:    macOS ${MACOS_MIN}"
    echo "   SDKROOT:   ${SDKROOT:-<auto>}"
    echo

    if [[ ${#rebuild_specific[@]} -gt 0 ]]; then
        builders=("${ALL_BUILDERS[@]}")
    fi
    for name in "${builders[@]}"; do
        if [[ ${#rebuild_specific[@]} -gt 0 ]]; then
            local keep=0
            for s in "${rebuild_specific[@]}"; do
                [[ "$s" == "$name" ]] && keep=1
            done
            [[ $keep -eq 0 ]] && continue
        fi
        local fn="build_${name//-/_}"
        if [[ "$name" == "openglide-headers" ]]; then fn="install_openglide_headers"; fi
        if declare -F "$fn" >/dev/null; then
            "$fn"
        else
            warn "No builder for '$name' (function $fn missing)"
        fi
    done

    echo
    msg "Verifying all installed dylibs are universal..."
    verify_prefix_universal

    echo
    ok "Dependencies ready at: $PREFIX"
    echo
    echo "Next steps:"
    echo "  ./build_all_ece.sh        # build all three ECE versions"
    echo "  ./package_macos.sh <dir>  # package an ECE build as .app + DMG"
}

main "$@"
