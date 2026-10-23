#!/usr/bin/env bash
# lib/deps.sh -- runtime libraries bundled inside dosbox-daum.app.
# shellcheck shell=bash

# --------------------------------------------------------------------------
# SDL2 + sdl12-compat
#
# Daum is an SDL 1.2 program.  SDL 1.2.15 predates ARM64 entirely and is built
# on macOS APIs Apple removed years ago, so instead we build SDL2 and layer
# sdl12-compat on top: it implements the SDL 1.2 API against SDL2, which means
# Daum's source needs no changes while the actual window, input and audio go
# through a modern, Metal-capable backend.
# --------------------------------------------------------------------------
dep_sdl2() {
  local src; src="$(extract "$(fetch "$SDL2_URL")")"
  build_autotools sdl2 "$src" \
    --without-x --disable-video-x11 --disable-sndio \
    --disable-dependency-tracking
}

dep_sdl12compat() {
  local src bdir
  src="$(extract "$(fetch "$SDL12COMPAT_URL")")"
  bdir="$BUILD/obj/$ARCH/sdl12compat"
  local log; log="$(start_log "sdl12compat.${ARCH}.log")"
  rm -rf "$bdir"; mkdir -p "$bdir"
  ( cd "$bdir" \
    && cmake "$src" \
         -DCMAKE_INSTALL_PREFIX="$ARCH_PREFIX" \
         -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
         -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
         -DCMAKE_BUILD_TYPE=Release \
         -DCMAKE_PREFIX_PATH="$ARCH_PREFIX" \
         -DSDL12TESTS=OFF -DSDL12DEVEL=ON \
    && make -j"$(nproc_count)" \
    && make install ) >> "$log" 2>&1 \
    || die "sdl12-compat ($ARCH) failed -- see $log"

  _ensure_sdl_config
}

# DOSBox's configure locates SDL 1.2 through AM_PATH_SDL, which shells out to
# sdl-config.  sdl12-compat does not always install one, so synthesise it.
# Without this, configure decides SDL is missing and the build dies with a
# misleading "SDL library not found" long after the real problem.
_ensure_sdl_config() {
  local sc="$ARCH_PREFIX/bin/sdl-config"
  [[ -x "$sc" ]] && return 0
  mkdir -p "$ARCH_PREFIX/bin"
  cat > "$sc" <<EOF
#!/bin/sh
prefix=$ARCH_PREFIX
exec_prefix=\$prefix
while test \$# -gt 0; do
  case "\$1" in
    --prefix) echo \$prefix ;;
    --exec-prefix) echo \$exec_prefix ;;
    --version) echo 1.2.68 ;;
    --cflags) echo "-I\$prefix/include/SDL -D_THREAD_SAFE" ;;
    --libs) echo "-L\$prefix/lib -lSDL-1.2" ;;
    --static-libs) echo "-L\$prefix/lib -lSDL-1.2" ;;
  esac
  shift
done
EOF
  chmod +x "$sc"
  ok "synthesised sdl-config for sdl12-compat"
}

dep_sdl_net() {
  local src; src="$(extract "$(fetch "$SDL_NET_URL")")"
  # SDL_net 1.2.8 ships a 2004-era config.guess that has never heard of arm64.
  _refresh_autotools_aux "$src"
  build_autotools sdl-net "$src" \
    --with-sdl-prefix="$ARCH_PREFIX" \
    --disable-sdltest --disable-gui --disable-dependency-tracking
}

dep_libpng() {
  local src; src="$(extract "$(fetch "$LIBPNG_URL")")"
  build_autotools libpng "$src" --disable-dependency-tracking
}

# --------------------------------------------------------------------------
# Feature-preserving dependencies
#
# Daum's configure.ac only warns when these are missing -- it prints
# AC_MSG_WARN and continues -- so leaving them out yields a build that looks
# successful while silently dropping features that exist in no other DOSBox
# fork.  Each is checked for after the build rather than trusted.
# --------------------------------------------------------------------------
dep_freetype() {
  local src; src="$(extract "$(fetch "$FREETYPE_URL")")"
  build_autotools freetype "$src" \
    --without-harfbuzz --without-brotli --without-bzip2 \
    --with-png=no --with-zlib=yes --disable-dependency-tracking
  _ensure_freetype_config
}

