# shellcheck shell=bash
# ============================================================================
# scripts/bundle.sh — turn the freshly built universal mpv into a portable
# mpv.app using mpv's own TOOLS/osxbundle.py (+ dylib_unhell.py).
#
# osxbundle.py:
#   * copies the .app skeleton from TOOLS/osxbundle/mpv.app
#   * copies the mpv binary into Contents/MacOS
#   * runs dylib_unhell, which walks `otool -L` recursively, copies every
#     non-system dylib into Contents/MacOS/lib, rewrites their ids and all
#     cross-references to @executable_path/lib/..., adds the matching rpath,
#     and strips dev-tool rpaths
#   * ad-hoc codesigns every Mach-O in the bundle
#
# The result references only @executable_path/lib, /usr/lib and
# /System/Library/Frameworks — i.e. it is fully relocatable.
# ============================================================================

bundle_mpv() {
  [ -n "$MPV_BUILD" ] || die "bundle_mpv called before build_mpv"
  command -v otool >/dev/null && command -v install_name_tool >/dev/null \
    || die "otool/install_name_tool missing (need Xcode Command Line Tools)"

  export PATH="$TOOLS_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin"

  # osxbundle.py must run from the mpv source root (it copies its skeleton from
  # TOOLS/osxbundle/mpv.app) but writes the finished bundle NEXT TO the binary,
  # i.e. at "$MPV_BUILD/mpv.app".
  ( cd "$MPV_SRC"
    log "running osxbundle.py (bundling + relocating all dylibs)"
    rm -rf "$MPV_BUILD/mpv.app"
    python3 TOOLS/osxbundle.py "$MPV_BUILD/mpv"
  )

  [ -d "$MPV_BUILD/mpv.app" ] || die "osxbundle.py did not produce $MPV_BUILD/mpv.app"
  mkdir -p "$DIST"
  rm -rf "$DIST/mpv.app"
  cp -a "$MPV_BUILD/mpv.app" "$DIST/mpv.app"

  # osxbundle.py's dylib_unhell can leave the main binary pointing at absolute
  # build paths (and skips relocation entirely if its dev-tool rpath cleanup
  # errors). Do it ourselves, deterministically: bundle every non-system
  # dependency and rewrite all references to @executable_path/lib.
  _relocate_app "$DIST/mpv.app"

  # Also drop libmpv next to the app for embedders who want it (optional).
  if [ -f "$MPV_BUILD/libmpv.2.dylib" ] || ls "$MPV_BUILD"/libmpv*.dylib >/dev/null 2>&1; then
    mkdir -p "$DIST/libmpv"
    cp -a "$MPV_BUILD"/libmpv*.dylib "$DIST/libmpv/" 2>/dev/null || true
    cp -a "$PREFIX/include" "$DIST/libmpv/include" 2>/dev/null || true
  fi

  _resign_if_needed "$DIST/mpv.app"

  ok "Bundle ready: $DIST/mpv.app"
  du -sh "$DIST/mpv.app" 2>/dev/null | sed 's/^/      size: /'
}

