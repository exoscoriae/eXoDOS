#!/bin/bash
# ============================================================================
# build.sh -- DOSBox-X 0.82.20 portable universal (arm64 + x86_64) app bundle
#             for macOS 11.0 and later.
#
#   * No Homebrew, no MacPorts. Only Xcode Command Line Tools + network.
#   * Everything that can be statically linked IS statically linked
#     (SDL 1.x, SDL_net, zlib, libpng, FluidSynth 1.1.6, x264, FFmpeg 4.4).
#   * Only OS-provided libraries are linked dynamically
#     (/usr/lib + /System/Library frameworks, present on every fresh install).
#   * Dynamic CPU core works on Apple Silicon (mmap+MAP_JIT, 16K pages)
#     and on Intel (classic dynamic_x86 core).
#   * Output: dosbox-x-08220.app with executable named dosbox-x-08220.
#
# Usage:
#   ./build.sh                 full build
#   ./build.sh --no-ffmpeg     skip FFmpeg/x264 video-capture support
#   ./build.sh --resume        keep previous work dir (re-run after a fix)
#
# Run from the buildkit directory (needs ./patches, ./resources, ./verify-bundle.sh).
# ============================================================================

set -o pipefail

# ----------------------------------------------------------------------------
# configuration
# ----------------------------------------------------------------------------
KIT="$(cd "$(dirname "$0")" && pwd)"
WORK="${DOSBOX_WORK:-$HOME/dosbox-x-08220-work}"
DEPLOY=11.0
ARCHS="arm64 x86_64"
JOBS="$(sysctl -n hw.ncpu)"

APP_NAME="dosbox-x-08220"
DOSBOX_TAG="dosbox-x-v0.82.20"
SDL_FORK_TAG="dosbox-x-v2025.01.01"     # maintained SDL1.x fork w/ arm64+Big Sur fixes

AUTOCONF_V=2.69
AUTOMAKE_V=1.16.5
LIBTOOL_V=2.4.7
PKGCONF_V=1.9.5
NASM_V=2.16.03
GETTEXT_V=0.21.1                         # libintl (glib dependency)
LIBFFI_V=3.4.6                           # glib dependency (3.4.4's aarch64 .cfi asm breaks on newer Xcode assemblers)
GLIB_V=2.56.4                            # last autotools glib (FluidSynth dependency)
FLUIDSYNTH_V=1.1.6                       # v1.1+ needed for fluid_synth_sysex; requires glib
FFMPEG_V=4.4.4                           # last major with the 2019 avcodec API

WITH_FFMPEG=1
RESUME=0
for a in "$@"; do
  case "$a" in
    --no-ffmpeg) WITH_FFMPEG=0 ;;
    --resume)    RESUME=1 ;;
    *) echo "unknown option: $a"; exit 1 ;;
  esac
done

TOOLS="$WORK/tools"                      # host-only build tools, never shipped
SRC="$WORK/sources"
LOG="$WORK/logs"

triplet() { case "$1" in arm64) echo aarch64-apple-darwin20;; x86_64) echo x86_64-apple-darwin20;; esac; }

