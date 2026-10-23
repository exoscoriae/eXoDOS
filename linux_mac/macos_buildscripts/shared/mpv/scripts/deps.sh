# shellcheck shell=bash
# ============================================================================
# scripts/deps.sh — recipes for every bundled dependency.
#
# Each dep_* function builds ONE library for the current $ARCH (set by the
# caller via set_arch_env) directly into the live $PREFIX. build_all_deps()
# builds the whole ordered sequence once per arch, snapshots $PREFIX after each
# arch, then lipo-merges the snapshots into the universal $PREFIX.
#
# Ordering respects the dependency graph: compression -> text -> codecs ->
# colour/gpu -> discs -> ffmpeg -> scripting/extras.
# ============================================================================

# ---------------------------------------------------------------------------
# System-library pkg-config shims.
#
# Because PKG_CONFIG_LIBDIR is pinned to our prefix (for isolation), libraries
# that locate a *system* library via pkg-config — notably zlib, which libpng,
# freetype, etc. look up with PKG_CHECK_MODULES(zlib) — won't find it. zlib is
# part of every macOS (/usr/lib/libz, headers in the SDK), is OS-versioned so it
# can never be "too new", and /usr/lib refs are allowed by the verifier. We
# therefore drop a zlib.pc that points at the system copy. Written per-arch into
# the staged pkgconfig dir so it's visible during that arch's builds and merged
# into the final prefix afterwards.
# ---------------------------------------------------------------------------
provide_system_pcs() {
  local zv
  zv="$(awk -F'"' '/define[ \t]+ZLIB_VERSION/{print $2}' "$SDKROOT/usr/include/zlib.h" 2>/dev/null)"
  [ -n "$zv" ] || zv="1.2.11"
  cat <<EOF | write_pc zlib
prefix=/usr
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: zlib
Description: zlib compression library (macOS system copy)
Version: $zv
Libs: -lz
Cflags:
EOF
  ok "[$ARCH] system zlib.pc shim (zlib $zv)"
}

# Convenience: download+extract a tarball, echo its srcdir, skip if already built.
_prep() {   # _prep <stampname> <url>  -> echoes srcdir (empty if already built)
  local stamp="$1" url="$2"
  is_built "$stamp" && { ok "[$ARCH] $stamp cached"; return 1; }
  fetch "$url"
  extract "$DL_DIR/$(basename "$url")"
}

# ---------------------------------------------------------------------------
# Compression base
# ---------------------------------------------------------------------------
dep_xz()    { local d; d="$(_prep xz "$XZ_URL")" || return 0
  run_autotools "$d" --disable-static --enable-shared --disable-xz \
      --disable-xzdec --disable-lzmadec --disable-lzmainfo --disable-doc
  mark_built xz; }

dep_zstd()  { local d; d="$(_prep zstd "$ZSTD_URL")" || return 0
  run_cmake "$d/build/cmake" -DZSTD_BUILD_PROGRAMS=OFF -DZSTD_BUILD_STATIC=OFF \
      -DZSTD_BUILD_SHARED=ON -DZSTD_LEGACY_SUPPORT=OFF
  mark_built zstd; }

dep_libpng(){ local d; d="$(_prep libpng "$LIBPNG_URL")" || return 0
  run_autotools "$d" --disable-static --enable-shared
  mark_built libpng; }

# ---------------------------------------------------------------------------
# Text / subtitle stack
# ---------------------------------------------------------------------------
dep_expat() { local d; d="$(_prep expat "$EXPAT_URL")" || return 0
  run_autotools "$d" --disable-static --enable-shared \
      --without-docbook --without-examples --without-tests
  mark_built expat; }

dep_freetype() { local d; d="$(_prep freetype "$FREETYPE_URL")" || return 0
  # First-pass freetype WITHOUT harfbuzz to break the freetype<->harfbuzz cycle.
  run_autotools "$d" --disable-static --enable-shared \
      --without-harfbuzz --without-brotli --with-png=yes --with-bzip2=no
  mark_built freetype; }

dep_fribidi() { local d; d="$(_prep fribidi "$FRIBIDI_URL")" || return 0
  run_meson "$d" -Ddocs=false -Dbin=false -Dtests=false
  mark_built fribidi; }

dep_harfbuzz() { local d; d="$(_prep harfbuzz "$HARFBUZZ_URL")" || return 0
  run_meson "$d" -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled \
      -Dcairo=disabled -Dicu=disabled -Dtests=disabled \
      -Ddocs=disabled -Dutilities=disabled
  mark_built harfbuzz; }

