# shellcheck shell=bash
# ============================================================================
# scripts/build-mpv.sh — configure & compile mpv, then lipo into a universal
# binary against the merged $PREFIX.
#
# mpv must be built ONCE PER ARCH (not in a single multi-arch meson pass):
# meson's has_header() probes invoke `clang -E`, and clang rejects `-E` together
# with multiple -arch flags ("cannot use 'cpp-output' output with multiple -arch
# options"). In a universal one-pass build every header probe therefore fails,
# silently misdetecting features (iconv, etc.). Building each arch with a single
# -arch keeps all detection correct; we lipo the two mpv binaries afterwards.
#
# pkg-config points exclusively at $PREFIX so every dependency resolves from our
# bundle and never from the system / Brew / MacPorts.
# ============================================================================

MPV_BUILD=""   # set by build_mpv(); consumed by bundle.sh (holds universal mpv)
MPV_SRC=""

build_mpv() {
  scrub_env
  detect_sdk

  [ -f "$MPV_TARBALL" ] || die "mpv tarball not found at $MPV_TARBALL (set MPV_TARBALL=)"
  MPV_SRC="$(extract "$MPV_TARBALL")"
  MPV_SRC="${MPV_SRC%/}"
  ok "mpv source: $MPV_SRC"

  export PATH="$TOOLS_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  export PKG_CONFIG="$TOOLS_PREFIX/bin/pkgconf"
  export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
  export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"

  # libiconv ships in the macOS SDK with no .pc; provide one (system -liconv).
  mkdir -p "$PREFIX/lib/pkgconfig"
  cat > "$PREFIX/lib/pkgconfig/iconv.pc" <<EOF
prefix=/usr
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: iconv
Description: libiconv character set conversion (macOS system)
Version: 1.11
Libs: -liconv
Cflags:
EOF

  # Feature options derived from config.sh toggles (no arch flags here).
  local o=()
  o+=( -Dcplayer=true -Dlibmpv=true )
  # mpv 0.41's macOS player (the Cocoa app/event loop) is implemented in Swift,
  # so Swift is REQUIRED to build the cplayer on macOS. The per-arch -target
  # (added in the build loop) pins swiftc to each arch AND the 11.0 deployment
  # floor; the Swift runtime is ABI-stable and provided by macOS 11+ at
  # /usr/lib/swift, so the result stays back-deployable.
  o+=( -Dswift-build=enabled )
  o+=( -Dcocoa=enabled -Dgl=enabled -Dgl-cocoa=enabled -Dplain-gl=enabled )
  o+=( -Dvideotoolbox-gl=enabled )              # HW decode over the OpenGL path
  o+=( -Dcoreaudio=enabled -Davfoundation=enabled )
  o+=( -Dmanpage-build=disabled )               # avoids needing python-docutils
  o+=( -Dlcms2=enabled -Diconv=enabled -Dzlib=enabled )

  [ "$ENABLE_LUA" = 1 ]        && o+=( -Dlua=lua52 )          || o+=( -Dlua=disabled )
  [ "$ENABLE_JAVASCRIPT" = 1 ] && o+=( -Djavascript=enabled ) || o+=( -Djavascript=disabled )
  [ "$ENABLE_LIBARCHIVE" = 1 ] && o+=( -Dlibarchive=enabled ) || o+=( -Dlibarchive=disabled )
  [ "$ENABLE_UCHARDET" = 1 ]   && o+=( -Duchardet=enabled )   || o+=( -Duchardet=disabled )
  [ "$ENABLE_RUBBERBAND" = 1 ] && o+=( -Drubberband=enabled ) || o+=( -Drubberband=disabled )
  [ "$ENABLE_JPEG" = 1 ]       && o+=( -Djpeg=enabled )       || o+=( -Djpeg=disabled )
  [ "$ENABLE_ZIMG" = 1 ]       && o+=( -Dzimg=enabled )       || o+=( -Dzimg=disabled )
  if [ "$ENABLE_DISC" = 1 ]; then
    o+=( -Dlibbluray=enabled -Ddvdnav=enabled -Dcdda=enabled )
  else
    o+=( -Dlibbluray=disabled -Ddvdnav=disabled -Dcdda=disabled )
  fi
  [ "$ENABLE_VAPOURSYNTH" = 1 ] && o+=( -Dvapoursynth=enabled ) || o+=( -Dvapoursynth=disabled )
  [ "$ENABLE_VULKAN" = 1 ]      && o+=( -Dvulkan=enabled )      || o+=( -Dvulkan=disabled )

  # Disable everything Linux/Windows so 'auto' never trips on a host stray.
  o+=( -Dalsa=disabled -Dpulse=disabled -Dpipewire=disabled -Djack=disabled
       -Dsndio=disabled -Dwayland=disabled -Dx11=disabled -Ddrm=disabled
       -Dvaapi=disabled -Dvdpau=disabled
       -Dsdl2-audio=disabled -Dsdl2-video=disabled -Dsdl2-gamepad=disabled )

  # --- build once per arch (single -arch each) ---
  local a primary="" bins=() libs=()
  for a in "${ARCHS[@]}"; do
    local bdir="$MPV_SRC/build-$a"
    rm -rf "$bdir"
    local af=()
    if [ "$a" = "$NATIVE_ARCH" ]; then
      local fa="-arch $a -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET} -isysroot $SDKROOT"
      af=( -Dc_args="$fa" -Dcpp_args="$fa" -Dobjc_args="$fa"
           -Dc_link_args="$fa" -Dcpp_link_args="$fa" -Dobjc_link_args="$fa" )
    else
      af=( --cross-file "$(meson_cross_file "$a")" )   # single -arch, so -E works
    fi
    log "configuring mpv for $a"
    # swiftc gets no -arch from meson; pin it per-arch + to the 11.0 floor here.
    meson setup "$bdir" "$MPV_SRC" --buildtype=release "${af[@]}" \
        -Dswift-flags="-target $a-apple-macosx${MACOSX_DEPLOYMENT_TARGET}" \
        "${o[@]}"
    log "compiling mpv for $a"
    meson compile -C "$bdir" -j "$JOBS"
    [ -f "$bdir/mpv" ] || die "mpv ($a) binary was not produced"
    bins+=( "$bdir/mpv" )
    local lm; lm="$(find "$bdir" -maxdepth 1 -name 'libmpv.*.dylib' -type f | head -1)"
    [ -n "$lm" ] && libs+=( "$lm" )
    [ "$a" = "$NATIVE_ARCH" ] && primary="$bdir"
  done
  [ -n "$primary" ] || primary="$MPV_SRC/build-${ARCHS[0]}"

  # Combine into universal binaries inside the primary build dir (it also holds
  # common/version.h that osxbundle.py reads).
  log "lipo-merging mpv into a universal binary"
  lipo -create "${bins[@]}" -output "$primary/mpv"
  if [ "${#libs[@]}" -gt 0 ]; then
    lipo -create "${libs[@]}" -output "$primary/$(basename "${libs[0]}")" 2>/dev/null || true
  fi

  MPV_BUILD="$primary"
  ok "Built universal mpv:"
  lipo -info "$primary/mpv" | sed 's/^/      /'
}