# Daum probes for FreeType with AC_PATH_PROG(FREETYPE_CONFIG, freetype-config)
# and disables the printer outright if it is absent.  FreeType dropped
# freetype-config in 2.9.1 in favour of pkg-config, so without a shim the
# printer can never be enabled no matter how the library is built.
_ensure_freetype_config() {
  local fc="$ARCH_PREFIX/bin/freetype-config"
  [[ -x "$fc" ]] && return 0
  mkdir -p "$ARCH_PREFIX/bin"
  cat > "$fc" <<EOF
#!/bin/sh
prefix=$ARCH_PREFIX
while test \$# -gt 0; do
  case "\$1" in
    --prefix|--exec-prefix) echo \$prefix ;;
    --ftversion) echo ${FREETYPE_VERSION} ;;
    --cflags) echo "-I\$prefix/include/freetype2" ;;
    --libs) echo "-L\$prefix/lib -lfreetype" ;;
  esac
  shift
done
EOF
  chmod +x "$fc"
  ok "synthesised freetype-config (FreeType 2.9.1+ no longer ships one)"
}

dep_sdl_sound() {
  local src; src="$(extract "$(fetch "$SDL_SOUND_URL")")"
  _refresh_autotools_aux "$src"
  build_autotools sdl-sound "$src" \
    --with-sdl-prefix="$ARCH_PREFIX" \
    --enable-mpglib --disable-smpeg --disable-speex --disable-flac \
    --disable-physfs --disable-sdltest --disable-dependency-tracking
}

dep_physfs() {
  local src bdir log
  src="$(extract "$(fetch "$PHYSFS_URL")")"
  bdir="$BUILD/obj/$ARCH/physfs"
  log="$(start_log "physfs.${ARCH}.log")"
  rm -rf "$bdir"; mkdir -p "$bdir"
  ( cd "$bdir" \
    && cmake "$src" \
         -DCMAKE_INSTALL_PREFIX="$ARCH_PREFIX" \
         -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
         -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
         -DCMAKE_BUILD_TYPE=Release \
         -DPHYSFS_BUILD_STATIC=OFF -DPHYSFS_BUILD_TEST=OFF -DPHYSFS_BUILD_DOCS=OFF \
         -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    && make -j"$(nproc_count)" \
    && make install ) >> "$log" 2>&1 \
    || die "physfs ($ARCH) failed -- see $log"
}

# --------------------------------------------------------------------------
# Audio: SoundFont MIDI
#
# There is deliberately no munt/mt32emu build here.  Daum vendors the entire
# MT-32 emulation library into src/gui -- 30 translation units (Synth, Part,
# Partial, TVA/TVF/TVP, LA32*, BReverbModel, ROMInfo, ...), all listed in
# src/gui/Makefile.am, registering mididevice=mt32.  Linking an external
# libmt32emu alongside it would at best be dead weight and at worst collide.
# MT-32 needs only its ROM files at run time; see the launcher's MT32_ROM_DIR.
# --------------------------------------------------------------------------
dep_fluidsynth() {
  local src bdir log
  src="$(extract "$(fetch "$FLUIDSYNTH_URL")")"
  bdir="$BUILD/obj/$ARCH/fluidsynth"
  log="$(start_log "fluidsynth.${ARCH}.log")"
  rm -rf "$bdir"; mkdir -p "$bdir"
  # -Dosal=cpp11 is the load-bearing flag: it selects FluidSynth 2.5's C++11 OS
  # abstraction instead of GLib.  Without it CMake fails at
  #   Could NOT find GLib2 (Required is at least version "2.6.5")
  # and the only alternative is building the whole glib stack.
  # -Denable-libinstpatch=0 is required alongside it -- libinstpatch itself
  # depends on GLib, so leaving it enabled reintroduces the dependency.
  #
  # -Denable-framework=OFF is equally load-bearing on macOS.  FluidSynth's
  # CMakeLists does  option(enable-framework "create a Mac OSX Framework" on)
  # so an Apple build defaults to installing
  #   <prefix>/Library/Frameworks/FluidSynth.framework/...
  # and nothing at all in lib/ or include/.  make install still succeeds, and
  # Daum's AC_CHECK_HEADER(fluidsynth.h) / AC_CHECK_LIB(fluidsynth) then both
  # fail, which configure downgrades to a warning -- so MIDI silently vanishes.
  # A plain dylib is also what the bundle's @rpath relocation expects.
  #
  # CoreAudio/CoreMIDI only otherwise: no PulseAudio, JACK, ALSA or SDL drivers,
  # and no readline/dbus, each of which would be another dylib to bundle.
  ( cd "$bdir" \
    && cmake "$src" \
         -DCMAKE_INSTALL_PREFIX="$ARCH_PREFIX" \
         -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
         -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
         -DCMAKE_BUILD_TYPE=Release \
         -DCMAKE_PREFIX_PATH="$ARCH_PREFIX" \
         -Dosal=cpp11 -Denable-libinstpatch=0 \
         -Denable-framework=OFF \
         -Denable-coreaudio=ON -Denable-coremidi=ON \
         -Denable-jack=OFF -Denable-pulseaudio=OFF -Denable-alsa=OFF \
         -Denable-sdl2=OFF -Denable-oss=OFF -Denable-dbus=OFF \
         -Denable-readline=OFF -Denable-libsndfile=OFF \
         -Denable-network=OFF -Denable-ipv6=OFF \
         -DBUILD_SHARED_LIBS=ON \
    && make -j"$(nproc_count)" \
    && make install ) >> "$log" 2>&1 \
    || die "fluidsynth ($ARCH) failed -- see $log"
}

