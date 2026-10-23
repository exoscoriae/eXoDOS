# =============================================================================
# lib/bundle.sh - assemble the final universal, relocatable Gnumeric.app
#
# Strategy:
#   1. Stage a bundle tree from each arch root (binaries, libs, data).
#   2. Rewrite every Mach-O in each tree to @rpath-relative install names.
#   3. lipo the two trees together into dist/gnumeric.app.
#   4. Add launcher, Info.plist, icon, schemas, caches; ad-hoc codesign.
# =============================================================================

GNM_VER="$(pkg_version gnumeric)"      # 1.12.61
GO_VER="$(pkg_version goffice)"        # 0.10.61
GNM_API="1.12"
GO_API="0.10"
BUNDLE_ID="org.gnumeric.Gnumeric"

MAIN_BINS="gnumeric ssconvert ssdiff ssgrep ssindex"

assemble_tree() { # <arch> <dest>
  local A="$1" T="$2" ROOT b
  ROOT="$(root_for "$A")"
  log "[$A] staging bundle tree"
  rm -rf "$T"
  mkdir -p "$T/Contents/MacOS" "$T/Contents/Resources"

  # --- executables ----------------------------------------------------------
  for b in $MAIN_BINS; do
    if [ -f "$ROOT/bin/$b" ]; then
      cp "$ROOT/bin/$b" "$T/Contents/MacOS/$b-bin"
    fi
  done
  [ -f "$T/Contents/MacOS/gnumeric-bin" ] || die "[$A] gnumeric binary missing from $ROOT/bin"
  for b in gdk-pixbuf-query-loaders gtk-query-immodules-3.0; do
    if [ -f "$ROOT/bin/$b" ]; then
      cp "$ROOT/bin/$b" "$T/Contents/MacOS/$b"
    fi
  done

  # --- libraries & loadable modules ------------------------------------------
  local RL="$T/Contents/Resources/lib"
  mkdir -p "$RL"
  # top-level dylibs (preserve version symlinks)
  ( cd "$ROOT/lib" && find . -maxdepth 1 \( -name '*.dylib' \) -print0 | \
    xargs -0 -I{} cp -a {} "$RL/" )
  # module trees needed at runtime
  local d
  for d in gnumeric goffice gdk-pixbuf-2.0 gtk-3.0; do
    if [ -d "$ROOT/lib/$d" ]; then
      cp -a "$ROOT/lib/$d" "$RL/$d"
    fi
  done
  # prune build junk
  find "$RL" \( -name '*.la' -o -name '*.a' \) -delete
  rm -rf "$RL/gtk-3.0/include"

  # --- shared data ------------------------------------------------------------
  local RS="$T/Contents/Resources/share"
  mkdir -p "$RS"
  for d in gnumeric goffice pixmaps locale icons "glib-2.0/schemas"; do
    if [ -e "$ROOT/share/$d" ]; then
      mkdir -p "$RS/$(dirname "$d")"
      cp -a "$ROOT/share/$d" "$RS/$d"
    fi
  done
  # gtk may install extra runtime data
  if [ -d "$ROOT/share/gtk-3.0" ]; then
    cp -a "$ROOT/share/gtk-3.0" "$RS/gtk-3.0"
  fi
  # (fontconfig's etc/fonts is NOT copied; the bundle ships its own fonts.conf)
  return 0
}

relocate_tree() { # <tree>  (rewrites install names; works on thin binaries)
  local T="$1"
  log "relocating Mach-O install names in $(basename "$T")"
  python3 "$TOP/lib/relocate_tree.py" "$T" \
      "$(root_for arm64)" "$(root_for x86_64)" "$TOOLS"
}

lipo_trees() { # <basetree> <othertree> <finaltree>
  # base tree = native arch (has the icon themes and full data);
  # every Mach-O in it gets fattened with its counterpart from the other tree.
  local AT="$1" XT="$2" FT="$3" f rel cnt=0 miss=0
  log "creating universal binaries (lipo)"
  rm -rf "$FT"
  cp -a "$AT" "$FT"
  while IFS= read -r f; do
    rel="${f#$AT/}"
    if [ ! -L "$f" ] && python3 "$TOP/lib/relocate_tree.py" --is-macho "$f"; then
      if [ -f "$XT/$rel" ]; then
        lipo -create "$f" "$XT/$rel" -output "$FT/$rel" \
          || die "lipo failed for $rel"
        cnt=$((cnt+1))
      else
        warn "no counterpart for $rel - staying single-arch"
        miss=$((miss+1))
      fi
    fi
  done < <(find "$AT" -type f)
  echo "  merged $cnt universal binaries ($miss unmatched)"
}