dep_fontconfig() { local d; d="$(_prep fontconfig "$FONTCONFIG_URL")" || return 0
  # Keep config/cache under our own prefix (NOT the system /etc and /var, which
  # we have no permission to write and must not touch). Teach fontconfig to scan
  # the standard macOS font directories so libass can find fonts on a clean
  # system. (Note: on macOS libass also has the native CoreText font provider,
  # so subtitle font matching works even if fontconfig's config isn't present.)
  # RUN_FC_CACHE_TEST=false: skip the fc-cache run during `make install`.
  # fontconfig 2.18 builds a system font cache at install time, which scans the
  # host's font tree and aborts on looped directories under
  # /System/Library/AssetsV2 on current macOS. We don't need a build-time cache
  # (the bundled lib builds per-user caches at runtime), so disable it.
  MAKE_INSTALL_VARS="RUN_FC_CACHE_TEST=false" \
  run_autotools "$d" --disable-static --enable-shared --disable-docs \
      --sysconfdir="$PREFIX/etc" --localstatedir="$PREFIX/var" \
      --with-add-fonts=/System/Library/Fonts,/Library/Fonts,~/Library/Fonts
  mark_built fontconfig; }

dep_libunibreak() { local d; d="$(_prep libunibreak "$LIBUNIBREAK_URL")" || return 0
  run_autotools "$d" --disable-static --enable-shared
  mark_built libunibreak; }

dep_libass() { local d; d="$(_prep libass "$LIBASS_URL")" || return 0
  run_autotools "$d" --disable-static --enable-shared \
      --enable-fontconfig --enable-libunibreak
  mark_built libass; }

# ---------------------------------------------------------------------------
# Audio codecs
# ---------------------------------------------------------------------------
dep_libogg()   { local d; d="$(_prep libogg "$OGG_URL")" || return 0
  run_autotools "$d" --disable-static --enable-shared; mark_built libogg; }

dep_libvorbis(){ local d; d="$(_prep libvorbis "$VORBIS_URL")" || return 0
  run_autotools "$d" --disable-static --enable-shared; mark_built libvorbis; }

dep_opus()     { local d; d="$(_prep opus "$OPUS_URL")" || return 0
  run_autotools "$d" --disable-static --enable-shared --disable-doc --disable-extra-programs
  mark_built opus; }

dep_flac()     { local d; d="$(_prep flac "$FLAC_URL")" || return 0
  run_autotools "$d" --disable-static --enable-shared --disable-cpplibs \
      --disable-doxygen-docs --disable-examples --disable-programs
  mark_built flac; }

dep_libtheora(){ local d; d="$(_prep libtheora "$THEORA_URL")" || return 0
  # theora 1.1.1 ships ancient asm; disable for clean universal builds.
  # Its libtheoraenc references th_comment_* from libtheoradec but never links
  # it, so the modern linker errors on the undefined symbols. Permit runtime
  # resolution (ffmpeg always loads libtheoradec alongside libtheoraenc).
  # Scoped to this recipe only.
  local saved="$LDFLAGS"
  export LDFLAGS="$LDFLAGS -Wl,-undefined,dynamic_lookup"
  run_autotools "$d" --disable-static --enable-shared --disable-examples \
      --disable-spec --disable-asm --disable-doc
  export LDFLAGS="$saved"
  mark_built libtheora; }

dep_lame()     { local d; d="$(_prep lame "$LAME_URL")" || return 0
  # LAME 3.100 exports the obsolete symbol lame_init_old in include/libmp3lame.sym
  # but never defines it, so -exported_symbols_list makes the link fail. Drop it.
  sed -i '' '/lame_init_old/d' "$d/include/libmp3lame.sym" 2>/dev/null || true
  run_autotools "$d" --disable-static --enable-shared --disable-frontend --enable-nasm
  mark_built lame; }

dep_fdkaac()   { local d; d="$(_prep fdkaac "$FDKAAC_URL")" || return 0
  run_autotools "$d" --disable-static --enable-shared; mark_built fdkaac; }

# ---------------------------------------------------------------------------
# Video codecs
# ---------------------------------------------------------------------------
dep_dav1d()  { local d; d="$(_prep dav1d "$DAV1D_URL")" || return 0
  run_meson "$d" -Denable_tools=false -Denable_tests=false; mark_built dav1d; }

