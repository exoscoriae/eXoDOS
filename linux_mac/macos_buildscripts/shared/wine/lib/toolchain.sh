#!/usr/bin/env bash
# lib/toolchain.sh -- build-time-only tools.  Nothing here ships in wine.app.
# shellcheck shell=bash

# --------------------------------------------------------------------------
# GNU m4 + bison
#
# macOS ships bison 2.3 (1990s-era, GPLv2 for licensing reasons).  Wine needs
# bison 3.x for its parser generators, and bison needs a real GNU m4.
# --------------------------------------------------------------------------
tc_m4() {
  local src; src="$(extract "$(fetch "$M4_URL")")"
  build_tool_autotools m4 "$src" --disable-dependency-tracking
}

tc_bison() {
  local src; src="$(extract "$(fetch "$BISON_URL")")"
  M4="$TOOLS/bin/m4" build_tool_autotools bison "$src" --disable-dependency-tracking --disable-nls
}

tc_pkgconf() {
  local src; src="$(extract "$(fetch "$PKGCONF_URL")")"
  build_tool_autotools pkgconf "$src" --disable-dependency-tracking
  ln -sf "$TOOLS/bin/pkgconf" "$TOOLS/bin/pkg-config"
}

tc_gettext() {
  local src; src="$(extract "$(fetch "$GETTEXT_URL")")"
  build_tool_autotools gettext "$src" \
    --disable-dependency-tracking --disable-java --disable-csharp \
    --disable-openmp --without-emacs --with-included-libxml \
    --without-git --without-cvs --without-bzip2 --without-xz
}

tc_nasm() {
  local src; src="$(extract "$(fetch "$NASM_URL")")"
  build_tool_autotools nasm "$src"
}

# --------------------------------------------------------------------------
# Python virtualenv holding meson + ninja (glib and GStreamer need them).
# Uses the system python3 from the Command Line Tools -- no Homebrew.
# --------------------------------------------------------------------------
tc_python() {
  python3 -m venv "$VENV" >>"$LOGDIR/tool-python.log" 2>&1 \
    || die "could not create python venv -- see $LOGDIR/tool-python.log"
  "$VENV/bin/pip" install --upgrade pip >>"$LOGDIR/tool-python.log" 2>&1 || true
  "$VENV/bin/pip" install "meson==${MESON_VERSION}" "ninja==${NINJA_VERSION}" \
    >>"$LOGDIR/tool-python.log" 2>&1 \
    || die "pip install meson/ninja failed -- see $LOGDIR/tool-python.log"
  [[ -x "$VENV/bin/meson" ]] || die "meson missing from venv"
  [[ -x "$VENV/bin/ninja" ]] || die "ninja missing from venv"
}

# Python modules that the meson builds themselves import.  glib 2.80 declares
# find_installation('python3', modules: ['packaging']) and hard-fails without
# it; several projects also still reach for pkg_resources/distutils, which
# Python 3.12 dropped from the standard library.
#
# Deliberately NOT wrapped in `once`: it is idempotent and cheap, so a venv
# created by an earlier run of this script picks up new requirements without
# anyone having to know to clear a stamp file.
PYTHON_BUILD_MODULES=(packaging setuptools wheel)

tc_python_modules() {
  local missing=() m
  for m in "${PYTHON_BUILD_MODULES[@]}"; do
    "$VENV/bin/python" -c "import ${m//-/_}" >/dev/null 2>&1 || missing+=("$m")
  done
  [[ ${#missing[@]} -eq 0 ]] && { ok "python build modules present"; return 0; }

  say "installing python modules: ${missing[*]}"
  "$VENV/bin/pip" install "${missing[@]}" >>"$LOGDIR/tool-python.log" 2>&1 \
    || die "pip install ${missing[*]} failed -- see $LOGDIR/tool-python.log"
  for m in "${missing[@]}"; do
    "$VENV/bin/python" -c "import ${m//-/_}" >/dev/null 2>&1 \
      || die "python module $m still missing after install"
  done
  ok "installed ${missing[*]}"
}

# --------------------------------------------------------------------------
# llvm-mingw: the PE cross compiler used for Wine's Windows-side DLLs.
#
# Wine 11 compiles every builtin DLL as a real PE image.  That needs a
# mingw-w64 targeting compiler for both i686 and x86_64.  We use mstorsjo's
# prebuilt universal macOS toolchain: it is a build tool only and never enters
# the app bundle, so its own minimum OS is irrelevant to the macOS 11 goal.
# --------------------------------------------------------------------------
tc_llvm_mingw() {
  local url tag json

  if [[ -n "$LLVM_MINGW_RELEASE" ]]; then
    tag="$LLVM_MINGW_RELEASE"
    url="https://github.com/${LLVM_MINGW_REPO}/releases/download/${tag}/llvm-mingw-${tag}-ucrt-macos-universal.tar.xz"
  else
    say "resolving newest llvm-mingw release"
    json="$(curl -fsSL "https://api.github.com/repos/${LLVM_MINGW_REPO}/releases/latest")" \
      || die "GitHub API request failed. Set LLVM_MINGW_RELEASE=<tag> to pin it manually."
    url="$(printf '%s' "$json" | python3 -c '
import json,re,sys
rel = json.load(sys.stdin)
pat = re.compile(sys.argv[1])
for a in rel.get("assets", []):
    if pat.search(a["name"]):
        print(a["browser_download_url"]); break
' "$LLVM_MINGW_ASSET_RE")"
    [[ -n "$url" ]] || die "no macos-universal asset in the latest llvm-mingw release.
Set LLVM_MINGW_RELEASE=<tag> to pin a known-good one."
  fi

  local tarball src
  tarball="$(fetch "$url")"
  src="$(extract "$tarball")"
  rm -rf "$MINGW_DIR"
  mkdir -p "$(dirname "$MINGW_DIR")"
  cp -a "$src" "$MINGW_DIR"

  # winebuild shells out to <target>-dlltool when generating import libraries,
  # so those wrappers matter as much as the compilers themselves.
  local t
  for t in clang i686-w64-mingw32-clang x86_64-w64-mingw32-clang \
           i686-w64-mingw32-dlltool x86_64-w64-mingw32-dlltool \
           x86_64-w64-mingw32-widl llvm-dlltool; do
    [[ -x "$MINGW_DIR/bin/$t" ]] || die "llvm-mingw is missing $t"
  done
  ok "llvm-mingw: $("$MINGW_DIR/bin/clang" --version | head -1)"
}

build_toolchain() {
  step "Stage 1: build-time toolchain"
  mkdir -p "$TOOLS/bin"
  once tool-m4        tc_m4
  once tool-bison     tc_bison
  once tool-pkgconf   tc_pkgconf
  once tool-gettext   tc_gettext
  once tool-nasm      tc_nasm
  once tool-python    tc_python
  tc_python_modules
  once tool-llvmmingw tc_llvm_mingw

  # Everything from here on must see our tools first.  $VENV/bin ahead of the
  # system python3 matters: meson resolves find_installation('python3') through
  # PATH, and only the venv interpreter has the modules installed above.
  export PATH="$VENV/bin:$TOOLS/bin:$PATH"
  ok "bison $("$TOOLS/bin/bison" --version | head -1 | awk '{print $NF}')"
  ok "pkgconf $("$TOOLS/bin/pkgconf" --version)"
  ok "msgfmt $("$TOOLS/bin/msgfmt" --version | head -1 | awk '{print $NF}')"
}