make_bundle() {
  local RA RX APP RES NROOT
  RA="$(root_for arm64)"; RX="$(root_for x86_64)"
  [ -d "$RA/lib" ] || die "arm64 root missing - run: ./build.sh deps arm64"
  [ -d "$RX/lib" ] || die "x86_64 root missing - run: ./build.sh deps x86_64"
  NROOT="$(root_for "$NATIVE_ARCH")"

  local OTHER_ARCH
  if [ "$NATIVE_ARCH" = "arm64" ]; then OTHER_ARCH="x86_64"; else OTHER_ARCH="arm64"; fi

  assemble_tree "$NATIVE_ARCH" "$WORK/bundle-$NATIVE_ARCH"
  assemble_tree "$OTHER_ARCH"  "$WORK/bundle-$OTHER_ARCH"
  relocate_tree "$WORK/bundle-$NATIVE_ARCH"
  relocate_tree "$WORK/bundle-$OTHER_ARCH"

  mkdir -p "$DIST"
  APP="$DIST/gnumeric.app"
  rm -rf "$APP"
  lipo_trees "$WORK/bundle-$NATIVE_ARCH" "$WORK/bundle-$OTHER_ARCH" "$APP"
  RES="$APP/Contents/Resources"

  # --- launcher ---------------------------------------------------------------
  log "installing launcher and metadata"
  sed -e "s|@GNM_VERSION@|$GNM_VER|g" -e "s|@GO_VERSION@|$GO_VER|g" \
      -e "s|@GNM_API@|$GNM_API|g"     -e "s|@GO_API@|$GO_API|g" \
      -e "s|@BUNDLE_ID@|$BUNDLE_ID|g" \
      "$TOP/resources/launcher.sh.in" > "$APP/Contents/MacOS/gnumeric"
  chmod +x "$APP/Contents/MacOS/gnumeric"
  local b
  for b in ssconvert ssdiff ssgrep ssindex; do
    if [ -f "$APP/Contents/MacOS/$b-bin" ]; then
      cp "$APP/Contents/MacOS/gnumeric" "$APP/Contents/MacOS/$b"
      chmod +x "$APP/Contents/MacOS/$b"
    fi
  done

  # --- Info.plist / PkgInfo ---------------------------------------------------
  sed -e "s|@GNM_VERSION@|$GNM_VER|g" -e "s|@BUNDLE_ID@|$BUNDLE_ID|g" \
      -e "s|@MACOS_MIN@|$MACOS_MIN|g" \
      "$TOP/resources/Info.plist.in" > "$APP/Contents/Info.plist"
  printf 'APPL????' > "$APP/Contents/PkgInfo"

  # --- fontconfig + gtk config -------------------------------------------------
  mkdir -p "$RES/etc/fonts" "$RES/etc/xdg/gtk-3.0"
  cp "$TOP/resources/fonts.conf" "$RES/etc/fonts/fonts.conf"
  cp "$TOP/resources/settings.ini" "$RES/etc/xdg/gtk-3.0/settings.ini"

  # --- glib schemas ------------------------------------------------------------
  if [ -d "$RES/share/glib-2.0/schemas" ]; then
    "$NROOT/bin/glib-compile-schemas" "$RES/share/glib-2.0/schemas" \
      || die "glib-compile-schemas failed"
  fi

  # --- icon caches ---------------------------------------------------------------
  local theme
  for theme in hicolor Adwaita; do
    if [ -d "$RES/share/icons/$theme" ] && [ -x "$NROOT/bin/gtk-update-icon-cache" ]; then
      "$NROOT/bin/gtk-update-icon-cache" -f -t "$RES/share/icons/$theme" || true
    fi
  done

  # --- app icon -----------------------------------------------------------------
  make_icns "$RES"

  # --- ad-hoc signing (mandatory on Apple Silicon after install_name_tool) -------
  log "ad-hoc code signing"
  xattr -cr "$APP" 2>/dev/null || true   # strip quarantine/Finder xattrs that break sealing
  while IFS= read -r f; do
    if python3 "$TOP/lib/relocate_tree.py" --is-macho "$f"; then
      codesign --force --sign - "$f" >/dev/null 2>&1 \
        || die "codesign failed for $f"
    fi
  done < <(find "$APP" -type f ! -type l)
  # the launcher and CLI wrappers are shell scripts: they must be signed too
  # (via xattr-based signatures) or the bundle seal is rejected
  local sf
  for sf in "$APP/Contents/MacOS"/*; do
    if [ -f "$sf" ] && ! python3 "$TOP/lib/relocate_tree.py" --is-macho "$sf"; then
      codesign --force --sign - "$sf" >/dev/null 2>&1 || warn "could not sign script $sf"
    fi
  done
  if ! codesign --force --sign - "$APP" 2>"$WORK/codesign.err"; then
    warn "bundle-level codesign failed (individual binaries ARE signed; app should still run):"
    sed 's/^/    /' "$WORK/codesign.err" >&2
  fi

  log "dist/gnumeric.app assembled"
  du -sh "$APP" | awk '{print "  size: "$1}'
}

make_icns() { # <resources-dir>
  local RES="$1" png iconset="$WORK/gnumeric.iconset" s
  png=""
  local cand
  for cand in "$RES/share/icons/hicolor/256x256/apps/org.gnumeric.gnumeric.png" \
              "$RES/share/icons/hicolor/256x256/apps/gnumeric.png"; do
    if [ -f "$cand" ]; then png="$cand"; break; fi
  done
  if [ -z "$png" ]; then
    warn "gnumeric 256px icon not found; skipping .icns"
    return 0
  fi
  rm -rf "$iconset"; mkdir -p "$iconset"
  for s in 16 32 128 256; do
    sips -z $s $s "$png" --out "$iconset/icon_${s}x${s}.png" >/dev/null
  done
  cp "$iconset/icon_32x32.png"   "$iconset/icon_16x16@2x.png"
  sips -z 64 64 "$png" --out "$iconset/icon_32x32@2x.png" >/dev/null
  cp "$png" "$iconset/icon_128x128@2x.png"
  iconutil -c icns "$iconset" -o "$RES/gnumeric.icns" \
    || { warn "iconutil failed; app will use generic icon"; return 0; }
}
