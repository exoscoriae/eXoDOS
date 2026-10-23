#!/usr/bin/env bash
# lib/deps.sh -- runtime libraries that ship inside wine.app.
#
# Each recipe is built once per architecture in $BUILD_ARCHS into
# $BUILD/prefix-<arch>.  The bundle stage later lipos them together.
# shellcheck shell=bash

# --------------------------------------------------------------------------
# FreeType -- font rasterisation for win32u.
# Built deliberately lean: no harfbuzz, brotli or libpng, none of which Wine's
# font path requires, each of which would be another bundled dylib.
# --------------------------------------------------------------------------
dep_freetype() {
  local src; src="$(extract "$(fetch "$FREETYPE_URL")")"
  build_autotools freetype "$src" \
    --without-harfbuzz --without-brotli --without-png \
    --without-bzip2 --with-zlib=yes --disable-dependency-tracking
}

# --------------------------------------------------------------------------
# GnuTLS stack -- schannel.dll's TLS backend.
# gmp -> nettle/hogweed -> libtasn1 -> gnutls
# --------------------------------------------------------------------------
dep_gmp() {
  local src; src="$(extract "$(fetch "$GMP_URL")")"
  build_autotools gmp "$src" --enable-cxx=no --disable-dependency-tracking
}

dep_nettle() {
  local src; src="$(extract "$(fetch "$NETTLE_URL")")"
  build_autotools nettle "$src" \
    --disable-documentation --disable-openssl --disable-dependency-tracking \
    --with-include-path="$ARCH_PREFIX/include" \
    --with-lib-path="$ARCH_PREFIX/lib"
}

dep_libtasn1() {
  local src; src="$(extract "$(fetch "$LIBTASN1_URL")")"
  build_autotools libtasn1 "$src" --disable-doc --disable-dependency-tracking
}

dep_gnutls() {
  local src; src="$(extract "$(fetch "$GNUTLS_URL")")"
  # --with-included-unistring avoids a libunistring dependency.
  # p11-kit, idn, tpm, dane and the command line tools are all dead weight for
  # a schannel backend and each would drag in more dylibs.
  build_autotools gnutls "$src" \
    --with-included-unistring \
    --without-p11-kit --without-idn --without-tpm --without-tpm2 \
    --without-zstd --without-brotli \
    --disable-libdane --disable-doc --disable-tests --disable-tools \
    --disable-nls --disable-guile --disable-gtk-doc \
    --disable-full-test-suite --disable-dependency-tracking \
    --with-nettle-mini=no
}

# --------------------------------------------------------------------------
# SDL2 -- gamepad / joystick support for dinput and xinput.
# --------------------------------------------------------------------------
dep_sdl2() {
  local src; src="$(extract "$(fetch "$SDL2_URL")")"
  build_autotools sdl2 "$src" \
    --without-x --disable-video-x11 --disable-sndio \
    --disable-dependency-tracking
}

# --------------------------------------------------------------------------
# FFmpeg -- winedmo (Media Foundation) and gst-libav.
# LGPL configuration only: no --enable-gpl, no --enable-nonfree, so the result
# is redistributable alongside Wine's LGPL.
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
      --prefix="$ARCH_PREFIX" \
      --target-os=darwin \
      --cc="clang -arch $ARCH" \
      --cxx="clang++ -arch $ARCH" \
      --extra-cflags="-mmacosx-version-min=${DEPLOYMENT_TARGET} -isysroot ${SDKROOT}" \
      --extra-ldflags="-mmacosx-version-min=${DEPLOYMENT_TARGET} -isysroot ${SDKROOT} -Wl,-headerpad_max_install_names" \
      --enable-shared --disable-static --enable-pic \
      --disable-programs --disable-doc --disable-debug \
      --disable-avdevice --disable-postproc \
      --disable-network --disable-sdl2 \
      --enable-videotoolbox --enable-audiotoolbox \
      --install-name-dir='@rpath' \
      "${extra[@]}" \
    && make -j"$(nproc_count)" \
    && make install ) >> "$log" 2>&1 \
    || die "ffmpeg ($ARCH) failed -- see $log"
}

