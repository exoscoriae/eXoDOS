# shellcheck shell=bash
# ============================================================================
# scripts/lib.sh — shared helpers: logging, downloading, per-arch build wrappers
# for autotools / meson / cmake, and the lipo merge step.
#
# Build model
# -----------
#   For each architecture in ARCHS we build EVERY library directly into the
#   live $PREFIX (configure --prefix=$PREFIX, plain `make install`), exactly as
#   a normal non-universal build would — so each library finds the headers and
#   libraries of the ones built before it at their natural locations. When an
#   arch finishes, $PREFIX is snapshotted to $STAGE_DIR/prefix-<arch>; the
#   prefix is then reset and the next arch is built the same way.
#
#   Because every snapshot was produced at the identical literal $PREFIX path,
#   all install-names, .pc prefixes and headers already match. merge_arch()
#   therefore just lipo's the matching Mach-O files from the snapshots into the
#   final universal $PREFIX — no install_name_tool or .pc fixups required.
#
#   Cross compiling: whichever arch differs from `uname -m` is built with
#   --host=<triple> (autotools), a generated meson cross file, or
#   -DCMAKE_OSX_ARCHITECTURES (cmake).  Test-binary execution is suppressed.
# ============================================================================

set -euo pipefail

# --- pretty logging ----------------------------------------------------------
# All log output goes to STDERR so that functions can safely `echo` a result
# value on STDOUT for capture via $( ... ) without log lines contaminating it.
_c() { printf '\033[%sm' "$1" >&2; }
log()   { _c '1;34'; printf '>>> %s\n' "$*" >&2; _c 0; }
ok()    { _c '1;32'; printf '    %s\n' "$*" >&2; _c 0; }
warn()  { _c '1;33'; printf '!!! %s\n' "$*" >&2; _c 0; }
# die() must abort the ENTIRE build even when called from inside a $(...)
# command-substitution subshell (e.g. a failed download in _prep). A plain
# `exit 1` there would only end the subshell and could be swallowed by a
# caller's `|| return 0`, silently skipping a dependency. Signalling the main
# shell guarantees the whole build stops. MAIN_PID is exported by build.sh.
die()   { _c '1;31'; printf 'XXX %s\n' "$*" >&2; _c 0; kill -TERM "${MAIN_PID:-$$}" 2>/dev/null; exit 1; }

NATIVE_ARCH="$(uname -m)"   # arm64 or x86_64

# ----------------------------------------------------------------------------
# scrub_env — neutralize every inherited environment variable that could inject
# a foreign (e.g. Homebrew/MacPorts) header, library, or framework search path
# into the compiler/linker, independent of PATH.  Called at the top of every
# build environment setup.  This is what stops a build from silently picking up
# an incompatible library that merely happens to exist on the system.
# ----------------------------------------------------------------------------
scrub_env() {
  unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH \
        OBJCPLUS_INCLUDE_PATH INCLUDE_PATH \
        LIBRARY_PATH DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH \
        DYLD_FRAMEWORK_PATH DYLD_FALLBACK_FRAMEWORK_PATH FRAMEWORK_PATH \
        CMAKE_PREFIX_PATH CMAKE_FRAMEWORK_PATH CMAKE_LIBRARY_PATH CMAKE_INCLUDE_PATH \
        PKG_CONFIG_PATH PKG_CONFIG_LIBDIR ACLOCAL ACLOCAL_PATH \
        CFLAGS CXXFLAGS CPPFLAGS LDFLAGS OBJCFLAGS \
        LD_LIBRARY_PATH GETTEXT_DIR BOOST_ROOT 2>/dev/null || true
  # Force our own SDK choice; ignore any SDKROOT the caller's shell exported.
  unset SDKROOT
}

# Resolve the active SDK once.
detect_sdk() {
  SDKROOT="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null)" \
    || die "Xcode Command Line Tools not found. Run: xcode-select --install"
  export SDKROOT
  local sdkver
  sdkver="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo '?')"
  ok "Using macOS SDK $sdkver at $SDKROOT (deployment target $MACOSX_DEPLOYMENT_TARGET)"
}

# Map an arch to an autotools host triple.
arch_triple() {
  case "$1" in
    arm64)  echo "aarch64-apple-darwin" ;;
    x86_64) echo "x86_64-apple-darwin" ;;
    *) die "unknown arch $1" ;;
  esac
}