dep_svtav1() { local d; d="$(_prep svtav1 "$SVTAV1_URL")" || return 0
  run_cmake "$d" -DBUILD_APPS=OFF -DBUILD_TESTING=OFF -DBUILD_DEC=ON -DBUILD_ENC=ON
  mark_built svtav1; }

dep_aom()    { is_built aom && { ok "[$ARCH] aom cached"; return 0; }
  local d; d="$(git_src "$AOM_GIT" "v$AOM_VER" aom)"
  run_cmake "$d" -DENABLE_TESTS=0 -DENABLE_TOOLS=0 -DENABLE_EXAMPLES=0 \
      -DENABLE_DOCS=0 -DCONFIG_AV1_ENCODER=1 -DCONFIG_AV1_DECODER=1
  mark_built aom; }

dep_libvpx() { local d; d="$(_prep libvpx "$VPX_URL")" || return 0
  # Build OUT OF TREE (per-arch dir) so the arm64 and x86_64 passes never share
  # objects or the generated vpx_config/rtcd. Also wipe any stale in-source
  # build left by an earlier in-tree build of the other arch.
  ( cd "$d" && make distclean >/dev/null 2>&1 || true )
  local target bdir="$d/_b.$ARCH"
  case "$ARCH" in
    arm64)  target="arm64-darwin20-gcc" ;;
    x86_64) target="x86_64-darwin20-gcc" ;;
  esac
  rm -rf "$bdir"; mkdir -p "$bdir"
  ( cd "$bdir"
    "$d/configure" --prefix="$PREFIX" --target="$target" \
        --enable-pic --enable-shared --disable-static \
        --enable-vp8 --enable-vp9 --enable-vp9-highbitdepth \
        --disable-examples --disable-tools --disable-docs --disable-unit-tests \
        --extra-cflags="$CFLAGS" --extra-cxxflags="$CXXFLAGS"
    make -j"$JOBS"
    make install )
  mark_built libvpx; }

dep_x264()   { is_built x264 && { ok "[$ARCH] x264 cached"; return 0; }
  local d; d="$(git_src "$X264_GIT" stable x264)"
  ( cd "$d" && make distclean >/dev/null 2>&1 || true )   # clear any in-source build
  local bdir="$d/_b.$ARCH"; rm -rf "$bdir"; mkdir -p "$bdir"
  local host_args=()
  is_cross "$ARCH" && host_args+=( --host="$(arch_triple "$ARCH")" --cross-prefix="" )
  ( cd "$bdir"
    # NB: do NOT pass --extra-asflags=$CFLAGS — on x86_64 the assembler is nasm,
    # which rejects clang flags like -arch/-isysroot. x264 derives the correct
    # nasm flags from --host itself; ARM .S files are assembled by the C compiler
    # which already gets the arch via --extra-cflags.
    "$d/configure" --prefix="$PREFIX" --enable-shared --disable-cli --enable-pic \
        --extra-cflags="$CFLAGS" --extra-ldflags="$LDFLAGS" \
        "${host_args[@]}"
    make -j"$JOBS"
    make install )
  mark_built x264; }

dep_x265()   { local d; d="$(_prep x265 "$X265_URL")" || return 0
  # Default 8-bit "main" profile (multilib 10/12-bit on universal is impractical).
  run_cmake "$d/source" -DENABLE_SHARED=ON -DENABLE_CLI=OFF -DSTATIC_LINK_CRT=OFF
  mark_built x265; }

dep_libwebp(){ local d; d="$(_prep libwebp "$WEBP_URL")" || return 0
  run_autotools "$d" --disable-static --enable-shared \
      --enable-libwebpmux --enable-libwebpdemux
  mark_built libwebp; }

