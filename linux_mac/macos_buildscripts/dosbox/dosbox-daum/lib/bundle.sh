#!/usr/bin/env bash
# lib/bundle.sh -- assemble, relocate and sign dosbox-daum.app.
# shellcheck shell=bash

APP_ID="org.dosbox.daum"

relpath() { python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$1" "$2"; }

add_lib_rpath() {
  local f="$1" libdir="$2" rel
  rel="$(relpath "$libdir" "$(dirname "$f")")"
  [[ "$rel" == "." ]] && rel=""
  install_name_tool -add_rpath "@loader_path${rel:+/$rel}" "$f" 2>/dev/null || true
}

macho_filetype() {
  /usr/bin/otool -hv "$1" 2>/dev/null | awk '
    { for (i = 1; i <= NF; i++)
        if ($i ~ /^(EXECUTE|DYLIB|BUNDLE|OBJECT|DYLINKER|PRELOAD)$/) { print $i; exit } }'
}

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
  while IFS= read -r -d '' f; do
    base="$(basename "$f")"
    ln -sf "$(readlink "$f")" "$dest/$base"
  done < <(find "$xroot" -maxdepth 1 -type l -name "$pattern" -print0)
}

# Daum is configured with -Wl,-rpath,$ARCH_PREFIX/lib so that configure's link
# tests can run (see daum_verify_sizeof).  That absolute rpath is baked into
# each slice and must come off before lipo: install_name_tool -delete_rpath is
# all-or-nothing across a fat binary's architectures, and the two slices carry
# *different* prefixes (prefix-arm64 vs prefix-x86_64), so afterwards neither
# can be removed -- which is why bundle_relocate reported "0 absolute rpath(s)
# removed" while verification still found two.
strip_abs_rpaths() {
  local f="$1" rp n=0
  chmod u+w "$f" 2>/dev/null || true
  while read -r rp; do
    case "$rp" in
      @*|"") ;;
      *) install_name_tool -delete_rpath "$rp" "$f" 2>/dev/null && n=$((n+1)) || true ;;
    esac
  done < <(/usr/bin/otool -l "$f" | awk '/LC_RPATH/{r=1} r&&/^ *path /{print $2; r=0}')
  [[ $n -gt 0 ]] && ok "stripped $n absolute rpath(s) from $(basename "$f") ($(lipo -archs "$f" 2>/dev/null))"
  return 0
}

bundle_copy_payload() {
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$DAUM_ROOT_IN_APP/bin"

  say "merging dosbox binaries into a universal executable"
  local a="$BUILD/daum-install-arm64/bin/dosbox"
  local x="$BUILD/daum-install-x86_64/bin/dosbox"
  if [[ "$UNIVERSAL_DEPS" == "1" ]]; then
    [[ -x "$a" && -x "$x" ]] || die "expected both arch builds; missing $( [[ -x $a ]] || echo arm64) $( [[ -x $x ]] || echo x86_64)"
    strip_abs_rpaths "$a"
    strip_abs_rpaths "$x"
    lipo -create "$a" "$x" -output "$DAUM_ROOT_IN_APP/bin/dosbox" \
      || die "lipo failed on the dosbox binaries"
  else
    strip_abs_rpaths "$x"
    cp -p "$x" "$DAUM_ROOT_IN_APP/bin/dosbox"
  fi
  chmod u+w "$DAUM_ROOT_IN_APP/bin/dosbox"
  ok "dosbox: $(lipo -archs "$DAUM_ROOT_IN_APP/bin/dosbox")"

  # Daum's data files (translations, mapper defaults) from either prefix.
  local share="$BUILD/daum-install-x86_64/share"
  [[ -d "$share" ]] && cp -a "$share" "$DAUM_ROOT_IN_APP/" 2>/dev/null || true

  say "copying support libraries"
  copy_universal_dir "lib" "$DAUM_ROOT_IN_APP/lib" '*.dylib'

  rm -rf "$DAUM_ROOT_IN_APP/include" "$DAUM_ROOT_IN_APP/lib/pkgconfig" \
         "$DAUM_ROOT_IN_APP/share/man" "$DAUM_ROOT_IN_APP/share/doc"
  find "$DAUM_ROOT_IN_APP" -name '*.la' -delete 2>/dev/null || true
  find "$DAUM_ROOT_IN_APP" -name '*.a'  -delete 2>/dev/null || true

  local n
  n="$(find "$DAUM_ROOT_IN_APP/lib" -maxdepth 1 -name '*.dylib' -type f | wc -l | tr -d ' ')"
  ok "$n support libraries bundled"
}