# ----------------------------------------------------------------------------
# _relocate_app — make the bundle self-contained. Breadth-first over the mpv
# binary's dependency graph: every dependency that is NOT a system library
# (/usr/lib, /System/.../Frameworks) and NOT already relocatable (@executable_path
# / @loader_path / @rpath) is copied into Contents/MacOS/lib, its id set to
# @executable_path/lib/<name>, and every referrer's load command rewritten to
# the same. Re-walks each freshly bundled dylib so transitive deps (e.g. ffmpeg
# -> libx264) come along too. Finishes with an ad-hoc re-sign (install_name_tool
# invalidates signatures).
# ----------------------------------------------------------------------------
_relocate_app() {
  local app="$1"
  local execdir="$app/Contents/MacOS"
  local libdir="$execdir/lib"
  mkdir -p "$libdir"
  command -v install_name_tool >/dev/null || die "install_name_tool missing"

  # Seed the BFS with every executable directly in Contents/MacOS (mpv.app has
  # one — `mpv`; ffmpeg.app has three — ffmpeg/ffprobe/ffplay). Dylibs live in
  # lib/ and are reached transitively.
  local queue=() processed=" " b
  while IFS= read -r b; do queue+=( "$b" ); done \
    < <(find "$execdir" -maxdepth 1 -type f -perm -u+x)
  while [ "${#queue[@]}" -gt 0 ]; do
    local cur="${queue[0]}"; queue=( "${queue[@]:1}" )
    case "$processed" in *" $cur "*) continue ;; esac
    processed+="$cur "
    [ -f "$cur" ] || continue
    chmod u+w "$cur" 2>/dev/null || true

    local dep bn src
    while IFS= read -r dep; do
      [ -z "$dep" ] && continue
      case "$dep" in
        @*|/usr/lib/*|/System/Library/Frameworks/*) continue ;;  # system / already-relocatable
      esac
      # Non-system absolute dependency -> bundle it.
      bn="$(basename "$dep")"
      if [ ! -f "$libdir/$bn" ]; then
        src=""
        if   [ -f "$dep" ];            then src="$dep"
        elif [ -f "$PREFIX/lib/$bn" ]; then src="$PREFIX/lib/$bn"
        fi
        if [ -n "$src" ]; then
          cp -L "$src" "$libdir/$bn"
          chmod u+w "$libdir/$bn"
          install_name_tool -id "@executable_path/lib/$bn" "$libdir/$bn" 2>/dev/null || true
          queue+=( "$libdir/$bn" )
        else
          warn "could not locate dependency $dep to bundle (referenced by ${cur#"$app"/})"
        fi
      fi
      install_name_tool -change "$dep" "@executable_path/lib/$bn" "$cur" 2>/dev/null || true
    done < <(otool -L "$cur" 2>/dev/null | grep -E '^[[:space:]]' | awk '{print $1}')
  done

  # Ad-hoc sign inside-out so the relocated bundle runs locally: nested dylibs
  # first, then every top-level executable, then the bundle itself.
  find "$libdir" -type f \( -name '*.dylib' -o -name '*.so' \) -exec \
       codesign --force -s - {} + 2>/dev/null || true
  find "$execdir" -maxdepth 1 -type f -perm -u+x -exec \
       codesign --force -s - {} + 2>/dev/null || true
  codesign --force -s - "$app"          2>/dev/null || true
  ok "relocated $(find "$libdir" -type f \( -name '*.dylib' -o -name '*.so' \) | wc -l | tr -d ' ') bundled libraries -> @executable_path/lib"
}

# ----------------------------------------------------------------------------
# bundle_ffmpeg — assemble dist/ffmpeg.app from the universal ffmpeg/ffprobe/
# ffplay binaries that dep_ffmpeg installed into $PREFIX/bin (they are lipo'd to
# universal by merge_arch). This is a plain CLI-tools container: the three
# binaries go in Contents/MacOS, every non-system dylib is bundled next to them
# in Contents/MacOS/lib via the same relocation pass used for mpv, and a minimal
# Info.plist is written. A caller script can then exec
# <ffmpeg.app>/Contents/MacOS/ffprobe etc. directly.
# ----------------------------------------------------------------------------
bundle_ffmpeg() {
  command -v otool >/dev/null && command -v install_name_tool >/dev/null \
    || die "otool/install_name_tool missing (need Xcode Command Line Tools)"
  export PATH="$TOOLS_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin"

  local app="$DIST/ffmpeg.app"
  local macos="$app/Contents/MacOS"
  rm -rf "$app"
  mkdir -p "$macos" "$app/Contents/Resources"

  local tools=( ffmpeg ffprobe ffplay ) t found=0
  for t in "${tools[@]}"; do
    if [ -f "$PREFIX/bin/$t" ]; then
      cp -L "$PREFIX/bin/$t" "$macos/$t"; chmod u+w "$macos/$t"; found=1
      lipo -info "$macos/$t" 2>/dev/null | sed 's/^/      /'
    else
      warn "$t not found in $PREFIX/bin — was ffmpeg built with ENABLE_FFMPEG_TOOLS=1 and deps merged?"
    fi
  done
  [ "$found" = 1 ] || die "no ffmpeg tools found in $PREFIX/bin (run: ./build.sh refresh-dep sdl2 ffmpeg)"

  cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ffmpeg</string>
  <key>CFBundleDisplayName</key><string>FFmpeg</string>
  <key>CFBundleIdentifier</key><string>org.ffmpeg.tools</string>
  <key>CFBundleVersion</key><string>${FFMPEG_VER}</string>
  <key>CFBundleShortVersionString</key><string>${FFMPEG_VER}</string>
  <key>CFBundleExecutable</key><string>ffmpeg</string>
  <key>CFBundleIconFile</key><string>ffmpeg</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>${MACOSX_DEPLOYMENT_TARGET}</string>
  <key>LSBackgroundOnly</key><true/>
</dict>
</plist>
EOF

  # Install the FFmpeg icon (Resources/ffmpeg.icns, referenced by CFBundleIconFile
  # above). Shipped base64-encoded as scripts/ffmpeg-icon.b64 so it travels with
  # the scripts and needs no macOS icon tooling. Graceful if the file is absent.
  local icon_b64="$ROOT/scripts/ffmpeg-icon.b64"
  if [ -f "$icon_b64" ]; then
    base64 -D -i "$icon_b64" -o "$app/Contents/Resources/ffmpeg.icns" 2>/dev/null \
      || base64 -d "$icon_b64" > "$app/Contents/Resources/ffmpeg.icns" 2>/dev/null \
      || openssl base64 -d -in "$icon_b64" -out "$app/Contents/Resources/ffmpeg.icns"
    [ -s "$app/Contents/Resources/ffmpeg.icns" ] && ok "installed ffmpeg.icns app icon" \
      || warn "ffmpeg.icns decode produced an empty file — check $icon_b64"
  else
    warn "icon $icon_b64 not found — ffmpeg.app will use the generic app icon"
  fi

  _relocate_app "$app"
  _resign_if_needed "$app"

  ok "Bundle ready: $app"
  du -sh "$app" 2>/dev/null | sed 's/^/      size: /'
}

# Re-sign with a real identity if the operator provided one (for distribution).
# Inside-out: sign nested dylibs first, then the app, with hardened runtime so
# the bundle can be notarized.
_resign_if_needed() {
  local app="$1"
  [ -n "$CODESIGN_IDENTITY" ] || { ok "ad-hoc signed (set CODESIGN_IDENTITY to sign for distribution)"; return 0; }
  log "re-signing with: $CODESIGN_IDENTITY"
  find "$app/Contents/MacOS/lib" -type f \( -name '*.dylib' -o -name '*.so' \) -print0 2>/dev/null \
    | xargs -0 -I{} codesign --force --timestamp --options runtime -s "$CODESIGN_IDENTITY" {}
  find "$app/Contents/MacOS" -maxdepth 1 -type f -perm -u+x -print0 \
    | xargs -0 -I{} codesign --force --timestamp --options runtime -s "$CODESIGN_IDENTITY" {}
  codesign --force --timestamp --options runtime -s "$CODESIGN_IDENTITY" "$app"
  codesign --verify --deep --strict --verbose=2 "$app"
}