# ----------------------------------------------------------------------------
# set_arch_env <arch> — export the toolchain environment for one arch build.
# Pins PATH (build tools + system only, no Brew/MacPorts) and PKG_CONFIG_LIBDIR
# to our prefix exclusively so nothing leaks in from /usr/local or /opt.
# ----------------------------------------------------------------------------
set_arch_env() {
  ARCH="$1"
  scrub_env                 # drop any inherited foreign search paths
  detect_sdk                # re-establish OUR sdk (scrub_env cleared SDKROOT)
  local archflag="-arch $ARCH"
  COMMON_FLAGS="$archflag -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET} -isysroot $SDKROOT"

  export CC="clang"
  export CXX="clang++"
  export OBJC="clang"
  # clang >= 17 makes implicit function declarations a hard error by default;
  # older C release tarballs (e.g. libvpx 1.15) rely on the legacy warning
  # behavior. Downgrade it so such code still builds on new toolchains.
  local COMPAT_C="-Wno-implicit-function-declaration -Wno-implicit-int"
  export CFLAGS="$COMMON_FLAGS -O2 $COMPAT_C"
  export CXXFLAGS="$COMMON_FLAGS -O2 -stdlib=libc++"
  export OBJCFLAGS="$COMMON_FLAGS -O2 $COMPAT_C"
  export LDFLAGS="$archflag -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET} -isysroot $SDKROOT -Wl,-headerpad_max_install_names -L$PREFIX/lib"
  export CPPFLAGS="-isysroot $SDKROOT -I$PREFIX/include"
  # Each architecture is built DIRECTLY into the live $PREFIX (then snapshotted
  # and lipo-merged), so a dependency built earlier in this arch pass is found
  # at its normal location by the next one — exactly like a non-universal build.

  # Sanitized, deterministic PATH: our build tools first, then base system.
  export PATH="$TOOLS_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin"

  # pkg-config: ONLY our prefix. LIBDIR (not PATH) wipes the default search dirs.
  export PKG_CONFIG="$TOOLS_PREFIX/bin/pkgconf"
  export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
  export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"

  # Include the host toolchain's aclocal dir so autoreconf (used by zimg) finds
  # libtool.m4 / pkg.m4 etc., plus our prefix's own macros.
  export ACLOCAL_PATH="$PREFIX/share/aclocal:$TOOLS_PREFIX/share/aclocal"
}

# Per-arch snapshot of the fully-built $PREFIX (all paths reference $PREFIX
# literally, so merging is a pure lipo with no install-name/.pc fixups).
arch_snapshot_dir() { echo "$STAGE_DIR/prefix-$1"; }

# Is the given arch different from the machine we're running on?
is_cross() { [ "$1" != "$NATIVE_ARCH" ]; }

# ----------------------------------------------------------------------------
# Source acquisition.
# ----------------------------------------------------------------------------
fetch() {            # fetch <url> [outfile]
  local url="$1" out="${2:-}"
  [ -n "$out" ] || out="$DL_DIR/$(basename "$url")"
  if [ -f "$out" ]; then ok "cached $(basename "$out")"; return 0; fi
  log "downloading $(basename "$out")"
  curl -fL --retry 3 --connect-timeout 30 -o "$out.part" "$url" \
    || die "download failed: $url"
  mv "$out.part" "$out"
}

# extract <tarball> -> echoes the resulting top-level source dir under $SRC_DIR
# The directory name is derived deterministically from the tarball's own top
# entry, so it is always correct regardless of how many sources coexist or
# whether this tarball was already extracted on a previous run.
extract() {
  local tb="$1" name top
  name="$(basename "$tb")"
  # First path component of the archive's first entry, e.g. "freetype-2.13.3".
  top="$(tar tf "$tb" 2>/dev/null | head -1 | cut -d/ -f1)"
  [ -n "$top" ] || die "could not read archive layout of $name"
  local dir="$SRC_DIR/$top"
  if [ ! -d "$dir" ]; then
    log "extracting $name"
    tar -xf "$tb" -C "$SRC_DIR"
  fi
  [ -d "$dir" ] || die "expected $dir after extracting $name"
  echo "$dir"
}

