#!/usr/bin/env bash
#
# 02e-agl-stub.sh — install an empty stub AGL.framework into each CraftRoot's lib/.
#
# Why: the macOS 26 SDK removed the legacy AGL framework. Qt 6.7.3 still emits a
# `-framework AGL` link line when desktop OpenGL is enabled, so QtGui fails with
# "ld: framework 'AGL' not found". We KEEP OpenGL on (KDE needs Qt6::OpenGLWidgets),
# and instead satisfy the dangling link with an empty AGL.framework that:
#   - lives in $ROOT/lib, which Qt already adds to the framework search path (-F),
#     so the build-time link resolves;
#   - has install_name @rpath/AGL.framework/Versions/A/AGL, so the recorded runtime
#     dependency points into the app bundle (macdeployqt copies it), NOT at the
#     system AGL (which is absent on macOS 15+). Result: runs on macOS 11 through 26.
#
# Qt 6 makes no AGL function calls on macOS (its GL path is Cocoa/Metal), so the
# stub exporting no symbols is safe — there are no undefined AGL symbols to satisfy.
# ---------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"

command -v clang >/dev/null || die "clang not found (install Xcode command-line tools)."

make_stub() {
  local root="$1" arch="$2"
  local fw="$root/lib/AGL.framework"
  local bin="$fw/Versions/A/AGL"

  mkdir -p "$fw/Versions/A/Resources"

  # Empty translation unit -> empty dylib (no exported/needed symbols).
  local tmpc; tmpc="$(mktemp -t aglstub).c"
  printf '\n' > "$tmpc"
  clang -dynamiclib -arch "$arch" -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" \
        -install_name "@rpath/AGL.framework/Versions/A/AGL" \
        -o "$bin" "$tmpc"
  rm -f "$tmpc"

  # A framework MUST be a well-formed bundle or `codesign --deep` rejects it with
  # "bundle format unrecognized, invalid, or unsuitable" (which broke 04's signing).
  # That means a Versions/A/Resources/Info.plist plus the conventional symlinks.
  cat > "$fw/Versions/A/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>AGL</string>
  <key>CFBundleIdentifier</key><string>org.kde.okular.agl-stub</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>AGL</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
</dict>
</plist>
PLIST

  # Framework symlinks (Versions/Current, top-level binary, top-level Resources).
  ln -sfn A "$fw/Versions/Current"
  ln -sfn Versions/Current/AGL "$fw/AGL"
  ln -sfn Versions/Current/Resources "$fw/Resources"

  printf '   stub AGL.framework (%s) -> %s\n' "$arch" "$bin"
}

for arch in "${ARCHES[@]}"; do
  root="$(craft_root_for "$arch")"
  [[ -d "$root/lib" ]] || die "Root lib dir missing for $arch ($root/lib). Bootstrap first."
  log "[$arch] Installing stub AGL.framework"
  make_stub "$root" "$arch"
done

log "AGL stubs in place. Re-enable OpenGL build of qtbase:"
log "   rm -rf \"$CRAFT_ROOT_ARM64/build/libs/qt6/qtbase\" \"$CRAFT_ROOT_X86_64/build/libs/qt6/qtbase\""
log "then ./03-build-arch.sh <arch> (or build-all)."