bundle_relocate() {
  local libdir="$DAUM_ROOT_IN_APP/lib"
  local f base dep rp changed=0 stripped=0

  say "rewriting install names"
  while IFS= read -r -d '' f; do
    base="$(basename "$f")"
    chmod u+w "$f" 2>/dev/null || true

    case "$(macho_filetype "$f")" in
      DYLIB|BUNDLE) install_name_tool -id "@rpath/$base" "$f" 2>/dev/null || true ;;
    esac

    while read -r dep; do
      case "$dep" in
        /usr/lib/*|/System/Library/*|@rpath/*|@loader_path/*|@executable_path/*) ;;
        /*) install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$f" 2>/dev/null \
              && changed=$((changed+1)) || warn "could not rewrite $dep in $base" ;;
      esac
      # Tab-indented lines only: a universal binary's otool -L output carries an
      # unindented "<path> (architecture arm64):" header per slice.
    done < <(/usr/bin/otool -L "$f" | awk '/^\t/{print $1}')

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
}

# Daum ships its own icon at src/dosbox.ico.  Info.plist has always named
# dosbox-daum.icns, but nothing produced it, so the bundle was showing the
# generic application icon.
bundle_icon() {
  local ico="$DAUM_SRC/src/dosbox.ico"
  local work="$BUILD/dosbox-daum.iconset"
  local out="$APP/Contents/Resources/dosbox-daum.icns"

  if [[ ! -f "$ico" ]]; then
    warn "src/dosbox.ico not found in the Daum tree; keeping the default icon"
    return 0
  fi

  say "building the app icon from Daum's own dosbox.ico"
  rm -rf "$work"
  python3 "$SCRIPT_DIR/src/ico2iconset.py" "$ico" "$work" \
    || { warn "could not convert dosbox.ico; keeping the default icon"; return 0; }
  iconutil -c icns "$work" -o "$out" 2>/dev/null \
    || { warn "iconutil failed; keeping the default icon"; rm -rf "$work"; return 0; }
  rm -rf "$work"

  # Info.plist references this by name; if it is absent macOS silently falls
  # back to the generic icon, which is exactly how this went unnoticed before.
  [[ -s "$out" ]] || die "iconutil reported success but produced no $out"
  ok "app icon: $(basename "$out") ($(du -h "$out" | cut -f1 | tr -d ' '))"
}

bundle_info_plist() {
  cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>            <string>dosbox-daum</string>
    <key>CFBundleIdentifier</key>            <string>${APP_ID}</string>
    <key>CFBundleName</key>                  <string>dosbox-daum</string>
    <key>CFBundleDisplayName</key>           <string>DOSBox Daum</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleSignature</key>             <string>????</string>
    <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
    <key>CFBundleShortVersionString</key>    <string>${DAUM_VERSION}</string>
    <key>CFBundleVersion</key>               <string>${DAUM_VERSION}</string>
    <key>CFBundleIconFile</key>              <string>dosbox-daum.icns</string>
    <key>LSMinimumSystemVersion</key>        <string>${DEPLOYMENT_TARGET}</string>
    <key>LSApplicationCategoryType</key>     <string>public.app-category.games</string>
    <key>NSHighResolutionCapable</key>       <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key> <true/>
    <key>NSRequiresAquaSystemAppearance</key><false/>

    <key>NSMicrophoneUsageDescription</key>
    <string>A DOS program running under DOSBox is requesting microphone access.</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>DOSBox can mount folders from your Desktop as DOS drives.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>DOSBox can mount folders from your Documents as DOS drives.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>DOSBox can mount folders from your Downloads as DOS drives.</string>
    <key>NSRemovableVolumesUsageDescription</key>
    <string>DOSBox can mount removable volumes as DOS drives.</string>
</dict>
</plist>
EOF
  printf 'APPL????' > "$APP/Contents/PkgInfo"
}

bundle_manifest() {
  local m="$APP/Contents/Resources/BUILD-INFO.txt"
  {
    echo "dosbox-daum.app -- portable DOSBox SVN Daum for macOS"
    echo "built            $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "daum             ${DAUM_VERSION}"
    echo "aarch64 dynrec   ${DOSBOXX_REPO}@${DOSBOXX_COMMIT} risc_armv8le.h"
    echo "deployment tgt   macOS ${DEPLOYMENT_TARGET}"
    echo "architectures    ${BUILD_ARCHS}"
    echo "sdk              $(xcrun --show-sdk-version 2>/dev/null)"
    echo "built on         macOS $(sw_vers -productVersion) / $(uname -m)"
    echo
    echo "bundled libraries"
    echo "  SDL2           ${SDL2_VERSION} + sdl12-compat ${SDL12COMPAT_VERSION}"
    echo "  SDL_net        ${SDL_NET_VERSION}"
    echo "  libpng         ${LIBPNG_VERSION}"
    echo "  MT-32          vendored in Daum (src/gui)"
    echo "  FluidSynth     ${FLUIDSYNTH_VERSION}"
    echo "  FFmpeg         ${FFMPEG_VERSION}"
  } > "$m"
  ok "wrote $(basename "$m")"
}

bundle_launcher() {
  say "compiling universal launcher"
  clang -arch arm64 -arch x86_64 \
        -mmacosx-version-min="$DEPLOYMENT_TARGET" -isysroot "$SDKROOT" \
        -O2 -Wall -Wextra -Wno-unused-parameter \
        -Wl,-headerpad_max_install_names \
        -o "$APP/Contents/MacOS/dosbox-daum" "$SCRIPT_DIR/src/launcher.c" \
    || die "launcher failed to compile"

  local archs; archs="$(lipo -archs "$APP/Contents/MacOS/dosbox-daum")"
  [[ "$archs" == *arm64* && "$archs" == *x86_64* ]] \
    || die "launcher is not universal (got: $archs)"
  ok "launcher: $archs"
}

# The entitlements we request, and why -- kept here rather than in the .plist
# because AMFI's parser rejects XML comments (see check below):
#
#   allow-jit                        MAP_JIT pages (the fallback path)
#   allow-unsigned-executable-memory plain RWX mmap (the preferred path)
#   disable-library-validation       load our own unsigned bundled dylibs
#
# The dynamic recompiler writes x86 translations into a code cache and then
# executes them.  Apple Silicon enforces write-xor-execute, so without the
# first two the cache allocation fails and DOSBox silently drops to the
# interpreter -- exactly the outcome this port exists to avoid.
#
# Deliberately NOT requested: com.apple.security.cs.disable-executable-page-
# protection.  On Apple Silicon it behaves identically to
# allow-unsigned-executable-memory, and it is a restricted entitlement macOS
# only honours for Apple-issued signatures, so on an ad-hoc signed bundle it is
# at best ignored.
bundle_sign() {
  local ents="$SCRIPT_DIR/src/dosbox-daum.entitlements"
  local f n_exe=0 n_lib=0

  # codesign accepts an entitlements file that the kernel's own loader will
  # later refuse.  AMFIUnserializeXML is far stricter than a plist parser -- an
  # XML comment alone is a syntax error -- so validate before signing rather
  # than discovering it as "failed to parse entitlements" mid-run.
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

  codesign --force --sign - --timestamp=none --entitlements "$ents" "$APP" \
    || die "failed to sign $APP"
  codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/      /' \
    || die "signature verification failed"

  ok "signed $n_exe executables and $n_lib libraries"
}

build_bundle() {
  step "Stage 4: assemble dosbox-daum.app"
  APP="$OUTPUT_DIR/dosbox-daum.app"
  DAUM_ROOT_IN_APP="$APP/Contents/Resources/daum"
  mkdir -p "$OUTPUT_DIR"

  bundle_copy_payload
  bundle_manifest
  bundle_info_plist
  bundle_icon
  bundle_launcher
  bundle_relocate
  bundle_sign

  ok "dosbox-daum.app assembled ($(du -sh "$APP" | awk '{print $1}')) at $APP"
}