# git_src <url> <ref> <dirname> [--recursive]
git_src() {
  local url="$1" ref="$2" name="$3" rec="${4:-}"
  local dst="$SRC_DIR/$name"
  if [ ! -d "$dst/.git" ]; then
    log "cloning $name @ $ref"
    # Everything in this block goes to STDERR; `git clone --recursive` and
    # `git submodule update` print "checked out ..." lines to STDOUT, which
    # would otherwise contaminate the captured source-dir path below.
    {
      git clone --depth 1 --branch "$ref" $rec "$url" "$dst" \
        || git clone "$url" "$dst"   # fallback for refs that aren't tags/branches
      ( cd "$dst" && git checkout -q "$ref" 2>/dev/null || true )
      [ "$rec" = "--recursive" ] && \
        ( cd "$dst" && git submodule update --init --recursive --depth 1 --quiet )
    } >&2
  else
    ok "cached clone $name"
  fi
  echo "$dst"
}

# A per-(lib,arch) stamp so re-runs skip already-built pieces.
built_stamp() { echo "$STAGE_DIR/.built/$1.$ARCH"; }
is_built()    { [ -f "$(built_stamp "$1")" ]; }
mark_built()  { mkdir -p "$STAGE_DIR/.built"; touch "$(built_stamp "$1")"; }

# ----------------------------------------------------------------------------
# Build-system wrappers.  Each runs in the current $ARCH env, configures with
# --prefix=$PREFIX, and installs directly into $PREFIX (which is the live
# per-arch tree; build_all_deps snapshots and lipo-merges it afterwards).
# Extra configure args are passed through "$@".
# ----------------------------------------------------------------------------
run_autotools() {        # run_autotools <srcdir> [configure args...]
  local src="$1"; shift
  local host_args=()
  if is_cross "$ARCH"; then
    host_args+=( --host="$(arch_triple "$ARCH")" )
    export cross_compiling=yes
  fi
  ( cd "$src"
    # Autotools build in-source, so a previous (possibly different-arch) build
    # leaves object files here. `make` would reuse them for this arch, causing
    # "found architecture arm64, required architecture x86_64" link errors.
    # Wipe all build artifacts so each arch compiles from scratch.
    [ -f Makefile ] && make distclean >/dev/null 2>&1 || true
    find . \( -name '*.o' -o -name '*.lo' -o -name '*.a' \) -delete 2>/dev/null || true
    find . -type d -name '.libs' -exec rm -rf {} + 2>/dev/null || true
    [ -x ./configure ] || { [ -f ./autogen.sh ] && NOCONFIGURE=1 ./autogen.sh; }
    # Strip obsolete Darwin flags that a few old autotools projects inject and
    # that modern ld rejects — notably -force_cpusubtype_ALL (libvorbis 1.3.7,
    # libtheora 1.1.1). Harmless no-op when the flag isn't present.
    LC_ALL=C sed -i '' 's/-force_cpusubtype_ALL//g' configure 2>/dev/null || true
    find . -name 'Makefile.in' -exec sed -i '' 's/-force_cpusubtype_ALL//g' {} + 2>/dev/null || true
    ./configure --prefix="$PREFIX" --disable-dependency-tracking \
        "${host_args[@]}" "$@"
    make -j"$JOBS"
    # MAKE_INSTALL_VARS lets a recipe pass make variables to the install step
    # only (e.g. fontconfig's RUN_FC_CACHE_TEST=false to skip the host-wide
    # fc-cache scan that fails on modern macOS). Unquoted on purpose so each
    # "VAR=val" token becomes its own make argument.
    # shellcheck disable=SC2086
    make install ${MAKE_INSTALL_VARS:-}
  )
}

run_meson() {            # run_meson <srcdir> [meson setup args...]
  local src="$1"; shift
  local bdir="$src/_b.$ARCH"
  rm -rf "$bdir"
  local argflags=()
  if is_cross "$ARCH"; then
    # The cross file already carries the arch/min-version/isysroot flags.
    argflags=( --cross-file "$(meson_cross_file "$ARCH")" )
  else
    # Native build: inject our flags directly.
    argflags=( -Dc_args="$CFLAGS" -Dcpp_args="$CXXFLAGS"
               -Dc_link_args="$LDFLAGS" -Dcpp_link_args="$LDFLAGS" )
  fi
  meson setup "$bdir" "$src" \
      --prefix="$PREFIX" --buildtype=release --default-library=shared \
      "${argflags[@]}" "$@"
  meson compile -C "$bdir" -j "$JOBS"
  meson install -C "$bdir"
}