dep_zimg()   { local d; d="$(_prep zimg "$ZIMG_URL")" || return 0
  # zimg's source archive ships no configure; generate it with the host
  # autotools we bootstrapped (idempotent — only the first arch pass runs it).
  [ -x "$d/configure" ] || ( cd "$d" && autoreconf -fi )
  # Build OUT OF TREE per arch (VPATH). zimg builds static "convenience"
  # sub-libraries and then links the final dylib; with -arch only in CFLAGS its
  # libtool link defaulted to the host arch and discarded the freshly-built
  # x86_64 objects (empty library). Embed -arch in CC/CXX so libtool bakes it
  # into the link too, and keep -arch OUT of CFLAGS to avoid duplicate-arch.
  ( cd "$d" && make distclean >/dev/null 2>&1 || true )
  local bdir="$d/_b.$ARCH"; rm -rf "$bdir"; mkdir -p "$bdir"
  local host_args=() af="-arch $ARCH -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -isysroot $SDKROOT"
  is_cross "$ARCH" && host_args+=( --host="$(arch_triple "$ARCH")" )
  ( cd "$bdir"
    CC="clang $af" CXX="clang++ $af" \
    CFLAGS="-O2 -Wno-implicit-function-declaration" CXXFLAGS="-O2" \
    CPPFLAGS="-I$PREFIX/include" \
    LDFLAGS="-L$PREFIX/lib -Wl,-headerpad_max_install_names" \
    "$d/configure" --prefix="$PREFIX" --disable-dependency-tracking \
        --disable-static --enable-shared "${host_args[@]}"
    make -j"$JOBS"
    make install )
  # Guard: a broken cross build has silently produced an empty libzimg. A real
  # libzimg exports the zimg_* API — verify before stamping so we fail here with
  # a clear message instead of confusingly at ffmpeg's detection.
  nm -gjU "$PREFIX/lib/libzimg.dylib" 2>/dev/null | grep -q zimg_get_api_version \
    || die "zimg produced an empty library (no zimg_get_api_version exported)"
  mark_built zimg; }

# ---------------------------------------------------------------------------
# Colour / image
# ---------------------------------------------------------------------------
dep_lcms2()  { local d; d="$(_prep lcms2 "$LCMS2_URL")" || return 0
  run_autotools "$d" --disable-static --enable-shared; mark_built lcms2; }

dep_jpegturbo() { local d; d="$(_prep jpegturbo "$JPEGTURBO_URL")" || return 0
  run_cmake "$d" -DENABLE_SHARED=ON -DENABLE_STATIC=OFF -DWITH_JPEG8=1 -DWITH_TURBOJPEG=ON
  mark_built jpegturbo; }

# ---------------------------------------------------------------------------
# GPU: libplacebo (OpenGL backend) + optional Vulkan stack
# ---------------------------------------------------------------------------
dep_vulkan_headers() { is_built vkheaders && return 0
  local d; d="$(git_src "$VULKAN_HEADERS_GIT" "$VULKAN_HEADERS_VER" Vulkan-Headers)"
  run_cmake "$d"; mark_built vkheaders; }

dep_vulkan_loader() { is_built vkloader && return 0
  local d; d="$(git_src "$VULKAN_LOADER_GIT" "$VULKAN_LOADER_VER" Vulkan-Loader)"
  run_cmake "$d" -DCMAKE_PREFIX_PATH="$PREFIX" -DBUILD_TESTS=OFF \
      -DVULKAN_HEADERS_INSTALL_DIR="$PREFIX"
  mark_built vkloader; }

dep_glslang() { is_built glslang && return 0
  local d; d="$(git_src "$GLSLANG_GIT" "$GLSLANG_VER" glslang)"
  # ENABLE_OPT=0 avoids the external SPIRV-Tools dependency; libplacebo is happy
  # with glslang's built-in front end for SPIR-V generation.
  run_cmake "$d" -DENABLE_OPT=0 -DENABLE_GLSLANG_BINARIES=OFF -DBUILD_SHARED_LIBS=OFF \
      -DBUILD_EXTERNAL=OFF
  mark_built glslang; }

dep_moltenvk() { is_built moltenvk && return 0
  local d; d="$(git_src "$MOLTENVK_GIT" "$MOLTENVK_VER" MoltenVK)"
  ( cd "$d"
    ./fetchDependencies --macos
    xcodebuild build -quiet -project MoltenVKPackaging.xcodeproj \
        -scheme "MoltenVK Package (macOS only)" \
        -configuration Release \
        MACOSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" ONLY_ACTIVE_ARCH=NO
    local out="Package/Release/MoltenVK/dynamic/dylib/macOS"
    local dst="$PREFIX"
    install -d "$dst/lib" "$dst/share/vulkan/icd.d"
    cp "$out/libMoltenVK.dylib" "$dst/lib/"
    cp "$out/MoltenVK_icd.json" "$dst/share/vulkan/icd.d/" 2>/dev/null || true )
  mark_built moltenvk; }

dep_libplacebo() { is_built libplacebo && { ok "[$ARCH] libplacebo cached"; return 0; }
  local d; d="$(git_src "$LIBPLACEBO_GIT" "$LIBPLACEBO_VER" libplacebo --recursive)"
  local vk=disabled glsl=disabled
  if [ "$ENABLE_VULKAN" = 1 ]; then vk=enabled; glsl=enabled; fi
  run_meson "$d" \
      -Dvulkan="$vk" -Dglslang="$glsl" -Dshaderc=disabled \
      -Dopengl=enabled -Dd3d11=disabled \
      -Dlcms=enabled \
      -Ddemos=false -Dtests=false -Dbench=false
  mark_built libplacebo; }

