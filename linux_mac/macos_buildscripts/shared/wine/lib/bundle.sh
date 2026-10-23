#!/usr/bin/env bash
# lib/bundle.sh -- assemble, relocate and sign wine.app.
# shellcheck shell=bash

APP_ID="org.winehq.wine"

# --------------------------------------------------------------------------
# Path helpers
# --------------------------------------------------------------------------
relpath() { python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$1" "$2"; }

# Give a Mach-O file an @loader_path rpath that reaches the bundle's lib dir.
add_lib_rpath() {
  local f="$1" libdir="$2" rel
  rel="$(relpath "$libdir" "$(dirname "$f")")"
  [[ "$rel" == "." ]] && rel=""
  install_name_tool -add_rpath "@loader_path${rel:+/$rel}" "$f" 2>/dev/null || true
}

# EXECUTE / DYLIB / BUNDLE / OBJECT ... .  Scans for the keyword rather than a
# fixed column so it works for fat binaries too, where otool -hv prints one
# header block per architecture.
macho_filetype() {
  /usr/bin/otool -hv "$1" 2>/dev/null | awk '
    { for (i = 1; i <= NF; i++)
        if ($i ~ /^(EXECUTE|DYLIB|BUNDLE|OBJECT|DYLINKER|PRELOAD|CORE|DSYM)$/) { print $i; exit } }'
}

# --------------------------------------------------------------------------
# Copy the per-arch prefixes into the bundle as universal binaries
# --------------------------------------------------------------------------
copy_universal_dir() {
  local rel="$1" dest="$2" pattern="$3"
  local xroot="$BUILD/prefix-x86_64/$rel"
  [[ -d "$xroot" ]] || return 0
  mkdir -p "$dest"

  local f base
  while IFS= read -r -d '' f; do
    base="$(basename "$f")"
    install_universal_lib "$rel/$base" "$dest"
  done < <(find "$xroot" -maxdepth 1 -type f -name "$pattern" -print0)

  # Recreate version symlinks (libfoo.dylib -> libfoo.30.dylib)
  while IFS= read -r -d '' f; do
    base="$(basename "$f")"
    ln -sf "$(readlink "$f")" "$dest/$base"
  done < <(find "$xroot" -maxdepth 1 -type l -name "$pattern" -print0)
}

bundle_copy_payload() {
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$WINE_ROOT_IN_APP"

  say "copying wine tree"
  cp -a "$WINE_INSTALL/." "$WINE_ROOT_IN_APP/"

  say "copying support libraries"
  copy_universal_dir "lib" "$WINE_ROOT_IN_APP/lib" '*.dylib'
  copy_universal_dir "lib/gstreamer-1.0" "$WINE_ROOT_IN_APP/lib/gstreamer-1.0" '*.dylib'
  copy_universal_dir "libexec/gstreamer-1.0" "$WINE_ROOT_IN_APP/libexec/gstreamer-1.0" '*'

  # Nothing from the build prefixes' headers, pkgconfig, static libs or
  # documentation belongs in a shipped bundle.
  rm -rf "$WINE_ROOT_IN_APP/include" "$WINE_ROOT_IN_APP/lib/pkgconfig" \
         "$WINE_ROOT_IN_APP/share/man" "$WINE_ROOT_IN_APP/share/doc" \
         "$WINE_ROOT_IN_APP/share/gtk-doc" "$WINE_ROOT_IN_APP/share/aclocal"
  find "$WINE_ROOT_IN_APP" -name '*.la' -delete 2>/dev/null || true
  find "$WINE_ROOT_IN_APP" -name '*.a' -delete 2>/dev/null || true

  local n
  n="$(find "$WINE_ROOT_IN_APP/lib" -maxdepth 1 -name '*.dylib' -type f | wc -l | tr -d ' ')"
  ok "$n support libraries bundled"
}

# --------------------------------------------------------------------------
# Make every dependency reference bundle-relative
# --------------------------------------------------------------------------
bundle_relocate() {
  local libdir="$WINE_ROOT_IN_APP/lib"
  local f base dep rp changed=0 external=0 stripped=0

  say "rewriting install names"
  while IFS= read -r -d '' f; do
    base="$(basename "$f")"
    chmod u+w "$f" 2>/dev/null || true

    case "$(macho_filetype "$f")" in
      DYLIB|BUNDLE) install_name_tool -id "@rpath/$base" "$f" 2>/dev/null || true ;;
    esac

    while read -r dep; do
      case "$dep" in
        /usr/lib/*|/System/Library/*|@rpath/*|@loader_path/*|@executable_path/*)
          ;;
        /*)
          # Anything else is a build-tree absolute path and must be rewritten.
          install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$f" 2>/dev/null \
            && changed=$((changed+1)) \
            || { warn "could not rewrite $dep in $base"; external=$((external+1)); }
          ;;
      esac
      # Tab-indented lines only: a universal binary's otool -L output has an
      # unindented "<path> (architecture arm64):" header for each slice.
    done < <(/usr/bin/otool -L "$f" | awk '/^\t/{print $1}')

    # Strip absolute rpaths before adding our own.  These come from two places:
    # libtool and meson both bake -Wl,-rpath,<build prefix>/lib into everything
    # they link, and we add one deliberately for Wine's host tools.  Any that
    # survived would tie the bundle to this machine's build directory.
    while read -r rp; do
      case "$rp" in
        @loader_path*|@executable_path*|"") ;;
        *) install_name_tool -delete_rpath "$rp" "$f" 2>/dev/null \
             && stripped=$((stripped+1)) || true ;;
      esac
    done < <(/usr/bin/otool -l "$f" | awk '/LC_RPATH/{r=1} r&&/^ *path /{print $2; r=0}')

    add_lib_rpath "$f" "$libdir"
  done < <(macho_find0 "$APP")

  ok "$changed dependency paths rewritten to @rpath"
  ok "$stripped absolute rpath(s) removed"
  (( external == 0 )) || warn "$external references could not be rewritten"
}

# --------------------------------------------------------------------------
# Bundle metadata
# --------------------------------------------------------------------------
bundle_info_plist() {
  cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>            <string>wine</string>
    <key>CFBundleIdentifier</key>            <string>${APP_ID}</string>
    <key>CFBundleName</key>                  <string>wine</string>
    <key>CFBundleDisplayName</key>           <string>Wine</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleSignature</key>             <string>????</string>
    <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
    <key>CFBundleShortVersionString</key>    <string>${WINE_VERSION}</string>
    <key>CFBundleVersion</key>               <string>${WINE_VERSION}</string>
    <key>CFBundleIconFile</key>              <string>wine.icns</string>
    <key>LSMinimumSystemVersion</key>        <string>${DEPLOYMENT_TARGET}</string>
    <key>LSApplicationCategoryType</key>     <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>       <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key> <true/>
    <key>NSRequiresAquaSystemAppearance</key><false/>

    <!-- Without these strings macOS denies the corresponding TCC prompt
         outright instead of asking the user, and the feature silently fails. -->
    <key>NSMicrophoneUsageDescription</key>
    <string>A Windows program running under Wine is requesting microphone access.</string>
    <key>NSCameraUsageDescription</key>
    <string>A Windows program running under Wine is requesting camera access.</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>Wine maps your Desktop into the Windows environment.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>Wine maps your Documents folder into the Windows environment.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>Wine maps your Downloads folder into the Windows environment.</string>
    <key>NSRemovableVolumesUsageDescription</key>
    <string>Wine exposes removable volumes to Windows programs as drive letters.</string>
    <key>NSNetworkVolumesUsageDescription</key>
    <string>Wine exposes network volumes to Windows programs as drive letters.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Wine uses AppleScript to install Rosetta 2 when it is missing.</string>

    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>      <string>Windows Executable</string>
            <key>CFBundleTypeRole</key>      <string>Shell</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.microsoft.windows-executable</string>
                <string>com.microsoft.windows-installer-package</string>
                <string>com.microsoft.windows-dynamic-link-library</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
EOF
  printf 'APPL????' > "$APP/Contents/PkgInfo"
}

# A generated icon so the bundle does not fall back to the blank document icon.
# Purely cosmetic: failures here never fail the build.
bundle_icon() {
  local work="$BUILD/wine.iconset"
  local out="$APP/Contents/Resources/wine.icns"
  local ico=""

  # Wine ships a number of .ico resources.  Prefer its own branding, then any
  # icon that names itself after wine, and only then give up.  WINE_ICON lets
  # this be overridden without editing the script.
  # logo.ico is the Wine logo proper -- a 194x313 glass, stored as a 256-class
  # PNG entry.  winecfg.ico is the control-panel applet's icon: the same glass
  # but overlaid with a gear and a window, which is wrong for the app itself.
  local candidates=(
    "${WINE_ICON:-}"
    "$WINE_SRC/programs/winecfg/logo.ico"
    "$WINE_SRC/programs/winecfg/winecfg.ico"
    "$WINE_SRC/dlls/user32/resources/oic_winlogo.ico"
  )
  local c
  for c in "${candidates[@]}"; do
    [[ -n "$c" && -f "$c" ]] && { ico="$c"; break; }
  done
  if [[ -z "$ico" ]]; then
    ico="$(find "$WINE_SRC" -name '*wine*.ico' -print -quit 2>/dev/null || true)"
  fi
  if [[ -z "$ico" ]]; then
    ico="$(find "$WINE_SRC" -name '*.ico' -print -quit 2>/dev/null || true)"
  fi
  if [[ -z "$ico" ]]; then
    warn "no .ico found in the Wine tree; bundle will use the default icon"
    return 0
  fi

  say "building the app icon from ${ico#$WINE_SRC/}"
  rm -rf "$work"
  python3 "$SCRIPT_DIR/src/ico2iconset.py" "$ico" "$work" \
    || { warn "could not convert $(basename "$ico"); keeping the default icon"; return 0; }
  iconutil -c icns "$work" -o "$out" 2>/dev/null \
    || { warn "iconutil failed; keeping the default icon"; rm -rf "$work"; return 0; }
  rm -rf "$work"

  [[ -s "$out" ]] || die "iconutil reported success but produced no $out"
  ok "app icon: wine.icns from ${ico#$WINE_SRC/} ($(du -h "$out" | cut -f1 | tr -d ' '))"
}

bundle_launcher() {
  say "compiling universal launcher"
  clang -arch arm64 -arch x86_64 \
        -mmacosx-version-min="$DEPLOYMENT_TARGET" -isysroot "$SDKROOT" \
        -O2 -Wall -Wextra -Wno-unused-parameter \
        -Wl,-headerpad_max_install_names \
        -o "$APP/Contents/MacOS/wine" "$SCRIPT_DIR/src/launcher.c" \
    || die "launcher failed to compile"

  local archs; archs="$(lipo -archs "$APP/Contents/MacOS/wine")"
  [[ "$archs" == *arm64* && "$archs" == *x86_64* ]] \
    || die "launcher is not universal (got: $archs)"
  ok "launcher: $archs"
}

# --------------------------------------------------------------------------
# Signing
#
# Executables get the JIT entitlements; dylibs and plugins are signed plain.
# Entitlements do not survive exec(), so it is not enough to sign only
# Contents/MacOS/wine -- the real loader, wineserver, the preloader and every
# other helper Wine spawns each need their own.
# --------------------------------------------------------------------------
bundle_sign() {
  local ents="$SCRIPT_DIR/src/wine.entitlements"
  local f n_exe=0 n_lib=0

  # Entitlements requested, and why (kept out of the .plist because AMFI's
  # parser rejects XML comments -- see the validation below):
  #
  #   allow-jit                        MAP_JIT pages
  #   allow-unsigned-executable-memory arbitrary RWX mappings (Wine's PE loader)
  #   disable-library-validation       load our own unsigned bundled dylibs
  #   allow-dyld-environment-variables permit DYLD_* for debugging/winetricks
  #
  # Wine's PE loader maps Windows code pages writable and then executes them,
  # and both wined3d and any JIT inside a guest program (wine-mono's .NET
  # runtime, for one) need the same relaxation.  Apple Silicon enforces W^X by
  # default, so without these the bundle dies as soon as a guest generates code.
  #
  # Deliberately NOT requested: disable-executable-page-protection -- a
  # restricted entitlement macOS only honours for Apple-issued signatures.
  #
  # codesign will happily accept an entitlements file the kernel later refuses,
  # so validate it here instead of failing at load time.
  [[ -f "$ents" ]] || die "entitlements file missing: $ents"
  grep -q '<!--' "$ents" \
    && die "entitlements contain an XML comment; AMFI rejects those -- $ents"
  plutil -lint "$ents" >/dev/null 2>&1 \
    || die "entitlements are not a valid plist: $ents"
  ok "entitlements validated"

  say "removing extended attributes"
  xattr -cr "$APP" 2>/dev/null || true

  say "signing bundle contents"
  while IFS= read -r -d '' f; do
    case "$(macho_filetype "$f")" in
      EXECUTE) sign_macho "$f" "$ents"; n_exe=$((n_exe+1)) ;;
      *)       sign_macho "$f";         n_lib=$((n_lib+1)) ;;
    esac
  done < <(macho_find0 "$APP")

  # Sign the bundle last so its seal covers everything above.
  codesign --force --sign - --timestamp=none \
           --entitlements "$ents" "$APP" \
    || die "failed to sign $APP"

  codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/      /' \
    || die "signature verification failed"

  ok "signed $n_exe executables and $n_lib libraries"
}

# --------------------------------------------------------------------------
# Manifest
#
# Records exactly what went into the bundle.  verify-bundle.sh reads it, and
# it is the first thing to look at when a bundle misbehaves months later.
# --------------------------------------------------------------------------
bundle_manifest() {
  local m="$APP/Contents/Resources/BUILD-INFO.txt"
  {
    echo "wine.app -- portable Wine for macOS"
    echo "built            $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "wine             ${WINE_VERSION}"
    echo "wine-gecko       ${GECKO_VERSION} (x86, x86_64)"
    echo "wine-mono        ${MONO_VERSION}"
    echo "deployment tgt   macOS ${DEPLOYMENT_TARGET}"
    echo "unix arch        x86_64 (Rosetta 2 on Apple Silicon)"
    echo "pe archs         i386, x86_64"
    echo "universal libs   ${UNIVERSAL_DEPS}"
    echo "sdk              $(xcrun --show-sdk-version 2>/dev/null)"
    echo "built on         macOS $(sw_vers -productVersion) / $(uname -m)"
    echo
    echo "bundled libraries"
    echo "  freetype       ${FREETYPE_VERSION}"
    echo "  gnutls         ${GNUTLS_VERSION} (nettle ${NETTLE_VERSION}, gmp ${GMP_VERSION}, libtasn1 ${LIBTASN1_VERSION})"
    echo "  SDL2           ${SDL2_VERSION}"
    echo "  FFmpeg         ${FFMPEG_VERSION}"
    echo "  MoltenVK       ${MOLTENVK_VERSION}"
    echo "  glib           ${GLIB_VERSION}"
    echo "  GStreamer      ${GST_VERSION}"
    echo
    echo "sha256 of bundled addons"
    (cd "$WINE_ROOT_IN_APP/share/wine" && find gecko mono -type f -name '*.msi' \
       -exec shasum -a 256 {} \; 2>/dev/null) | sed 's/^/  /'
  } > "$m"
  ok "wrote $(basename "$m")"
}

build_bundle() {
  step "Stage 5: assemble wine.app"
  APP="$OUTPUT_DIR/wine.app"
  WINE_ROOT_IN_APP="$APP/Contents/Resources/wine"
  mkdir -p "$OUTPUT_DIR"

  bundle_copy_payload
  bundle_manifest
  bundle_info_plist
  bundle_icon
  bundle_launcher
  bundle_relocate
  bundle_sign

  local size
  size="$(du -sh "$APP" | awk '{print $1}')"
  ok "wine.app assembled ($size) at $APP"
}
