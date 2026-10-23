#!/usr/bin/env bash
#
# 02c-relax-toolchain.sh — tell Qt (and a few others) NOT to treat warnings as
# errors, so the 2024-era source compiles under the much newer macOS 26 / Clang 21
# toolchain. This is the reliable counterpart to the -Wno-error=* compiler flags
# in 03 (which can lose to Qt's blanket -Werror depending on flag order).
#
# Adds CMake args per blueprint via Craft's BlueprintSettings:
#   -DWARNINGS_ARE_ERRORS=OFF          (drops Qt's -Werror entirely)
#   -DQT_NO_APPLE_SDK_MAX_VERSION_CHECK=ON   (silences the "SDK too new" check)
# ---------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"
THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

QT_RELAX_ARGS="-DWARNINGS_ARE_ERRORS=OFF -DQT_NO_APPLE_SDK_MAX_VERSION_CHECK=ON -DQT_NO_APPLE_SDK_AND_XCODE_CHECK=ON $CMAKE_DEPLOY_ARG"

# qtbase: KEEP OpenGL enabled (KDE components like phonon require Qt6::OpenGLWidgets,
# which lives in qtbase and only exists when OpenGL is on). The macOS 26 SDK removed
# the legacy AGL framework that Qt 6.7.3 vestigially links; rather than disable
# OpenGL (which removes OpenGLWidgets), 02e installs an empty stub AGL.framework so
# the link resolves. Qt 6 never calls AGL functions, so the stub is a harmless no-op
# at runtime across macOS 11-26. So: no extra qtbase feature args here.
QTBASE_EXTRA_ARGS=""

# qttools only: lupdate's libclang-based C++ parser (clangtoolastreader.cpp) uses
# Clang APIs removed in Clang 20 ("no member named 'getName' in clang::FileEntry").
# lupdate only EXTRACTS translatable strings (a dev task); building Okular needs
# lrelease (.ts->.qm), which builds fine. Disable the clang-based lupdate.
QTTOOLS_EXTRA_ARGS="-DFEATURE_clang=OFF -DFEATURE_clangcpp=OFF"

run_craft() {
  local root="$1"; shift
  ( set +u; scrub_brew_env; source "$root/craft/craftenv.sh"; craft "$@" )
}

set_args() {
  local root="$1" blueprint="$2" args="$3"
  if run_craft "$root" --set "args=$args" "$blueprint" >/dev/null 2>&1; then
    printf '   relaxed %-40s\n' "$blueprint"
  else
    warn "could not set args on $blueprint (option unsupported) — relying on 03's -Wno-error flags"
  fi
}

for arch in "${ARCHES[@]}"; do
  root="$(craft_root_for "$arch")"
  [[ -f "$root/etc/CraftSettings.ini" ]] || die "Root for $arch not bootstrapped."
  log "[$arch] Disabling warnings-as-errors on Qt 6 modules"
  while IFS= read -r line; do
    line="${line%%#*}"; line="$(echo "$line" | xargs)"
    [[ -z "$line" ]] && continue
    set_args "$root" "$line" "$QT_RELAX_ARGS"
  done < "$THIS_DIR/qt6-modules.txt"
  # qtbase / qttools get the relax args PLUS their workarounds (last --set wins).
  set_args "$root" "libs/qt6/qtbase"  "$QT_RELAX_ARGS $QTBASE_EXTRA_ARGS"
  set_args "$root" "libs/qt6/qttools" "$QT_RELAX_ARGS $QTTOOLS_EXTRA_ARGS"
done

log "Toolchain relaxations set. Next: ./03-build-arch.sh arm64"