# --------------------------------------------------------------------------
# Vulkan headers + MoltenVK.
#
# MoltenVK is universal by construction, so it is built (or downloaded) once
# and then thinned into each per-arch prefix for linking.  Version 1.4.1 is
# pinned deliberately: 1.4.2 raised its deployment target to macOS 12.0.
# --------------------------------------------------------------------------
# Vulkan-Headers publishes git tags but no GitHub "releases", so the
# /releases/latest endpoint 404s.  Resolve from the tag list instead, newest
# vMAJOR.MINOR.PATCH wins.  git ls-remote needs no API token and is not rate
# limited, so try it first and keep the REST API as a fallback.
_resolve_vulkan_headers_url() {
  local tag="$VULKAN_HEADERS_TAG" repo="$VULKAN_HEADERS_REPO"

  if [[ -z "$tag" ]]; then
    tag="$(git ls-remote --tags --refs "https://github.com/${repo}.git" 2>/dev/null \
           | awk -F/ '{print $NF}' \
           | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
           | sort -V | tail -1)"
  fi

  if [[ -z "$tag" ]]; then
    tag="$(curl -fsSL "https://api.github.com/repos/${repo}/tags?per_page=100" 2>/dev/null \
           | python3 -c '
import json,re,sys
try: tags = json.load(sys.stdin)
except Exception: sys.exit(1)
ok = [t["name"] for t in tags if re.fullmatch(r"v\d+\.\d+\.\d+", t["name"])]
if not ok: sys.exit(1)
print(max(ok, key=lambda s: tuple(int(p) for p in s[1:].split("."))))' 2>/dev/null)"
  fi

  [[ -n "$tag" ]] || die "cannot resolve a Vulkan-Headers tag.
Pin one explicitly, e.g.:  VULKAN_HEADERS_TAG=v1.4.309 ./build-wine.sh
(browse https://github.com/${repo}/tags for the current list)"

  say "Vulkan-Headers: $tag"
  printf 'https://github.com/%s/archive/refs/tags/%s.tar.gz' "$repo" "$tag"
}

dep_vulkan_headers() {
  local src url
  url="$(_resolve_vulkan_headers_url)"
  src="$(extract "$(fetch "$url" "vulkan-headers-$(basename "$url")")")"
  mkdir -p "$ARCH_PREFIX/include"
  cp -a "$src/include/vulkan" "$ARCH_PREFIX/include/" 2>/dev/null || true
  cp -a "$src/include/vk_video" "$ARCH_PREFIX/include/" 2>/dev/null || true
  [[ -f "$ARCH_PREFIX/include/vulkan/vulkan.h" ]] \
    || die "Vulkan headers did not install correctly"
}