# hermetic PATH: system + our own tools only. Never /usr/local or /opt/homebrew.
export PATH="$TOOLS/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export MACOSX_DEPLOYMENT_TARGET="$DEPLOY"
unset PKG_CONFIG_PATH PKG_CONFIG_LIBDIR CPATH LIBRARY_PATH DYLD_LIBRARY_PATH
unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS LIBS OBJCXXFLAGS

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mERROR: %s\033[0m\n' "$*"; exit 1; }

run() { # run <logname> <cmd...>
  local lg="$LOG/$1.log"; shift
  echo "    [$*] > $lg"
  "$@" >>"$lg" 2>&1 || fail "command failed, see $lg (last 40 lines):$(printf '\n')$(tail -40 "$lg")"
}

fetch() { # fetch <url> [outfile]
  local url="$1" out="${2:-$SRC/$(basename "$1")}"
  [ -s "$out" ] && { echo "    cached: $(basename "$out")"; return 0; }
  echo "    downloading $(basename "$out")"
  curl -fL --retry 5 --retry-delay 3 -o "$out.part" "$url" || fail "download failed: $url"
  mv "$out.part" "$out"
  shasum -a 256 "$out" | tee -a "$WORK/downloads.sha256" >/dev/null
}

# ----------------------------------------------------------------------------
# stage 0: sanity checks
# ----------------------------------------------------------------------------
say "Stage 0: environment checks"
xcode-select -p >/dev/null 2>&1 || fail "Xcode Command Line Tools not installed. Run: xcode-select --install"
command -v cc >/dev/null   || fail "cc not found"
command -v git >/dev/null  || fail "git not found (comes with CLT)"
command -v python3 >/dev/null || fail "python3 not found (comes with CLT)"
SDKVER="$(xcrun --show-sdk-version 2>/dev/null | cut -d. -f1)"
[ -n "$SDKVER" ] && [ "$SDKVER" -ge 11 ] || fail "macOS SDK >= 11 required (found: $(xcrun --show-sdk-version 2>/dev/null))"
echo "    SDK $(xcrun --show-sdk-version), deployment target $DEPLOY, $JOBS jobs"
for d in /usr/local/include /opt/homebrew/include /opt/local/include; do
  [ -d "$d" ] && ls "$d" 2>/dev/null | grep -qE '^(png|SDL|fluid|zlib|libav)' && \
    echo "    NOTE: $d contains dev headers; PATH is sanitized and -I/usr/local/include is patched out, so they will NOT be used."
done

if [ "$RESUME" != "1" ] && [ -d "$WORK" ]; then
  fail "$WORK already exists. Use --resume to continue a previous run, or delete it."
fi
mkdir -p "$WORK" "$TOOLS" "$SRC" "$LOG" "$WORK/out"

# ----------------------------------------------------------------------------
# stage 1: host build tools (native arch only; NOT shipped in the bundle)
#   autoconf/automake/libtool : dosbox-x 0.82.20 does not commit ./configure
#   pkgconf                   : provides pkg.m4 + pkg-config (FluidSynth/FFmpeg)
#   nasm                      : x86_64 assembly for x264/FFmpeg
# ----------------------------------------------------------------------------
say "Stage 1: bootstrap build tools (autoconf/automake/libtool/pkgconf/nasm)"
build_tool() { # build_tool <name> <dirname> <url> [configure args...]
  local name="$1" dir="$2" url="$3"; shift 3
  [ -x "$TOOLS/bin/$name" ] && { echo "    have $name"; return 0; }
  local tb="$SRC/tool-$name-$(basename "$url")"
  fetch "$url" "$tb"
  rm -rf "$WORK/tmp-tool"; mkdir -p "$WORK/tmp-tool"
  run "tool-$name" tar -x -C "$WORK/tmp-tool" -f "$tb"
  ( cd "$WORK/tmp-tool/$dir" && \
    { [ -x ./configure ] || "$TOOLS/bin/autoreconf" -fi >>"$LOG/tool-$name.log" 2>&1; } && \
    ./configure --prefix="$TOOLS" "$@" >>"$LOG/tool-$name.log" 2>&1 && \
    make -j"$JOBS" >>"$LOG/tool-$name.log" 2>&1 && \
    make install >>"$LOG/tool-$name.log" 2>&1 ) || fail "building $name failed, see $LOG/tool-$name.log"
  echo "    built $name"
}
GNU=https://ftpmirror.gnu.org/gnu
build_tool autoconf "autoconf-$AUTOCONF_V" "$GNU/autoconf/autoconf-$AUTOCONF_V.tar.gz"
build_tool automake "automake-$AUTOMAKE_V" "$GNU/automake/automake-$AUTOMAKE_V.tar.gz"
build_tool libtool  "libtool-$LIBTOOL_V"   "$GNU/libtool/libtool-$LIBTOOL_V.tar.gz"
# official release tarball (ships a generated ./configure; the GitHub archive
# does not, and its configure.ac needs autoconf >= 2.71 which we don't build)
build_tool pkgconf  "pkgconf-$PKGCONF_V" \
  "https://distfiles.ariadne.space/pkgconf/pkgconf-$PKGCONF_V.tar.gz"
[ -e "$TOOLS/bin/pkg-config" ] || ln -s pkgconf "$TOOLS/bin/pkg-config"
build_tool nasm "nasm-$NASM_V" "https://www.nasm.us/pub/nasm/releasebuilds/$NASM_V/nasm-$NASM_V.tar.gz"
# pkgconf needs autoreconf if the github archive lacks ./configure:
if [ ! -x "$TOOLS/bin/pkgconf" ] && [ ! -e "$TOOLS/bin/pkg-config" ]; then
  fail "pkgconf did not install; check $LOG/tool-pkgconf.log"
fi

# arm64-aware config.guess/config.sub: automake 1.16.5 ships 2021-era copies.
NEW_CONFIG_GUESS="$TOOLS/share/automake-1.16/config.guess"
NEW_CONFIG_SUB="$TOOLS/share/automake-1.16/config.sub"
[ -f "$NEW_CONFIG_GUESS" ] && [ -f "$NEW_CONFIG_SUB" ] \
  || fail "config.guess/config.sub not found under $TOOLS/share/automake-1.16/"

# ----------------------------------------------------------------------------
# stage 2: fetch sources
# ----------------------------------------------------------------------------
say "Stage 2: sources"
fetch "https://github.com/joncampbell123/dosbox-x/archive/refs/tags/$DOSBOX_TAG.tar.gz" "$SRC/dosbox-x-0.82.20.tar.gz"
fetch "$GNU/gettext/gettext-$GETTEXT_V.tar.gz" "$SRC/gettext-$GETTEXT_V.tar.gz"
fetch "https://github.com/libffi/libffi/releases/download/v$LIBFFI_V/libffi-$LIBFFI_V.tar.gz" "$SRC/libffi-$LIBFFI_V.tar.gz"
fetch "https://download.gnome.org/sources/glib/${GLIB_V%.*}/glib-$GLIB_V.tar.xz" "$SRC/glib-$GLIB_V.tar.xz"
fetch "https://github.com/FluidSynth/fluidsynth/archive/refs/tags/v$FLUIDSYNTH_V.tar.gz" "$SRC/fluidsynth-$FLUIDSYNTH_V.tar.gz"
if [ "$WITH_FFMPEG" = "1" ]; then
  fetch "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_V.tar.gz" "$SRC/ffmpeg-$FFMPEG_V.tar.gz"
  fetch "https://code.videolan.org/videolan/x264/-/archive/stable/x264-stable.tar.gz" "$SRC/x264-stable.tar.gz"
fi

# maintained SDL1.x fork: sparse shallow clone (only vs/sdl + vs/sdlnet, a few MB)
if [ ! -d "$SRC/sdl-fork/vs/sdl" ]; then
  say "Fetching maintained SDL 1.x fork from $SDL_FORK_TAG (sparse clone)"
  rm -rf "$SRC/sdl-fork"
  if git clone --depth 1 --branch "$SDL_FORK_TAG" --filter=blob:none --sparse \
       https://github.com/joncampbell123/dosbox-x.git "$SRC/sdl-fork" >>"$LOG/sdl-fork.log" 2>&1; then
    ( cd "$SRC/sdl-fork" && git sparse-checkout set vs/sdl vs/sdlnet ) \
      >>"$LOG/sdl-fork.log" 2>&1 || fail "sparse checkout failed, see $LOG/sdl-fork.log"
  else
    echo "    sparse clone failed; falling back to full tag tarball (larger download)"
    fetch "https://github.com/joncampbell123/dosbox-x/archive/refs/tags/$SDL_FORK_TAG.tar.gz" "$SRC/sdl-fork.tar.gz"
    mkdir -p "$SRC/sdl-fork"
    run sdl-fork tar -x -C "$SRC/sdl-fork" --strip-components 1 -f "$SRC/sdl-fork.tar.gz" \
      "*/vs/sdl/*" "*/vs/sdlnet/*"
  fi
fi

# ----------------------------------------------------------------------------
# stage 3: prepare the patched dosbox-x tree (arch-independent, done once)
# ----------------------------------------------------------------------------
PREP="$WORK/src-prepared"
if [ ! -f "$PREP/.prepared" ]; then
  say "Stage 3: prepare + patch DOSBox-X 0.82.20 tree"
  rm -rf "$PREP"; mkdir -p "$PREP"
  run extract tar -x -C "$PREP" --strip-components 1 -f "$SRC/dosbox-x-0.82.20.tar.gz"

  echo "    swapping in maintained SDL 1.x / SDL_net fork"
  rm -rf "$PREP/vs2015/sdl" "$PREP/vs2015/sdlnet"
  cp -R "$SRC/sdl-fork/vs/sdl"    "$PREP/vs2015/sdl"
  cp -R "$SRC/sdl-fork/vs/sdlnet" "$PREP/vs2015/sdlnet"

  echo "    applying source patches (Apple Silicon JIT, MT-32 on arm64, hermetic includes)"
  python3 "$KIT/patches/apply_patches.py" "$PREP" || fail "patching failed"

  echo "    regenerating configure (autoreconf)"
  ( cd "$PREP" && "$TOOLS/bin/autoreconf" -fi ) >>"$LOG/autoreconf.log" 2>&1 \
    || fail "autoreconf failed, see $LOG/autoreconf.log"

  touch "$PREP/.prepared"
fi

# refresh config.guess/config.sub everywhere (arm64-apple-darwin awareness).
# Runs on every invocation: cheap, and heals trees prepared by older kit versions.
find "$PREP" -name config.guess -exec cp "$NEW_CONFIG_GUESS" {} \;
find "$PREP" -name config.sub   -exec cp "$NEW_CONFIG_SUB"   {} \;

# ----------------------------------------------------------------------------
# stage 4: per-arch external dependencies (static)
# ----------------------------------------------------------------------------
# permissive C flags for 2000s-era C code under modern clang
CWARN_C="-fcommon -Wno-implicit-function-declaration -Wno-error=implicit-function-declaration -Wno-error=int-conversion -Wno-error=incompatible-pointer-types -Wno-error=incompatible-function-pointer-types"

build_gettext() { # $1=arch  (libintl only, from gettext-runtime)
  local A="$1" T; T="$(triplet "$1")"
  local P="$WORK/deps/$A"
  [ -f "$P/lib/libintl.a" ] && { echo "    have libintl ($A)"; return; }
  say "gettext-runtime/libintl $GETTEXT_V ($A, static)"
  local B="$WORK/gettext-$A"; rm -rf "$B"; mkdir -p "$B"
  run "gettext-$A" tar -x -C "$B" --strip-components 1 -f "$SRC/gettext-$GETTEXT_V.tar.gz"
  find "$B" -name config.guess -exec cp "$NEW_CONFIG_GUESS" {} \; 2>/dev/null
  find "$B" -name config.sub   -exec cp "$NEW_CONFIG_SUB"   {} \; 2>/dev/null
  ( cd "$B/gettext-runtime" \
    && ./configure --host="$T" --prefix="$P" --enable-static --disable-shared \
         --disable-java --disable-csharp --disable-libasprintf --disable-c++ \
         CC="cc" CXX="c++" CFLAGS="-arch $A -mmacosx-version-min=$DEPLOY -O2 $CWARN_C" \
         LDFLAGS="-arch $A -mmacosx-version-min=$DEPLOY" \
    && make -j"$JOBS" && make install ) >>"$LOG/gettext-$A.log" 2>&1 \
    || fail "gettext/libintl ($A) failed, see $LOG/gettext-$A.log"
}

build_libffi() { # $1=arch
  local A="$1" T; T="$(triplet "$1")"
  local P="$WORK/deps/$A"
  [ -f "$P/lib/libffi.a" ] && { echo "    have libffi ($A)"; return; }
  say "libffi $LIBFFI_V ($A, static)"
  local B="$WORK/libffi-$A"; rm -rf "$B"; mkdir -p "$B"
  run "libffi-$A" tar -x -C "$B" --strip-components 1 -f "$SRC/libffi-$LIBFFI_V.tar.gz"
  # libffi_cv_as_cfi_pseudo_op=no: recent Xcode assemblers reject the CFI
  # *expressions* in libffi's aarch64 asm ("invalid CFI advance_loc expression").
  # Disabling the .cfi pseudo-ops compiles them out entirely (ffi_cfi.h macros
  # become no-ops); only debugger unwind info through FFI frames is lost.
  ( cd "$B" \
    && export gcc_cv_as_cfi_pseudo_op=no libffi_cv_as_cfi_pseudo_op=no \
    && ./configure --host="$T" --prefix="$P" --enable-static --disable-shared --disable-docs \
         CC="cc" CFLAGS="-arch $A -mmacosx-version-min=$DEPLOY -O2" \
         LDFLAGS="-arch $A -mmacosx-version-min=$DEPLOY" \
    && make -j"$JOBS" && make install ) >>"$LOG/libffi-$A.log" 2>&1 \
    || fail "libffi ($A) failed, see $LOG/libffi-$A.log"
  # some libffi versions install into $P/lib64 or leave headers in libffi-*/include
  [ -f "$P/lib/libffi.a" ] || cp "$B"/*/.libs/libffi.a "$P/lib/" 2>/dev/null || true
}

build_glib() { # $1=arch
  local A="$1" T; T="$(triplet "$1")"
  local P="$WORK/deps/$A"
  [ -f "$P/lib/libglib-2.0.a" ] && { echo "    have glib ($A)"; return; }
  say "glib $GLIB_V ($A, static; last autotools glib)"
  local B="$WORK/glib-$A"; rm -rf "$B"; mkdir -p "$B"
  run "glib-$A" tar -x -C "$B" --strip-components 1 -f "$SRC/glib-$GLIB_V.tar.xz"
  find "$B" -name config.guess -exec cp "$NEW_CONFIG_GUESS" {} \; 2>/dev/null
  find "$B" -name config.sub   -exec cp "$NEW_CONFIG_SUB"   {} \; 2>/dev/null
  # the tarball ships pre-built .gmo message catalogs; make them newer than the
  # .po sources so msgfmt (which we stub with /usr/bin/true) is never invoked
  find "$B/po" -name '*.gmo' -exec touch {} \; 2>/dev/null
  # cache variables for AC_TRY_RUN tests: the explicit --host triplet puts
  # configure in cross mode even for the native arch. Values are correct for
  # both arm64 and x86_64 macOS.
  ( cd "$B" \
    && PKG_CONFIG="$TOOLS/bin/pkg-config" PKG_CONFIG_PATH="$P/lib/pkgconfig" \
       MSGFMT=/usr/bin/true GMSGFMT=/usr/bin/true \
       XGETTEXT=/usr/bin/true MSGMERGE=/usr/bin/true \
       glib_cv_stack_grows=no \
       glib_cv_uscore=no \
       ac_cv_func_posix_getpwuid_r=yes \
       ac_cv_func_posix_getgrgid_r=yes \
       glib_cv_rtldglobal_broken=no \
       glib_cv_have_qsort_r=yes \
       ac_cv_func_vsnprintf_c99=yes \
       ac_cv_func_snprintf_c99=yes \
       ac_cv_func_printf_unix98=yes \
       glib_cv_compliant_posix_memalign=1 \
       glib_cv_long_long_format=ll \
       glib_cv_va_copy=yes \
       glib_cv___va_copy=yes \
       glib_cv_va_val_copy=yes \
       glib_cv_monotonic_clock=yes \
       ac_cv_func_mmap_fixed_mapped=yes \
       ./configure --host="$T" --prefix="$P" --enable-static --disable-shared \
         --with-pcre=internal --with-libiconv=native \
         --disable-selinux --disable-fam --disable-xattr --disable-libelf \
         --disable-libmount --disable-dtrace --disable-systemtap \
         --disable-coverage --disable-gtk-doc --disable-man \
         CC="cc" CFLAGS="-arch $A -mmacosx-version-min=$DEPLOY -O2 $CWARN_C" \
         CPPFLAGS="-I$P/include" \
         LDFLAGS="-arch $A -mmacosx-version-min=$DEPLOY -L$P/lib" \
         LIBS="-lintl -liconv" \
    && find . -name Makefile -exec sed -i '' -E 's/-Werror=[A-Za-z0-9=-]+//g' {} + \
    && make -j"$JOBS" && make install ) >>"$LOG/glib-$A.log" 2>&1 \
    || fail "glib ($A) failed, see $LOG/glib-$A.log -- last 50 lines:$(printf '\n')$(tail -50 "$LOG/glib-$A.log")"
}

build_fluidsynth() { # $1=arch
  local A="$1" T; T="$(triplet "$1")"
  local P="$WORK/deps/$A"
  [ -f "$P/lib/libfluidsynth.a" ] && { echo "    have fluidsynth ($A)"; return; }
  say "FluidSynth $FLUIDSYNTH_V ($A, static)"
  local B="$WORK/fluidsynth-$A"; rm -rf "$B"; mkdir -p "$B"
  run "fluidsynth-$A" tar -x -C "$B" --strip-components 1 -f "$SRC/fluidsynth-$FLUIDSYNTH_V.tar.gz"
  # the v1.1.6 repo nests the autotools project in a fluidsynth/ subdirectory
  local SD="$B"; [ -f "$B/configure.ac" ] || SD="$B/fluidsynth"
  [ -f "$SD/configure.ac" ] || fail "fluidsynth: configure.ac not found in archive layout"
  # the github archive lacks the gettext-family m4 macros configure.ac uses
  # (AC_LIB_PROG_LD_GNU lives in lib-ld.m4); borrow them from the gettext sources
  mkdir -p "$SD/m4"
  local GT="$WORK/gettext-$A"
  m4src=""
  [ -d "$GT" ] && m4src="$(find "$GT" -name lib-ld.m4 2>/dev/null | head -1)"
  if [ -z "$m4src" ]; then
    GT="$B/.gettext-src"; rm -rf "$GT"; mkdir -p "$GT"
    tar -x -C "$GT" --strip-components 1 -f "$SRC/gettext-$GETTEXT_V.tar.gz" \
      >>"$LOG/fluidsynth-$A.log" 2>&1 || fail "fluidsynth: could not extract gettext tarball"
    m4src="$(find "$GT" -name lib-ld.m4 2>/dev/null | head -1)"
  fi
  [ -n "$m4src" ] || fail "fluidsynth: lib-ld.m4 not found in gettext sources"
  cp "$m4src" "$SD/m4/"
  # lib-link.m4 / lib-prefix.m4 accompany lib-ld.m4 (may live in a sibling dir)
  for f in lib-link.m4 lib-prefix.m4; do
    src="$(dirname "$m4src")/$f"
    [ -f "$src" ] || src="$(find "$GT" -name "$f" 2>/dev/null | head -1)"
    [ -n "$src" ] && [ -f "$src" ] && cp "$src" "$SD/m4/"
  done
  ( cd "$SD" \
    && "$TOOLS/bin/autoreconf" -fi -I m4 \
    && find . -name config.guess -exec cp "$NEW_CONFIG_GUESS" {} \; \
    && find . -name config.sub   -exec cp "$NEW_CONFIG_SUB"   {} \; \
    && PKG_CONFIG="$TOOLS/bin/pkg-config" PKG_CONFIG_PATH="$P/lib/pkgconfig" \
       ./configure --host="$T" --prefix="$P" --enable-static --disable-shared \
         --disable-dbus-support --disable-pulse-support --disable-alsa-support \
         --disable-libsndfile-support --disable-jack-support \
         --disable-coreaudio --disable-coremidi --disable-lash --disable-ladcca \
         --disable-portaudio-support --disable-aufile-support --without-readline \
         CC="cc" CFLAGS="-arch $A -mmacosx-version-min=$DEPLOY -O2 $CWARN_C" \
         CPPFLAGS="-I$P/include" \
         LDFLAGS="-arch $A -mmacosx-version-min=$DEPLOY -L$P/lib" \
         LIBS="-Wl,-framework,CoreFoundation -Wl,-framework,CoreServices" \
    && make -j"$JOBS" && make install ) >>"$LOG/fluidsynth-$A.log" 2>&1 \
    || fail "fluidsynth ($A) failed, see $LOG/fluidsynth-$A.log"
}

build_x264() { # $1=arch
  local A="$1" T; T="$(triplet "$1")"
  local P="$WORK/deps/$A"
  [ -f "$P/lib/libx264.a" ] && { echo "    have x264 ($A)"; return; }
  say "x264 ($A, static)"
  local B="$WORK/x264-$A"; rm -rf "$B"; mkdir -p "$B"
  run "x264-$A" tar -x -C "$B" --strip-components 1 -f "$SRC/x264-stable.tar.gz"
  ( cd "$B" \
    && ./configure --host="$T" --prefix="$P" --enable-static --disable-cli \
         --disable-opencl --disable-swscale --disable-lavf --disable-ffms \
         --disable-gpac --disable-lsmash \
         --extra-cflags="-arch $A -mmacosx-version-min=$DEPLOY" \
         --extra-ldflags="-arch $A -mmacosx-version-min=$DEPLOY" \
    && make -j"$JOBS" && make install ) >>"$LOG/x264-$A.log" 2>&1 \
    || fail "x264 ($A) failed, see $LOG/x264-$A.log"
}

build_ffmpeg() { # $1=arch
  local A="$1"
  local P="$WORK/deps/$A"
  [ -f "$P/lib/libavcodec.a" ] && { echo "    have ffmpeg ($A)"; return; }
  say "FFmpeg $FFMPEG_V ($A, static, minimal: h264/aac/mpegts encode only)"
  local B="$WORK/ffmpeg-$A"; rm -rf "$B"; mkdir -p "$B"
  run "ffmpeg-$A" tar -x -C "$B" --strip-components 1 -f "$SRC/ffmpeg-$FFMPEG_V.tar.gz"
  local cross=""
  [ "$A" != "$(uname -m)" ] && cross="--enable-cross-compile --arch=$A --target-os=darwin"
  ( cd "$B" \
    && PKG_CONFIG="$TOOLS/bin/pkg-config" PKG_CONFIG_PATH="$P/lib/pkgconfig" \
       ./configure --prefix="$P" $cross \
         --cc="cc -arch $A" --enable-gpl --enable-libx264 \
         --enable-static --disable-shared --disable-programs --disable-doc \
         --disable-network --disable-avdevice --disable-avfilter \
         --disable-decoders --disable-demuxers --disable-parsers --disable-bsfs \
         --disable-filters --disable-indevs --disable-outdevs --disable-hwaccels \
         --disable-videotoolbox --disable-audiotoolbox --disable-securetransport \
         --disable-iconv --disable-zlib --disable-bzlib --disable-lzma \
         --disable-sdl2 --disable-xlib --disable-libxcb --disable-coreimage \
         --disable-appkit --disable-avfoundation --disable-vaapi \
         --disable-encoders --enable-encoder=libx264,aac \
         --disable-muxers --enable-muxer=mpegts \
         --disable-protocols --enable-protocol=file \
         --extra-cflags="-mmacosx-version-min=$DEPLOY -I$P/include" \
         --extra-ldflags="-mmacosx-version-min=$DEPLOY -L$P/lib" \
    && make -j"$JOBS" && make install ) >>"$LOG/ffmpeg-$A.log" 2>&1 \
    || fail "ffmpeg ($A) failed, see $LOG/ffmpeg-$A.log"
}

for A in $ARCHS; do
  mkdir -p "$WORK/deps/$A"
  build_gettext "$A"
  build_libffi "$A"
  build_glib "$A"
  build_fluidsynth "$A"
  if [ "$WITH_FFMPEG" = "1" ]; then
    build_x264 "$A"
    build_ffmpeg "$A"
  fi
done

# ----------------------------------------------------------------------------
# stage 5: per-arch DOSBox-X build (with in-tree zlib/libpng/SDL/SDL_net)
# ----------------------------------------------------------------------------
build_dosbox_arch() { # $1=arch
  local A="$1" T; T="$(triplet "$1")"
  local B="$WORK/build-$A"
  local DEPS="$WORK/deps/$A"
  local AF="-arch $A -mmacosx-version-min=$DEPLOY"
  local CWARN="-fcommon -Wno-implicit-function-declaration -Wno-error=implicit-function-declaration -Wno-error=int-conversion -Wno-error=incompatible-pointer-types -Wno-error=incompatible-function-pointer-types"

  # W^X JIT fix must be checked even when a binary already exists: a binary
  # built before this fix will SIGBUS on Apple Silicon when the dynamic core
  # first executes generated code.
  if [ -f "$B/src/cpu/core_dynrec/cache.h" ]; then
    WXRES="$(python3 "$KIT/patches/apply_wx_fix.py" "$B")" || fail "W^X patch failed on $B"
    if [ "$WXRES" = "CHANGED" ]; then
      echo "    applied W^X JIT fix ($A) -- forcing rebuild"
      rm -f "$B/src/dosbox-x" "$WORK/out/dosbox-x-$A"
    fi
  fi

  [ -f "$B/src/dosbox-x" ] && { echo "    have dosbox-x ($A)"; return; }
  say "DOSBox-X 0.82.20 ($A)"
  if [ ! -f "$B/.copied" ]; then
    rm -rf "$B"; cp -R "$PREP" "$B"; touch "$B/.copied"
  fi

  # dosbox.h (2019) only knows 32-bit ARM (__arm__); on arm64 it falls through
  # to "# define HAS_LONG_DOUBLE 1" which selects the x87-assembly FPU path
  # (fldcw etc.) that cannot compile on aarch64. Extend the guard.
  if ! grep -q '__aarch64__' "$B/include/dosbox.h"; then
    sed -i '' 's/#elif defined(__arm__)/#elif defined(__arm__) || defined(__aarch64__) || defined(__arm64__)/' \
      "$B/include/dosbox.h"
    grep -q '__aarch64__' "$B/include/dosbox.h" || fail "HAS_LONG_DOUBLE guard patch did not apply"
  fi

  # the 2025 SDL fork renamed the mac menu helpers:
  #   sdl1_hax_stock_osx_menu[_additem] -> sdl1_hax_stock_macosx_menu[_additem]
  # 0.82.20's menu_osx.mm uses the old names; rename (idempotent).
  if LC_ALL=C grep -rq 'sdl1_hax_stock_osx_menu' "$B/src/gui/" 2>/dev/null; then
    LC_ALL=C grep -rl 'sdl1_hax_stock_osx_menu' "$B/src" 2>/dev/null | while read -r f; do
      LC_ALL=C sed -i '' 's/sdl1_hax_stock_osx_menu/sdl1_hax_stock_macosx_menu/g' "$f" 2>/dev/null
    done
  fi

  # Apple Silicon W^X JIT fix for freshly copied trees (idempotent; trees
  # that existed before this function ran were already handled above).
  python3 "$KIT/patches/apply_wx_fix.py" "$B" >/dev/null || fail "W^X patch failed on $B"

  # ---- in-tree zlib (static)
  if [ ! -f "$B/vs2015/zlib/linux-host/lib/libz.a" ]; then
    echo "    in-tree zlib ($A)"
    # zlib 1.2.11's classic-MacOS guard misfires on modern SDKs that expose
    # TARGET_OS_MAC (redefines fdopen to NULL). Same fix as upstream 1.2.12.
    sed -i '' 's/defined(MACOS) || defined(TARGET_OS_MAC)/defined(MACOS)/' \
      "$B/vs2015/zlib/zutil.h" "$B/vs2015/zlib/gzguts.h" 2>/dev/null
    ( cd "$B/vs2015/zlib" \
      && CC="cc" CFLAGS="$AF -O2 $CWARN" ./configure --prefix="$PWD/linux-host" --static \
      && make -j"$JOBS" && make install ) >>"$LOG/zlib-$A.log" 2>&1 \
      || fail "zlib ($A) failed, see $LOG/zlib-$A.log"
  fi

  # ---- in-tree libpng (static)
  if [ ! -f "$B/vs2015/libpng/linux-host/lib/libpng.a" ] && \
     ! ls "$B/vs2015/libpng/linux-host/lib/"libpng*.a >/dev/null 2>&1; then
    echo "    in-tree libpng ($A)"
    # like zlib: pngpriv.h's classic-MacOS guard sees TARGET_OS_MAC on modern
    # SDKs and includes the long-gone <fp.h>. Upstream removed the test too.
    sed -i '' 's/ || defined(TARGET_OS_MAC)//' "$B/vs2015/libpng/pngpriv.h" 2>/dev/null
    sed -i '' 's/|| defined(TARGET_OS_MAC)//'  "$B/vs2015/libpng/pngpriv.h" 2>/dev/null
    ( cd "$B/vs2015/libpng" \
      && cp "$NEW_CONFIG_GUESS" config.guess 2>/dev/null; cp "$NEW_CONFIG_SUB" config.sub 2>/dev/null; \
      cd "$B/vs2015/libpng" \
      && ./configure --host="$T" --prefix="$PWD/linux-host" --enable-static --disable-shared \
           CC="cc" CFLAGS="$AF -O2 $CWARN" \
           CPPFLAGS="-I$B/vs2015/zlib/linux-host/include" \
           LDFLAGS="$AF -L$B/vs2015/zlib/linux-host/lib" \
      && make -j"$JOBS" && make install ) >>"$LOG/libpng-$A.log" 2>&1 \
      || fail "libpng ($A) failed, see $LOG/libpng-$A.log"
    # configure.ac checks for -lpng; make sure a plain libpng.a name exists
    ( cd "$B/vs2015/libpng/linux-host/lib" && [ -f libpng.a ] || ln -sf libpng16.a libpng.a ) 2>/dev/null
  fi

  # ---- in-tree SDL 1.x fork (static)
  if [ ! -f "$B/vs2015/sdl/linux-host/lib/libSDL.a" ]; then
    echo "    in-tree SDL 1.x ($A)"
    ( cd "$B/vs2015/sdl" \
      && chmod +x configure build-scripts/* 2>/dev/null; \
      cd "$B/vs2015/sdl" \
      && ac_cv_header_iconv_h=no ac_cv_func_iconv=no ac_cv_lib_iconv_libiconv_open=no \
         ./configure --host="$T" --prefix="$PWD/linux-host" \
           --enable-static --disable-shared --disable-video-x11 --disable-x11-shared \
           --disable-video-x11-xrandr --disable-video-x11-vm --disable-video-x11-xv \
           --disable-assembly \
           CC="cc" CXX="c++" CFLAGS="$AF -O2 $CWARN" CXXFLAGS="$AF -O2" \
           LDFLAGS="$AF" \
      && make -j"$JOBS" && make install ) >>"$LOG/sdl-$A.log" 2>&1 \
      || fail "SDL1 ($A) failed, see $LOG/sdl-$A.log"
  fi

  # ---- in-tree SDL_net fork (static)
  # Built directly with cc+ar: it is only 4 C files, and the autotools path
  # produced an empty archive from this tree (all the drama for nothing).
  local SDLNET_LIB="$B/vs2015/sdlnet/linux-host/lib/libSDL_net.a"
  if ! { [ -f "$SDLNET_LIB" ] && nm -gU "$SDLNET_LIB" 2>/dev/null | grep -q SDLNet_Init; }; then
    echo "    in-tree SDL_net ($A, direct build)"
    ( cd "$B/vs2015/sdlnet" || exit 1
      rm -rf linux-host build-tmp
      mkdir -p linux-host/lib linux-host/include/SDL build-tmp
      for s in SDLnet.c SDLnetTCP.c SDLnetUDP.c SDLnetselect.c; do
        [ -f "$s" ] || { echo "missing source: $s"; exit 1; }
        cc -c -o "build-tmp/${s%.c}.o" "$s" $AF -O2 $CWARN \
          -I. -I"$B/vs2015/sdl/linux-host/include/SDL" \
          -I"$B/vs2015/sdl/linux-host/include" -D_THREAD_SAFE || exit 1
      done
      ar cr linux-host/lib/libSDL_net.a build-tmp/*.o || exit 1
      ranlib linux-host/lib/libSDL_net.a || exit 1
      cp SDL_net.h linux-host/include/SDL/ || exit 1
      cp SDL_net.h linux-host/include/ ) >>"$LOG/sdlnet-$A.log" 2>&1 \
      || fail "SDL_net ($A) failed, see $LOG/sdlnet-$A.log"
    nm -gU "$SDLNET_LIB" | grep -q SDLNet_Init \
      || fail "SDL_net ($A): SDLNet_Init still missing after direct build"
    # the archive changed: force reconfigure+relink so C_SDL_NET/C_MODEM/C_IPX enable
    rm -f "$B/src/dosbox-x"
  fi

  # ---- DOSBox-X itself
  echo "    configuring dosbox-x ($A)"
  local SDLCFG="$B/vs2015/sdl/linux-host/bin/sdl-config"
  local SDL_STATIC; SDL_STATIC="$("$SDLCFG" --static-libs 2>/dev/null || "$SDLCFG" --libs)"
  local FFLIBS=""
  local FFOPT="--disable-avcodec"
  if [ "$WITH_FFMPEG" = "1" ]; then
    # the full static closure must be in LIBS *before* configure runs its
    # AC_CHECK_LIB(avcodec,...) probe -- static archives don't pull their
    # dependencies the way the 2019-era shared dylibs did
    FFLIBS="-lavformat -lavcodec -lswscale -lswresample -lavutil -lx264"
    FFOPT="--enable-avcodec"
  fi
  # FluidSynth's static closure: glib core + gthread + libintl. CoreFoundation
  # comes via configure.ac's framework list; CoreServices is needed by static
  # glib (FSFindFolder in gutils.c) and libintl.
  local FSLIBS="-lgthread-2.0 -lglib-2.0 -lintl -framework CoreServices"

  ( cd "$B" && \
    PKG_CONFIG="$TOOLS/bin/pkg-config" \
    PKG_CONFIG_PATH="$DEPS/lib/pkgconfig" \
    CC="cc" CXX="c++" OBJCXX="c++" \
    CFLAGS="$AF -O2 $CWARN" \
    CXXFLAGS="$AF -O2" \
    OBJCXXFLAGS="$AF -O2" \
    CPPFLAGS="-I$B/vs2015/zlib/linux-host/include -I$B/vs2015/libpng/linux-host/include -I$DEPS/include" \
    LDFLAGS="$AF -L$B/vs2015/zlib/linux-host/lib -L$B/vs2015/libpng/linux-host/lib -L$DEPS/lib" \
    LIBS="$FFLIBS $FSLIBS -liconv $SDL_STATIC" \
    ./configure --host="$T" --prefix=/usr \
        --enable-core-inline --enable-debug=heavy $FFOPT \
    ) >>"$LOG/dosbox-configure-$A.log" 2>&1 \
    || fail "dosbox-x configure ($A) failed, see $LOG/dosbox-configure-$A.log"

  # verify the features we care about actually got enabled
  local CFG="$B/config.h"
  for def in C_DYNREC C_SDL_NET C_MODEM C_IPX C_LIBPNG C_SSHOT C_LIBZ C_DEBUG C_HEAVY_DEBUG C_MT32 C_OPENGL C_NE2000 C_FLUIDSYNTH; do
    grep -q "define $def 1" "$CFG" || echo "    WARNING($A): $def is NOT enabled (check $LOG/dosbox-configure-$A.log)"
  done
  if [ "$A" = "x86_64" ]; then
    grep -q "define C_TARGETCPU X86_64" "$CFG" || fail "x86_64 slice: C_TARGETCPU wrong (dynamic core would be lost)"
  else
    grep -q "define C_TARGETCPU ARMV8LE" "$CFG" || fail "arm64 slice: C_TARGETCPU != ARMV8LE (dynamic core would be lost)"
  fi
  if [ "$WITH_FFMPEG" = "1" ]; then
    grep -q "define C_AVCODEC 1" "$CFG" || echo "    WARNING($A): C_AVCODEC not enabled -- FFmpeg capture missing (see configure log)"
  fi

  echo "    compiling dosbox-x ($A) -- this takes a while"
  ( cd "$B" && make -j"$JOBS" ) >>"$LOG/dosbox-make-$A.log" 2>&1 \
    || fail "dosbox-x make ($A) failed, see $LOG/dosbox-make-$A.log (last 60 lines):$(printf '\n')$(tail -60 "$LOG/dosbox-make-$A.log")"

  [ -f "$B/src/dosbox-x" ] || fail "build finished but $B/src/dosbox-x not found"
  cp "$B/src/dosbox-x" "$WORK/out/dosbox-x-$A"
  echo "    OK: $WORK/out/dosbox-x-$A"
}

for A in $ARCHS; do build_dosbox_arch "$A"; done

# ----------------------------------------------------------------------------
# stage 6: universal binary + app bundle
# ----------------------------------------------------------------------------
say "Stage 6: assemble $APP_NAME.app"
OUTAPP="$WORK/out/$APP_NAME.app"
rm -rf "$OUTAPP"
mkdir -p "$OUTAPP/Contents/MacOS" "$OUTAPP/Contents/Resources"

run lipo lipo -create -output "$OUTAPP/Contents/MacOS/$APP_NAME" \
  "$WORK/out/dosbox-x-arm64" "$WORK/out/dosbox-x-x86_64"
chmod +x "$OUTAPP/Contents/MacOS/$APP_NAME"

cp "$KIT/resources/Info.plist" "$OUTAPP/Contents/Info.plist"
printf 'APPL????' > "$OUTAPP/Contents/PkgInfo"

# resources the emulator likes to have around
cp "$PREP/dosbox.reference.conf"  "$OUTAPP/Contents/Resources/" 2>/dev/null
cp "$PREP/font/FREECG98.BMP"      "$OUTAPP/Contents/Resources/" 2>/dev/null
cp "$PREP/CHANGELOG"              "$OUTAPP/Contents/Resources/" 2>/dev/null

# app icon: generated from the official DOSBox-X artwork the same way the
# upstream Makefile.am does it (sips + iconutil, both part of macOS)
fetch "https://raw.githubusercontent.com/joncampbell123/dosbox-x/$SDL_FORK_TAG/contrib/macos/dosbox-x.png" \
      "$SRC/dosbox-x-icon.png"
if [ ! -f "$WORK/out/dosbox-x.icns" ]; then
  ICONSET="$WORK/out/dosbox.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  ( sips -z 16 16     "$SRC/dosbox-x-icon.png" --out "$ICONSET/icon_16x16.png" && \
    sips -z 32 32     "$SRC/dosbox-x-icon.png" --out "$ICONSET/icon_16x16@2x.png" && \
    sips -z 32 32     "$SRC/dosbox-x-icon.png" --out "$ICONSET/icon_32x32.png" && \
    sips -z 64 64     "$SRC/dosbox-x-icon.png" --out "$ICONSET/icon_32x32@2x.png" && \
    sips -z 128 128   "$SRC/dosbox-x-icon.png" --out "$ICONSET/icon_128x128.png" && \
    sips -z 256 256   "$SRC/dosbox-x-icon.png" --out "$ICONSET/icon_256x256.png" && \
    sips -z 512 512   "$SRC/dosbox-x-icon.png" --out "$ICONSET/icon_512x512.png" && \
    sips -z 1024 1024 "$SRC/dosbox-x-icon.png" --out "$ICONSET/icon_512x512@2x.png" && \
    iconutil -c icns -o "$WORK/out/dosbox-x.icns" "$ICONSET" ) >>"$LOG/icon.log" 2>&1 \
    || echo "    NOTE: icon generation failed (see $LOG/icon.log); continuing without icon"
  rm -rf "$ICONSET"
fi
[ -f "$WORK/out/dosbox-x.icns" ] && cp "$WORK/out/dosbox-x.icns" "$OUTAPP/Contents/Resources/dosbox-x.icns"

# ad-hoc signature: REQUIRED for arm64 (unsigned arm64 binaries are killed).
# No hardened runtime -> MAP_JIT works without entitlements.
run codesign codesign --force --sign - "$OUTAPP"

# ----------------------------------------------------------------------------
# stage 7: verification
# ----------------------------------------------------------------------------
say "Stage 7: verify"
bash "$KIT/verify-bundle.sh" "$OUTAPP" || fail "verification FAILED"

say "DONE"
echo "  App bundle : $OUTAPP"
echo "  Copy it anywhere (it is fully self-contained) and run:"
echo "    open \"$OUTAPP\""
echo
echo "  If you move it to another Mac, clear the quarantine flag once:"
echo "    xattr -dr com.apple.quarantine $APP_NAME.app"
echo
echo "  Inside DOSBox-X, verify the dynamic core with:  core dynamic  (in the config)"
echo "  or check the log for 'DYNREC' / dynamic core messages."
