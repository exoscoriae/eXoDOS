#!/usr/bin/env bash
# lib/toolchain.sh -- build-time-only tools.  None of this ships in the bundle.
# shellcheck shell=bash

tc_m4() {
  local src; src="$(extract "$(fetch "$M4_URL")")"
  build_tool_autotools m4 "$src" --disable-dependency-tracking
}

# Daum ships a configure.ac and autogen.sh, not a generated configure, so the
# full autotools chain is needed.  macOS provides none of it.
tc_autoconf() {
  local src; src="$(extract "$(fetch "$AUTOCONF_URL")")"
  M4="$TOOLS/bin/m4" build_tool_autotools autoconf "$src"
}

tc_automake() {
  local src; src="$(extract "$(fetch "$AUTOMAKE_URL")")"
  M4="$TOOLS/bin/m4" build_tool_autotools automake "$src"
}

tc_libtool() {
  local src; src="$(extract "$(fetch "$LIBTOOL_URL")")"
  M4="$TOOLS/bin/m4" build_tool_autotools libtool "$src" --disable-dependency-tracking
}

tc_pkgconf() {
  local src; src="$(extract "$(fetch "$PKGCONF_URL")")"
  build_tool_autotools pkgconf "$src" --disable-dependency-tracking
  ln -sf "$TOOLS/bin/pkgconf" "$TOOLS/bin/pkg-config"
}

tc_nasm() {
  local src; src="$(extract "$(fetch "$NASM_URL")")"
  build_tool_autotools nasm "$src"
}

# CMake, built by its own bootstrap script.  sdl12-compat, munt and fluidsynth
# are CMake-only and macOS ships no cmake; with Homebrew and MacPorts excluded
# there is no other way to get one.  Takes 10-15 minutes.
tc_cmake() {
  local src bdir log
  src="$(extract "$(fetch "$CMAKE_URL")")"
  bdir="$BUILD/obj/tools/cmake"
  log="$(start_log "tool-cmake.log")"
  rm -rf "$bdir"; mkdir -p "$bdir"
  ( cd "$bdir" \
    && env -u CFLAGS -u CXXFLAGS -u LDFLAGS -u CPPFLAGS -u CC -u CXX \
         MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
         "$src/bootstrap" --prefix="$TOOLS" --parallel="$(nproc_count)" -- \
           -DCMAKE_USE_OPENSSL=OFF \
    && make -j"$(nproc_count)" \
    && make install ) >> "$log" 2>&1 \
    || die "cmake bootstrap failed -- see $log"
  [[ -x "$TOOLS/bin/cmake" ]] || die "cmake was not installed"
}

build_toolchain() {
  step "Stage 1: build-time toolchain"
  mkdir -p "$TOOLS/bin"
  once tool-m4        tc_m4
  once tool-autoconf  tc_autoconf
  once tool-automake  tc_automake
  once tool-libtool   tc_libtool
  once tool-pkgconf   tc_pkgconf
  once tool-nasm      tc_nasm
  once tool-cmake     tc_cmake

  export PATH="$TOOLS/bin:$PATH"
  # autogen.sh needs to find our aclocal/automake macros rather than a system
  # set that does not exist.
  export ACLOCAL_PATH="$TOOLS/share/aclocal"
  export AUTOCONF="$TOOLS/bin/autoconf"
  export AUTOMAKE="$TOOLS/bin/automake"
  export ACLOCAL="$TOOLS/bin/aclocal"
  export AUTOHEADER="$TOOLS/bin/autoheader"
  export LIBTOOLIZE="$TOOLS/bin/libtoolize"

  ok "autoconf $("$TOOLS/bin/autoconf" --version | head -1 | awk '{print $NF}')"
  ok "automake $("$TOOLS/bin/automake" --version | head -1 | awk '{print $NF}')"
  ok "cmake $("$TOOLS/bin/cmake" --version | head -1 | awk '{print $NF}')"
}