_moltenvk_build_universal() {
  local out="$BUILD/moltenvk/libMoltenVK.dylib"
  [[ -f "$out" ]] && { printf '%s' "$out"; return 0; }
  mkdir -p "$BUILD/moltenvk"

  local found=""
  if [[ "$MOLTENVK_FROM_SOURCE" == "1" ]]; then
    local src mvklog
    src="$(extract "$(fetch "$MOLTENVK_URL")")"
    mvklog="$(start_log moltenvk.log)"

    # MoltenVK is driven by xcodebuild, which resolves $CC as a single
    # executable path -- our "clang -arch arm64" makes it look for a binary of
    # that literal name.  It also produces its own universal slices, so hand it
    # a pristine environment and let the Xcode project decide everything except
    # the deployment target.
    local -a xcenv=(
      env
      -u CC -u CXX -u OBJC -u OBJCXX
      -u CFLAGS -u CXXFLAGS -u OBJCFLAGS -u CPPFLAGS -u LDFLAGS
      -u PKG_CONFIG -u PKG_CONFIG_PATH -u PKG_CONFIG_LIBDIR
      -u SDKROOT
      MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
    )

    # Discard any half-finished Xcode state from an earlier failed attempt; the
    # cloned dependency sources under External/ are kept.
    rm -rf "$src/External/build" "$src/build" "$src/Package"

    ( cd "$src" \
      && "${xcenv[@]}" ./fetchDependencies --macos \
      && "${xcenv[@]}" make macos \
    ) >> "$mvklog" 2>&1 \
      || die "MoltenVK build failed -- see $mvklog

To skip the source build and use Khronos's official universal 1.4.1 binary
(still audited for minos ${DEPLOYMENT_TARGET} by verify-bundle.sh), re-run with:
    MOLTENVK_FROM_SOURCE=0 ./build-wine.sh"
    found="$(find "$src/Package" -name libMoltenVK.dylib -type f 2>/dev/null | head -1)"
  else
    local tarball dir
    tarball="$(fetch "$MOLTENVK_PREBUILT_URL" "MoltenVK-macos-${MOLTENVK_VERSION}.tar")"
    dir="$BUILD/moltenvk/unpacked"
    rm -rf "$dir"; mkdir -p "$dir"
    tar -xf "$tarball" -C "$dir" || die "cannot unpack MoltenVK release tar"
    found="$(find "$dir" -name libMoltenVK.dylib -type f 2>/dev/null | head -1)"
  fi

  [[ -n "$found" ]] || die "libMoltenVK.dylib not found after MoltenVK stage"
  cp -p "$found" "$out"
  chmod u+w "$out"
  install_name_tool -id "@rpath/libMoltenVK.dylib" "$out" 2>/dev/null || true
  sign_macho "$out"
  printf '%s' "$out"
}

dep_moltenvk() {
  local uni; uni="$(_moltenvk_build_universal)"
  mkdir -p "$ARCH_PREFIX/lib"
  if lipo -archs "$uni" | tr ' ' '\n' | grep -qx "$ARCH"; then
    lipo -thin "$ARCH" "$uni" -output "$ARCH_PREFIX/lib/libMoltenVK.dylib" 2>/dev/null \
      || cp -p "$uni" "$ARCH_PREFIX/lib/libMoltenVK.dylib"
  else
    warn "MoltenVK has no $ARCH slice; the $ARCH prefix will link against the fat binary"
    cp -p "$uni" "$ARCH_PREFIX/lib/libMoltenVK.dylib"
  fi
  chmod u+w "$ARCH_PREFIX/lib/libMoltenVK.dylib"
  install_name_tool -id "@rpath/libMoltenVK.dylib" "$ARCH_PREFIX/lib/libMoltenVK.dylib" 2>/dev/null || true
  sign_macho "$ARCH_PREFIX/lib/libMoltenVK.dylib"

  # Wine's configure looks for a vulkan loader; point it at MoltenVK directly.
  ln -sf libMoltenVK.dylib "$ARCH_PREFIX/lib/libvulkan.1.dylib"
  ln -sf libMoltenVK.dylib "$ARCH_PREFIX/lib/libvulkan.dylib"
}

build_deps_for_arch() {
  set_arch "$1"
  step "Stage 2: runtime libraries ($ARCH)"
  once "dep-freetype-$ARCH"       dep_freetype
  once "dep-gmp-$ARCH"            dep_gmp
  once "dep-nettle-$ARCH"         dep_nettle
  once "dep-libtasn1-$ARCH"       dep_libtasn1
  once "dep-gnutls-$ARCH"         dep_gnutls
  once "dep-sdl2-$ARCH"           dep_sdl2
  once "dep-ffmpeg-$ARCH"         dep_ffmpeg
  once "dep-vulkanhdr-$ARCH"      dep_vulkan_headers
  once "dep-moltenvk-$ARCH"       dep_moltenvk
}
