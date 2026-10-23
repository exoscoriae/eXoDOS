# shellcheck shell=bash
# ============================================================================
# scripts/bootstrap.sh — build/obtain the HOST build tools without Brew/MacPorts.
#
# These tools run on the build machine only; none of them are bundled into the
# .app.  We get them from upstream source/release tarballs:
#   * pkgconf  — built from source (our pkg-config implementation)
#   * nasm     — built from source (assembler for x264/x265/ffmpeg/dav1d/...)
#   * cmake    — official Kitware universal binary (no compilation)
#   * meson + ninja — via pip into an isolated venv using the system python3
#
# Everything installs under $TOOLS_PREFIX and is put on PATH by set_arch_env.
# ============================================================================

bootstrap_tools() {
  scrub_env
  mkdir -p "$TOOLS_PREFIX/bin" "$DL_DIR" "$SRC_DIR"
  detect_sdk

  # --- sanity: compiler + python present ---
  command -v clang >/dev/null  || die "clang not found (install Xcode Command Line Tools)"
  command -v python3 >/dev/null|| die "python3 not found (ships with the CLT)"
  command -v git >/dev/null    || die "git not found (ships with the CLT)"

  _bootstrap_pkgconf
  _bootstrap_nasm
  _bootstrap_cmake
  _bootstrap_meson_ninja
  _bootstrap_autotools   # only if a dep needs autoreconf (e.g. zimg)

  # Make the tools visible for the rest of bootstrap.
  export PATH="$TOOLS_PREFIX/bin:$VENV/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  ok "Host tools ready:"
  printf '      pkgconf %s\n' "$("$TOOLS_PREFIX"/bin/pkgconf --version)"
  printf '      nasm    %s\n' "$("$TOOLS_PREFIX"/bin/nasm -v | awk '{print $3}')"
  printf '      cmake   %s\n' "$("$TOOLS_PREFIX"/bin/cmake --version | head -1 | awk '{print $3}')"
  printf '      meson   %s\n' "$(meson --version)"
  printf '      ninja   %s\n' "$(ninja --version)"
}

# pkgconf is built native (host arch only) — it's a tool, not a bundled lib.
_bootstrap_pkgconf() {
  [ -x "$TOOLS_PREFIX/bin/pkgconf" ] && { ok "pkgconf cached"; _link_pkgconfig_alias; return; }
  fetch "$PKGCONF_URL"
  local d; d="$(extract "$DL_DIR/$(basename "$PKGCONF_URL")")"
  ( cd "$d"
    CC=clang CFLAGS="-O2" ./configure --prefix="$TOOLS_PREFIX" \
        --with-system-libdir=/usr/lib --with-system-includedir=/usr/include
    make -j"$JOBS"; make install )
  _link_pkgconfig_alias
}
_link_pkgconfig_alias() {
  # Many build systems invoke `pkg-config`; alias it to pkgconf.
  ln -sf "$TOOLS_PREFIX/bin/pkgconf" "$TOOLS_PREFIX/bin/pkg-config"
}

_bootstrap_nasm() {
  [ -x "$TOOLS_PREFIX/bin/nasm" ] && { ok "nasm cached"; return; }
  fetch "$NASM_URL"
  local d; d="$(extract "$DL_DIR/$(basename "$NASM_URL")")"
  ( cd "$d"
    CC=clang CFLAGS="-O2" ./configure --prefix="$TOOLS_PREFIX"
    make -j"$JOBS"; make install )
}

_bootstrap_cmake() {
  [ -x "$TOOLS_PREFIX/bin/cmake" ] && { ok "cmake cached"; return; }
  fetch "$CMAKE_URL"
  local d; d="$(extract "$DL_DIR/$(basename "$CMAKE_URL")")"
  # The macOS release ships as CMake.app; expose its CLI tools.
  local appbin
  appbin="$(find "$d" -maxdepth 3 -type d -name 'bin' -path '*CMake.app*' | head -1)"
  [ -n "$appbin" ] || die "could not locate cmake bin inside $d"
  local t
  for t in cmake ctest cpack; do ln -sf "$appbin/$t" "$TOOLS_PREFIX/bin/$t"; done
}

_bootstrap_meson_ninja() {
  VENV="$TOOLS_PREFIX/venv"
  if [ ! -x "$VENV/bin/meson" ]; then
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install --upgrade pip wheel >/dev/null
    "$VENV/bin/pip" install "meson>=1.4.0" ninja >/dev/null
  else
    ok "meson/ninja cached"
  fi
  ln -sf "$VENV/bin/meson" "$TOOLS_PREFIX/bin/meson"
  ln -sf "$VENV/bin/ninja" "$TOOLS_PREFIX/bin/ninja"
}

# GNU autotools (m4 -> autoconf -> automake -> libtool), built from source for
# the build host only. Required to run autoreconf for dependencies that ship no
# pre-generated configure (currently only zimg). Skipped unless ENABLE_ZIMG=1.
_bootstrap_autotools() {
  [ "${ENABLE_ZIMG:-0}" = 1 ] || { ok "autotools not needed (zimg disabled)"; return 0; }
  # These tools must find each other (and our GNU m4) on PATH while building.
  export PATH="$TOOLS_PREFIX/bin:${VENV:-$TOOLS_PREFIX/venv}/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  _host_build m4       "$M4_URL"       "bin/m4"
  export M4="$TOOLS_PREFIX/bin/m4"
  _host_build autoconf "$AUTOCONF_URL" "bin/autoconf"
  _host_build automake "$AUTOMAKE_URL" "bin/automake"
  _host_build libtool  "$LIBTOOL_URL"  "bin/libtoolize"
  ok "autotools ready: $("$TOOLS_PREFIX"/bin/autoconf --version | head -1)"
}

# Build one host (native-arch) autotools helper into $TOOLS_PREFIX.
_host_build() {  # _host_build <name> <url> <check-relpath>
  local name="$1" url="$2" check="$3"
  [ -x "$TOOLS_PREFIX/$check" ] && { ok "$name cached"; return 0; }
  log "building host tool: $name"
  fetch "$url"
  local d; d="$(extract "$DL_DIR/$(basename "$url")")"
  ( cd "$d"
    # Newer clang defaults make some old gnulib code error on implicit decls.
    CC=clang CFLAGS="-O2 -Wno-implicit-function-declaration -Wno-implicit-int" \
      ./configure --prefix="$TOOLS_PREFIX" --disable-dependency-tracking
    make -j"$JOBS"
    make install )
}