run_cmake() {            # run_cmake <srcdir> [cmake args...]
  local src="$1"; shift
  local bdir="$src/_b.$ARCH"
  rm -rf "$bdir"
  # When building the non-native slice, CMAKE_OSX_ARCHITECTURES sets the -arch
  # flag but CMAKE_SYSTEM_PROCESSOR still reflects the host. Projects that pick
  # x86-vs-arm code paths from CMAKE_SYSTEM_PROCESSOR (SVT-AV1's cpuinfo, aom,
  # x265) then build the wrong backend. Put CMake in cross mode with the real
  # target processor so those selections match the actual -arch.
  local xc=()
  if is_cross "$ARCH"; then
    xc=( -DCMAKE_SYSTEM_NAME=Darwin -DCMAKE_SYSTEM_PROCESSOR="$ARCH" )
  fi
  cmake -S "$src" -B "$bdir" -G "Ninja" \
      "${xc[@]}" \
      -DCMAKE_INSTALL_PREFIX="$PREFIX" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
      -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
      -DCMAKE_OSX_SYSROOT="$SDKROOT" \
      -DBUILD_SHARED_LIBS=ON \
      -DCMAKE_PREFIX_PATH="$PREFIX" \
      -DCMAKE_FIND_FRAMEWORK=LAST \
      -DCMAKE_FIND_APPBUNDLE=LAST \
      -DCMAKE_IGNORE_PREFIX_PATH="/usr/local;/opt/homebrew;/opt/local" \
      -DCMAKE_SYSTEM_IGNORE_PREFIX_PATH="/usr/local;/opt/homebrew;/opt/local" \
      -DCMAKE_MACOSX_RPATH=OFF \
      -DCMAKE_INSTALL_NAME_DIR="$PREFIX/lib" \
      -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-headerpad_max_install_names" \
      "$@"
  cmake --build "$bdir" -j "$JOBS"
  cmake --install "$bdir"
}

# Generate (once per arch) a meson cross file targeting <arch>.
meson_cross_file() {
  local arch="$1" cpu cpufam
  case "$arch" in
    arm64)  cpu="aarch64"; cpufam="aarch64" ;;
    x86_64) cpu="x86_64";  cpufam="x86_64" ;;
  esac
  local f="$WORK/meson-cross-$arch.ini"
  # Always (re)generate so flag changes take effect.
  cat > "$f" <<EOF
[binaries]
c = 'clang'
cpp = 'clang++'
objc = 'clang'
ar = 'ar'
strip = 'strip'
pkg-config = '$TOOLS_PREFIX/bin/pkgconf'

[built-in options]
c_args = ['-arch', '$arch', '-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET', '-isysroot', '$SDKROOT', '-Wno-implicit-function-declaration', '-Wno-implicit-int']
cpp_args = ['-arch', '$arch', '-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET', '-isysroot', '$SDKROOT']
objc_args = ['-arch', '$arch', '-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET', '-isysroot', '$SDKROOT', '-Wno-implicit-function-declaration']
c_link_args = ['-arch', '$arch', '-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET', '-isysroot', '$SDKROOT']
cpp_link_args = ['-arch', '$arch', '-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET', '-isysroot', '$SDKROOT']
objc_link_args = ['-arch', '$arch', '-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET', '-isysroot', '$SDKROOT']

[host_machine]
system = 'darwin'
cpu_family = '$cpufam'
cpu = '$cpu'
endian = 'little'
EOF
  echo "$f"
}