# ---------------------------------------------------------------------------
# Optical media
# ---------------------------------------------------------------------------
dep_libxml2() { local d; d="$(_prep libxml2 "$LIBXML2_URL")" || return 0
  run_autotools "$d" --disable-static --enable-shared --without-python \
      --with-lzma="$PREFIX" --with-zlib
  mark_built libxml2; }

dep_libdvdcss() { local d; d="$(_prep libdvdcss "$LIBDVDCSS_URL")" || return 0
  # libdvdcss 1.5.0+ builds with Meson (autotools dropped upstream).
  run_meson "$d"; mark_built libdvdcss; }

dep_libdvdread() { local d; d="$(_prep libdvdread "$LIBDVDREAD_URL")" || return 0
  # libdvdread 7.0.0+ builds with Meson. It dlopen()s libdvdcss at runtime, so
  # no explicit dvdcss link option is needed.
  run_meson "$d"
  mark_built libdvdread; }

dep_libdvdnav() { local d; d="$(_prep libdvdnav "$LIBDVDNAV_URL")" || return 0
  # libdvdnav 7.0.0+ builds with Meson (finds libdvdread via pkg-config).
  run_meson "$d"; mark_built libdvdnav; }

dep_libbluray() { local d; d="$(_prep libbluray "$LIBBLURAY_URL")" || return 0
  # libbluray 1.4.0+ builds with Meson. BD-Java is off by default in the Meson
  # build (no JDK/ant on the host), so plain defaults give the C library with
  # menu rendering. If a future release flips a relevant default, add the
  # explicit feature flag here (run `meson configure` in the build dir to list
  # option names) rather than guessing.
  run_meson "$d"
  mark_built libbluray; }

dep_libcdio() { local d; d="$(_prep libcdio "$LIBCDIO_URL")" || return 0
  run_autotools "$d" --disable-static --enable-shared --disable-cxx \
      --without-cd-drive --without-cd-info --without-cd-paranoia \
      --without-cdda-player --without-iso-info --without-iso-read \
      --disable-example-progs
  mark_built libcdio; }

dep_libcdio_paranoia() { local d; d="$(_prep libcdio_paranoia "$LIBCDIO_PARANOIA_URL")" || return 0
  run_autotools "$d" --disable-static --enable-shared --disable-example-progs
  mark_built libcdio_paranoia; }

# ---------------------------------------------------------------------------
# Opt-in network (TLS)
# ---------------------------------------------------------------------------
dep_openssl() { local d; d="$(_prep openssl "$OPENSSL_URL")" || return 0
  local cfg
  case "$ARCH" in
    arm64)  cfg="darwin64-arm64-cc" ;;
    x86_64) cfg="darwin64-x86_64-cc" ;;
  esac
  ( cd "$d"
    ./Configure "$cfg" shared no-tests --prefix="$PREFIX" \
        --openssldir="$PREFIX/etc/ssl" \
        -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET"
    make -j"$JOBS"
    make install_sw )
  mark_built openssl; }

dep_srt() { local d; d="$(_prep srt "$SRT_URL")" || return 0
  run_cmake "$d" -DCMAKE_PREFIX_PATH="$PREFIX" -DENABLE_APPS=OFF \
      -DENABLE_SHARED=ON -DENABLE_STATIC=OFF -DUSE_OPENSSL_PC=ON
  mark_built srt; }

dep_rist() { local d; d="$(_prep rist "$RIST_URL")" || return 0
  run_meson "$d" -Dbuilt_tools=false -Dtest=false; mark_built rist; }

# ---------------------------------------------------------------------------
# FFmpeg — links most of the above.  Built per-arch (uses nasm on x86_64).
# ---------------------------------------------------------------------------
dep_sdl2() { local d; d="$(_prep sdl2 "$SDL2_URL")" || return 0
  # Shared SDL2 for FFmpeg's ffplay. CMake build installs libSDL2 + sdl2.pc
  # (so ffmpeg's --enable-sdl2 finds it via pkg-config). macOS frameworks are
  # weak-linked; CMAKE_OSX_DEPLOYMENT_TARGET pins the 11.0 floor (set by run_cmake).
  run_cmake "$d" -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TEST=OFF
  mark_built sdl2; }