# --------------------------------------------------------------------------
# FFmpeg for video capture.  LGPL configuration: no --enable-gpl, no
# --enable-nonfree, so the result is redistributable alongside Daum's GPLv2.
# --------------------------------------------------------------------------
dep_ffmpeg() {
  local src bdir log extra=()
  src="$(extract "$(fetch "$FFMPEG_URL")")"
  log="$(start_log "ffmpeg.${ARCH}.log")"
  bdir="$BUILD/obj/$ARCH/ffmpeg"
  rm -rf "$bdir"; mkdir -p "$bdir"

  if [[ "$ARCH" == "x86_64" ]]; then
    extra+=(--arch=x86_64 --x86asmexe="$TOOLS/bin/nasm")
  else
    extra+=(--arch=arm64 --enable-neon)
  fi
  [[ "$ARCH" != "$HOST_ARCH" ]] && extra+=(--enable-cross-compile)

  ( cd "$bdir" && "$src/configure" \
      --prefix="$ARCH_PREFIX" --target-os=darwin \
      --cc="clang -arch $ARCH" --cxx="clang++ -arch $ARCH" \
      --extra-cflags="-mmacosx-version-min=${DEPLOYMENT_TARGET} -isysroot ${SDKROOT}" \
      --extra-ldflags="-mmacosx-version-min=${DEPLOYMENT_TARGET} -isysroot ${SDKROOT} -Wl,-headerpad_max_install_names" \
      --enable-shared --disable-static --enable-pic \
      --disable-programs --disable-doc --disable-debug \
      --disable-avdevice --disable-postproc --disable-network \
      --enable-videotoolbox --enable-audiotoolbox \
      --install-name-dir='@rpath' \
      "${extra[@]}" \
    && make -j"$(nproc_count)" \
    && make install ) >> "$log" 2>&1 \
    || die "ffmpeg ($ARCH) failed -- see $log"
}

# Replace config.guess/config.sub in an old source tree.  Packages from the
# 2000s ship versions that predate arm64 and abort with "cannot guess build
# type"; the copies in our own automake install know about it.
_refresh_autotools_aux() {
  local src="$1" f found
  for f in config.guess config.sub; do
    found="$(find "$TOOLS/share/automake"* -name "$f" 2>/dev/null | head -1)"
    [[ -n "$found" && -e "$src/$f" ]] && cp -f "$found" "$src/$f"
  done
}

build_deps_for_arch() {
  set_arch "$1"
  step "Stage 2: runtime libraries ($ARCH)"
  # Each stage names the file it must leave behind, so a stale stamp over a
  # wiped prefix rebuilds instead of silently disabling the feature.
  local L="$ARCH_PREFIX/lib"
  once_artifact "dep-sdl2-$ARCH"        "$L/libSDL2*.dylib"      dep_sdl2
  once_artifact "dep-sdl12compat-$ARCH" "$L/libSDL-1.2*.dylib"   dep_sdl12compat
  once_artifact "dep-sdlnet-$ARCH"      "$L/libSDL_net*.dylib"   dep_sdl_net
  once_artifact "dep-libpng-$ARCH"      "$L/libpng*.dylib"       dep_libpng
  once_artifact "dep-freetype-$ARCH"    "$L/libfreetype*.dylib"  dep_freetype
  once_artifact "dep-sdlsound-$ARCH"    "$L/libSDL_sound*.dylib" dep_sdl_sound
  once_artifact "dep-physfs-$ARCH"      "$L/libphysfs*.dylib"    dep_physfs
  once_artifact "dep-fluidsynth-$ARCH"  "$L/libfluidsynth*.dylib" dep_fluidsynth
  once_artifact "dep-ffmpeg-$ARCH"      "$L/libavcodec*.dylib"   dep_ffmpeg
}