# ----------------------------------------------------------------------------
# merge_arch — lipo every per-arch snapshot into the final $PREFIX.
# Walks the first arch's snapshot; for each file:
#   symlink            -> recreated
#   Mach-O / archive   -> lipo -create across all arches that have it
#   anything else      -> copied (headers, .pc, scripts, data)
# Because every snapshot was built at the literal $PREFIX path, install-names,
# .pc prefixes and headers are already correct — no fixups required.
# Then strips libtool .la files (meson/pkg-config don't need them and their
# baked-in paths only cause grief).
# ----------------------------------------------------------------------------
merge_arch() {
  log "merging per-arch snapshots into universal prefix"
  local first base rel target a cand
  first="${ARCHS[0]}"
  base="$(arch_snapshot_dir "$first")"
  [ -d "$base" ] || die "no snapshot at $base — did the dep builds run?"
  rm -rf "$PREFIX"; mkdir -p "$PREFIX"

  # Recreate directory tree.
  ( cd "$base" && find . -type d -print0 ) | while IFS= read -r -d '' rel; do
    mkdir -p "$PREFIX/${rel#./}"
  done
  # Recreate symlinks verbatim.
  ( cd "$base" && find . -type l -print0 ) | while IFS= read -r -d '' rel; do
    cp -a "$base/${rel#./}" "$PREFIX/${rel#./}"
  done
  # Merge regular files; lipo Mach-O/archives across arches, copy everything else.
  ( cd "$base" && find . -type f -print0 ) | while IFS= read -r -d '' rel; do
    rel="${rel#./}"
    target="$PREFIX/$rel"
    if is_macho_or_archive "$base/$rel"; then
      local inputs=()
      for a in "${ARCHS[@]}"; do
        cand="$(arch_snapshot_dir "$a")/$rel"
        [ -f "$cand" ] && inputs+=( "$cand" )
      done
      if [ "${#inputs[@]}" -gt 1 ]; then
        lipo -create "${inputs[@]}" -output "$target" 2>/dev/null || cp -a "$base/$rel" "$target"
      else
        cp -a "$base/$rel" "$target"
      fi
    else
      cp -a "$base/$rel" "$target"
    fi
  done

  find "$PREFIX" -name '*.la' -delete 2>/dev/null || true
  normalize_install_names "$PREFIX/lib"
  ok "universal prefix assembled at $PREFIX"
}

# normalize_install_names — rewrite every dylib's id and inter-library refs from
# @rpath/<name> to an absolute <libdir>/<name>. Our model uses absolute install
# names everywhere (so configure RUN-tests, the mpv link, and dylib_unhell all
# work without rpaths). CMake libs are now built with absolute names directly;
# this is defense-in-depth that also repairs a prefix built before that fix.
normalize_install_names() {
  local libdir="${1:-$PREFIX/lib}" f id dep base fixed=0 failed=0
  [ -d "$libdir" ] || { warn "normalize: no lib dir at $libdir"; return 0; }
  log "normalizing install names -> absolute in $libdir"
  for f in "$libdir"/*.dylib; do
    [ -f "$f" ] || continue
    [ -L "$f" ] && continue
    id="$(otool -D "$f" 2>/dev/null | sed -n '2p')"
    case "$id" in
      @rpath/*)
        if install_name_tool -id "$libdir/${id#@rpath/}" "$f" 2>/dev/null; then
          fixed=$((fixed+1))
        else
          warn "could not fix id of $(basename "$f") (insufficient headerpad)"; failed=$((failed+1))
        fi ;;
    esac
    while IFS= read -r dep; do
      case "$dep" in
        @rpath/*) base="${dep#@rpath/}"
          if [ -e "$libdir/$base" ]; then
            install_name_tool -change "$dep" "$libdir/$base" "$f" 2>/dev/null \
              || { warn "could not rewrite $dep in $(basename "$f")"; failed=$((failed+1)); }
          fi ;;
      esac
    done < <(otool -L "$f" 2>/dev/null | awk 'NR>1{print $1}')
  done
  ok "normalize done (ids fixed: $fixed, failures: $failed)"
  [ "$failed" -eq 0 ] || warn "some libs lacked headerpad — rebuild those if issues persist"
}

is_macho_or_archive() {
  case "$1" in
    *.dylib|*.a|*.so) return 0 ;;
  esac
  # Executables without an extension: sniff the magic.
  file -b "$1" 2>/dev/null | grep -qE 'Mach-O|ar archive|current ar archive'
}

# Write a pkg-config .pc into the live prefix for libs that don't ship one
# (e.g. vanilla Lua, MuJS, the system-zlib shim).  Reads contents from stdin.
write_pc() {
  local name="$1"
  local dir="$PREFIX/lib/pkgconfig"
  mkdir -p "$dir"
  cat > "$dir/$name.pc"
}