dep_ffmpeg() { local d; d="$(_prep ffmpeg "$FFMPEG_URL")" || return 0
  local ex=()
  # Codec / format libraries, gated by the same toggles used to build them.
  [ "$ENABLE_AV1" = 1 ]          && ex+=( --enable-libdav1d --enable-libaom --enable-libsvtav1 )
  [ "$ENABLE_VPX" = 1 ]          && ex+=( --enable-libvpx )
  [ "$ENABLE_X264" = 1 ]         && ex+=( --enable-libx264 )
  [ "$ENABLE_X265" = 1 ]         && ex+=( --enable-libx265 )
  [ "$ENABLE_AUDIO_CODECS" = 1 ] && ex+=( --enable-libopus --enable-libvorbis --enable-libtheora --enable-libmp3lame )
  [ "$ENABLE_WEBP" = 1 ]         && ex+=( --enable-libwebp )
  [ "$ENABLE_ZIMG" = 1 ]         && ex+=( --enable-libzimg )
  [ "$ENABLE_TEXT" = 1 ]         && ex+=( --enable-libfreetype --enable-libfontconfig --enable-libfribidi --enable-libharfbuzz )
  [ "$ENABLE_DISC" = 1 ]         && ex+=( --enable-libxml2 --enable-libbluray )
  [ "$ENABLE_FDK_AAC" = 1 ]      && ex+=( --enable-libfdk-aac )
  [ "$ENABLE_SRT" = 1 ]          && ex+=( --enable-libsrt )
  [ "$ENABLE_RIST" = 1 ]         && ex+=( --enable-librist )

  # TLS backend: SecureTransport (default, GPL-clean, no extra dylib) vs OpenSSL.
  if [ "$ENABLE_OPENSSL" = 1 ]; then
    ex+=( --enable-openssl --enable-nonfree )
  else
    ex+=( --enable-securetransport )
  fi
  # fdk-aac is also nonfree.
  [ "$ENABLE_FDK_AAC" = 1 ] && ex+=( --enable-nonfree )

  # Command-line programs. Default: libs only (--disable-programs, for mpv).
  # With ENABLE_FFMPEG_TOOLS, also build ffmpeg/ffprobe (on by default) and
  # ffplay (needs SDL2) so the ffmpeg.app bundle has its binaries.
  local progflags=( --disable-programs )
  if [ "${ENABLE_FFMPEG_TOOLS:-0}" = 1 ]; then
    progflags=( --enable-ffplay --enable-sdl2 )
  fi

  local cross=()
  if is_cross "$ARCH"; then
    cross+=( --enable-cross-compile --arch="$ARCH" --target-os=darwin --cc="clang" )
  fi

  # Build OUT OF TREE per arch so the arm64 and x86_64 passes never share
  # objects or the generated config/asm (FFmpeg has per-arch assembly).
  ( cd "$d" && make distclean >/dev/null 2>&1 || true )
  local bdir="$d/_b.$ARCH"; rm -rf "$bdir"; mkdir -p "$bdir"
  ( cd "$bdir"
    "$d/configure" --prefix="$PREFIX" \
        --enable-shared --disable-static \
        --enable-gpl --enable-version3 \
        "${progflags[@]}" --disable-doc --disable-debug \
        --enable-pthreads --enable-network \
        --enable-videotoolbox --enable-audiotoolbox \
        --enable-zlib --enable-bzlib --enable-lzma \
        --extra-cflags="$CFLAGS -I$PREFIX/include" \
        --extra-cxxflags="$CXXFLAGS" \
        --extra-ldflags="$LDFLAGS" \
        --pkg-config="$PKG_CONFIG" \
        "${cross[@]}" "${ex[@]}"
    make -j"$JOBS"
    make install )
  mark_built ffmpeg; }

# ---------------------------------------------------------------------------
# Scripting + extras
# ---------------------------------------------------------------------------
dep_lua() { local d; d="$(_prep lua "$LUA_URL")" || return 0
  # Build a static liblua.a for THIS arch. We bake -arch (via $COMMON_FLAGS)
  # directly into CC and build the `a` target instead of Lua's `macosx`
  # convenience target — `macosx` re-invokes make with CC=cc, which would
  # otherwise discard our arch and produce a host-arch (arm64) archive even on
  # the x86_64 pass (then merge_arch can't lipo arm64+arm64 -> universal).
  # `make clean` drops any stale objects from the other arch's pass.
  ( cd "$d/src"
    make clean >/dev/null 2>&1 || true
    make a CC="clang $COMMON_FLAGS" MYCFLAGS="-DLUA_USE_MACOSX" RANLIB="ranlib" )
  mkdir -p "$PREFIX/lib" "$PREFIX/include"
  cp "$d/src/liblua.a" "$PREFIX/lib/liblua.a"
  local h
  for h in lua.h luaconf.h lualib.h lauxlib.h lua.hpp; do
    [ -f "$d/src/$h" ] && cp "$d/src/$h" "$PREFIX/include/"
  done
  # Vanilla Lua ships no pkg-config file; synthesize the names mpv looks for.
  local body="prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: Lua
Description: Lua language engine
Version: $LUA_VER
Libs: -L\${libdir} -llua -lm
Cflags: -I\${includedir}"
  local n
  for n in lua52 lua5.2 lua-5.2; do printf '%s\n' "$body" | write_pc "$n"; done
  mark_built lua; }

dep_mujs() { local d; d="$(_prep mujs "$MUJS_URL")" || return 0
  # Static libmujs.a linked into libmpv (no dylib to relocate). Bake -arch into
  # CC (via $COMMON_FLAGS) and set build=release directly rather than via the
  # `release` target, which recurses into a fresh make that would drop our arch
  # on the cross pass — yielding an arm64 archive that can't be lipo-merged.
  ( cd "$d"
    make clean >/dev/null 2>&1 || true
    make install prefix="$PREFIX" build=release CC="clang $COMMON_FLAGS" )
  # Guarantee a pkg-config file exists (older MuJS revisions don't ship one).
  local pc; pc="$PREFIX/lib/pkgconfig/mujs.pc"
  if [ ! -f "$pc" ]; then
    cat <<EOF | write_pc mujs
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: mujs
Description: MuJS embeddable Javascript interpreter
Version: $MUJS_VER
Libs: -L\${libdir} -lmujs
Cflags: -I\${includedir}
EOF
  fi
  mark_built mujs; }

dep_libarchive() { local d; d="$(_prep libarchive "$LIBARCHIVE_URL")" || return 0
  run_autotools "$d" --disable-static --enable-shared \
      --without-openssl --without-xml2 --without-expat \
      --disable-bsdtar --disable-bsdcpio --disable-bsdcat
  mark_built libarchive; }

dep_uchardet() { local d; d="$(_prep uchardet "$UCHARDET_URL")" || return 0
  run_cmake "$d" -DBUILD_BINARY=OFF -DBUILD_STATIC=OFF
  mark_built uchardet; }

dep_rubberband() { local d; d="$(_prep rubberband "$RUBBERBAND_URL")" || return 0
  # rubberband 4.0.0's src/common/mathmisc.h declares functions using a bare
  # `size_t` without including <stddef.h>; clang 21 + libc++ only expose
  # std::size_t and reject it. Prepend the C header (defines the global
  # ::size_t) so the bare name resolves. Idempotent + arch-independent (source
  # patch, so it fixes both the native and cross builds).
  local mm="$d/src/common/mathmisc.h"
  if [ -f "$mm" ] && ! grep -q 'stddef\.h' "$mm"; then
    { printf '#include <stddef.h>\n'; cat "$mm"; } > "$mm.fixup" && mv "$mm.fixup" "$mm"
  fi
  # builtin FFT + resampler => no FFTW (GPL) and no libsamplerate dependency.
  run_meson "$d" -Dfft=builtin -Dresampler=builtin -Djni=disabled \
      -Dcmdline=disabled -Dtests=disabled
  mark_built rubberband; }

# ===========================================================================
# Orchestration
# ===========================================================================
_deps_sequence() {
  # system-library pkg-config shims (zlib) must exist before anything that
  # looks zlib up via pkg-config (libpng, freetype, ...).
  provide_system_pcs

  # base compression
  dep_xz; dep_zstd; dep_libpng

  # text / subtitles
  if [ "$ENABLE_TEXT" = 1 ]; then
    dep_expat; dep_freetype; dep_fribidi; dep_harfbuzz; dep_fontconfig; dep_libunibreak
  fi
  dep_libass   # libass is effectively core

  # audio codecs
  if [ "$ENABLE_AUDIO_CODECS" = 1 ]; then
    dep_libogg; dep_libvorbis; dep_opus; dep_flac; dep_libtheora; dep_lame
  fi
  [ "$ENABLE_FDK_AAC" = 1 ] && dep_fdkaac

  # video codecs
  [ "$ENABLE_AV1" = 1 ] && { dep_dav1d; dep_svtav1; dep_aom; }
  [ "$ENABLE_VPX" = 1 ] && dep_libvpx
  [ "$ENABLE_X264" = 1 ] && dep_x264
  [ "$ENABLE_X265" = 1 ] && dep_x265
  [ "$ENABLE_WEBP" = 1 ] && dep_libwebp
  [ "$ENABLE_ZIMG" = 1 ] && dep_zimg

  # colour / image
  dep_lcms2
  [ "$ENABLE_JPEG" = 1 ] && dep_jpegturbo

  # gpu
  if [ "$ENABLE_VULKAN" = 1 ]; then
    dep_vulkan_headers; dep_vulkan_loader; dep_glslang; dep_moltenvk
  fi
  dep_libplacebo

  # discs
  if [ "$ENABLE_DISC" = 1 ]; then
    dep_libxml2; dep_libdvdcss; dep_libdvdread; dep_libdvdnav
    dep_libbluray; dep_libcdio; dep_libcdio_paranoia
  fi

  # opt-in network
  [ "$ENABLE_OPENSSL" = 1 ] && dep_openssl
  [ "$ENABLE_SRT" = 1 ] && dep_srt
  [ "$ENABLE_RIST" = 1 ] && dep_rist

  # SDL2 (only needed for ffplay in the ffmpeg.app tools build) — before ffmpeg.
  [ "${ENABLE_FFMPEG_TOOLS:-0}" = 1 ] && dep_sdl2

  # ffmpeg (after all of its external libs)
  dep_ffmpeg

  # scripting + audio filter extras
  [ "$ENABLE_LUA" = 1 ] && dep_lua
  [ "$ENABLE_JAVASCRIPT" = 1 ] && dep_mujs
  [ "$ENABLE_LIBARCHIVE" = 1 ] && dep_libarchive
  [ "$ENABLE_UCHARDET" = 1 ] && dep_uchardet
  [ "$ENABLE_RUBBERBAND" = 1 ] && dep_rubberband
}

build_all_deps() {
  local a snap
  for a in "${ARCHS[@]}"; do
    snap="$(arch_snapshot_dir "$a")"
    if [ -d "$snap" ]; then
      ok "================  $a already built (snapshot present)  ================"
      continue
    fi

    # Resume-aware preparation of the live prefix:
    #   * if $PREFIX is mid-build for THIS arch, keep it and let per-lib stamps
    #     skip what's done;
    #   * otherwise start clean and reset this arch's stamps.
    if [ -f "$PREFIX/.building-arch" ] && [ "$(cat "$PREFIX/.building-arch")" = "$a" ]; then
      log "resuming in-progress $a build"
    else
      rm -rf "$PREFIX"; mkdir -p "$PREFIX"
      echo "$a" > "$PREFIX/.building-arch"
      rm -f "$STAGE_DIR/.built/"*".$a" 2>/dev/null || true
    fi

    set_arch_env "$a"
    log "================  Building dependencies for $a  ================"
    _deps_sequence        # begins by writing the system zlib.pc shim

    rm -f "$PREFIX/.building-arch"
    log "snapshotting $a prefix"
    rm -rf "$snap"
    mv "$PREFIX" "$snap"
  done
  merge_arch
}

# ---------------------------------------------------------------------------
# refresh_deps <name...> — surgically rebuild specific recipes IN PLACE inside
# every existing per-arch snapshot, then re-merge the universal $PREFIX. Use
# this after fixing a single recipe instead of rebuilding the whole tree (which
# would recompile ffmpeg, x265, aom, ... twice). Each snapshot is treated as the
# live prefix for its arch so the recipe installs straight into it.
# ---------------------------------------------------------------------------
refresh_deps() {
  [ "$#" -ge 1 ] || die "refresh_deps: name(s) required (e.g. lua mujs)"
  local merged="$PREFIX" a snap n
  for a in "${ARCHS[@]}"; do
    snap="$(arch_snapshot_dir "$a")"
    [ -d "$snap" ] || die "snapshot $snap missing — run a full './build.sh deps' first"
    PREFIX="$snap"            # set_arch_env keys -L/-I/pkgconfig off $PREFIX
    set_arch_env "$a"
    log "================  Refreshing [$*] for $a  ================"
    for n in "$@"; do
      rm -f "$(built_stamp "$n")"
      "dep_$n"
    done
  done
  PREFIX="$merged"
  merge_arch
  ok "refreshed [$*] and re-merged universal prefix at $PREFIX"
}
