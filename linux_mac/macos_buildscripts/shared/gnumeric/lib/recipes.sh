# =============================================================================
# lib/recipes.sh - host tools + per-package build recipes
# =============================================================================

# ---------------------------------------------------------------------------
# HOST TOOLS (built natively, into $TOOLS; never shipped in the bundle)
# ---------------------------------------------------------------------------
build_host_tools() {
  log "Building host tools (native, $NATIVE_ARCH)"
  export PATH="$TOOLS/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  export MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN"

  # --- pkg-config 0.29.2 (internal glib) -----------------------------------
  if ! is_built host pkgconfig; then
    log "[host] pkg-config"
    sd="$(extract_to pkgconfig "$BLD/host")"
    ( cd "$sd" && \
      CFLAGS="-O2 -Wno-int-conversion -Wno-implicit-function-declaration" \
      ./configure --prefix="$TOOLS" --with-internal-glib --disable-host-tool \
                  --disable-dependency-tracking && \
      make -j"$NPROC" && make install )
    mark_built host pkgconfig
  fi

  # --- ninja (bootstrap from source) ----------------------------------------
  if ! is_built host ninja; then
    log "[host] ninja"
    sd="$(extract_to ninja "$BLD/host")"
    ( cd "$sd" && python3 configure.py --bootstrap && cp ninja "$TOOLS/bin/" )
    mark_built host ninja
  fi

  # --- meson (runs straight from its source tree) ---------------------------
  if ! is_built host meson; then
    log "[host] meson"
    sd="$(extract_to meson "$TOOLS")"
    cat > "$TOOLS/bin/meson" <<EOF
#!/bin/sh
exec /usr/bin/python3 "$sd/meson.py" "\$@"
EOF
    chmod +x "$TOOLS/bin/meson"
    "$TOOLS/bin/meson" --version >/dev/null || die "meson bootstrap failed"
    mark_built host meson
  fi

  # --- gettext tools (msgfmt/msgmerge/xgettext for po processing) -----------
  if ! is_built host gettext-tools; then
    log "[host] gettext (tools) - this one takes a while"
    sd="$(extract_to gettext "$BLD/host")"
    ( cd "$sd" && \
      ./configure --prefix="$TOOLS" --disable-static --disable-java \
                  --disable-dependency-tracking --disable-curses \
                  CFLAGS="-O2" && \
      make -j"$NPROC" && make install )
    mark_built host gettext-tools
  fi

  # --- perl XML::Parser (needed by intltool) --------------------------------
  if ! is_built host xmlparser; then
    if /usr/bin/perl -MXML::Parser -e1 2>/dev/null; then
      echo "system perl already has XML::Parser"
    else
      log "[host] expat + perl XML::Parser (system perl lacks it)"
      sd="$(extract_to expat "$BLD/host")"
      ( cd "$sd" && CFLAGS="-O2" ./configure --prefix="$TOOLS" \
            --without-examples --without-tests --without-docbook \
            --disable-dependency-tracking && \
        make -j"$NPROC" && make install )
      sd="$(extract_to xmlparser "$BLD/host")"
      ( cd "$sd" && \
        /usr/bin/perl Makefile.PL INSTALL_BASE="$TOOLS/perl5" \
            EXPATLIBPATH="$TOOLS/lib" EXPATINCPATH="$TOOLS/include" && \
        make && make install )
      PERL5LIB="$TOOLS/perl5/lib/perl5" /usr/bin/perl -MXML::Parser -e1 \
        || die "XML::Parser build failed"
    fi
    mark_built host xmlparser
  fi
  if [ -d "$TOOLS/perl5/lib/perl5" ]; then
    export PERL5LIB="$TOOLS/perl5/lib/perl5"
  fi

  # --- intltool (with the perl>=5.26 regex fix) ------------------------------
  if ! is_built host intltool; then
    log "[host] intltool"
    sd="$(extract_to intltool "$BLD/host")"
    # Fix "Unescaped left brace in regex is illegal" with modern perl:
    python3 - "$sd/intltool-update.in" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(r'/^(.*)\${?([A-Z_]+)}?(.*)$/', r'/^(.*)\$\{?([A-Z_]+)\}?(.*)$/')
open(p, 'w').write(s)
PYEOF
    ( cd "$sd" && ./configure --prefix="$TOOLS" && make && make install )
    mark_built host intltool
  fi

  # --- itstool stub ----------------------------------------------------------
  # gnumeric's configure requires itstool to exist; it is only *used* to build
  # translated help pages, which we skip (make HELP_LINGUAS=""). The English
  # help is plain files and installs without it.
  if [ ! -x "$TOOLS/bin/itstool" ]; then
    cat > "$TOOLS/bin/itstool" <<'EOF'
#!/bin/sh
if [ "$1" = "--version" ] || [ "$1" = "-v" ]; then echo "itstool 2.0.7"; exit 0; fi
echo "itstool stub: translated docs are disabled in this build" >&2
exit 1
EOF
    chmod +x "$TOOLS/bin/itstool"
  fi

  log "Host tools ready in work/tools"
}

# ---------------------------------------------------------------------------
# PER-PACKAGE RECIPES  (run inside a subshell with arch_env already applied)
# Each gets the arch as $1; $ROOT/$A are exported by build_one.
# ---------------------------------------------------------------------------

recipe_zlib() {
  sd="$(extract_to zlib "$BLD/$A")"
  ( cd "$sd" && ./configure --prefix="$ROOT" && make -j"$NPROC" && make install )
}

recipe_libffi() {
  sd="$(extract_to libffi "$BLD/$A")"
  autotools_build "$A" "$sd"
}

recipe_expat() {
  sd="$(extract_to expat "$BLD/$A")"
  autotools_build "$A" "$sd" --without-examples --without-tests --without-docbook
}

recipe_gettext() {  # runtime only (libintl); tools live in $TOOLS
  sd="$(extract_to gettext "$BLD/$A")"
  autotools_build "$A" "$sd/gettext-runtime" --disable-java --disable-curses
}

recipe_pcre2() {
  sd="$(extract_to pcre2 "$BLD/$A")"
  autotools_build "$A" "$sd" --enable-unicode
}

recipe_libpng() {
  sd="$(extract_to libpng "$BLD/$A")"
  autotools_build "$A" "$sd"
}

recipe_jpeg() {
  sd="$(extract_to jpeg "$BLD/$A")"
  autotools_build "$A" "$sd"
}

recipe_freetype() {
  sd="$(extract_to freetype "$BLD/$A")"
  autotools_build "$A" "$sd" --with-harfbuzz=no --with-brotli=no \
      --with-bzip2=no --with-png=yes
}

recipe_fontconfig() {
  sd="$(extract_to fontconfig "$BLD/$A")"
  autotools_build "$A" "$sd" --disable-docs --disable-nls \
      --with-add-fonts=/System/Library/Fonts,/Library/Fonts
}

recipe_glib() {
  sd="$(extract_to glib "$BLD/$A")"
  meson_build "$A" "$sd" -Dtests=false -Dman=false \
      $(meson_opt_if_exists "$sd" gtk_doc false) \
      $(meson_opt_if_exists "$sd" libmount disabled) \
      $(meson_opt_if_exists "$sd" selinux disabled)
}

recipe_libxml2() {
  sd="$(extract_to libxml2 "$BLD/$A")"
  autotools_build "$A" "$sd" --without-python --without-lzma \
      --with-zlib="$ROOT" --with-iconv
}

recipe_libxslt() {
  sd="$(extract_to libxslt "$BLD/$A")"
  autotools_build "$A" "$sd" --without-python --without-crypto
}

recipe_fribidi() {
  sd="$(extract_to fribidi "$BLD/$A")"
  meson_build "$A" "$sd" \
      $(meson_opt_if_exists "$sd" docs false) \
      $(meson_opt_if_exists "$sd" tests false) \
      $(meson_opt_if_exists "$sd" bin false)
}

recipe_harfbuzz() {
  sd="$(extract_to harfbuzz "$BLD/$A")"
  meson_build "$A" "$sd" -Dfreetype=enabled -Dglib=enabled -Dcoretext=enabled \
      -Dcairo=disabled -Dicu=disabled -Dtests=disabled -Ddocs=disabled \
      -Dintrospection=disabled \
      $(meson_opt_if_exists "$sd" chafa disabled) \
      $(meson_opt_if_exists "$sd" benchmark disabled) \
      $(meson_opt_if_exists "$sd" utilities disabled)
}

recipe_pixman() {
  sd="$(extract_to pixman "$BLD/$A")"
  # The a64-neon assembly is GNU-as syntax; Apple's clang assembler rejects
  # it. Disable it (C fast paths are used instead; x86_64 keeps SSE2/SSSE3).
  autotools_build "$A" "$sd" --disable-gtk --disable-arm-a64-neon
}

recipe_cairo() {
  sd="$(extract_to cairo "$BLD/$A")"
  meson_build "$A" "$sd" -Dquartz=enabled -Dfontconfig=enabled \
      -Dfreetype=enabled -Dglib=enabled -Dpng=enabled -Dzlib=enabled \
      -Dxlib=disabled -Dxcb=disabled -Dtests=disabled \
      $(meson_opt_if_exists "$sd" spectre disabled) \
      $(meson_opt_if_exists "$sd" symbol-lookup disabled) \
      $(meson_opt_if_exists "$sd" gtk2-utils disabled) \
      $(meson_opt_if_exists "$sd" dwrite disabled)
}

recipe_gdkpixbuf() {
  sd="$(extract_to gdkpixbuf "$BLD/$A")"
  # builtin_loaders=all compiles every no-dependency loader (png, jpeg, gif,
  # bmp, ico, ...) directly into the library => no loaders.cache required for
  # the core formats. Only librsvg's SVG loader stays dynamic.
  # gio_sniffing=false: GLib's macOS content-type backend identifies data
  # mostly by filename extension, so images decoded from memory buffers
  # (e.g. pictures embedded in ODS/XLSX files) are never recognized. Disable
  # it so gdk-pixbuf uses its own magic-byte sniffing, which handles raw
  # buffers correctly. (MacPorts does the same on macOS.)
  meson_build "$A" "$sd" -Dpng=enabled -Djpeg=enabled -Dtiff=disabled \
      -Dbuiltin_loaders=all -Dintrospection=disabled \
      $(meson_opt_if_exists "$sd" gio_sniffing false) \
      $(meson_opt_if_exists "$sd" man false) \
      $(meson_opt_if_exists "$sd" docs false) \
      $(meson_opt_if_exists "$sd" gtk_doc false) \
      $(meson_opt_if_exists "$sd" installed_tests false) \
      $(meson_opt_if_exists "$sd" tests false)
}

recipe_atk() {
  sd="$(extract_to atk "$BLD/$A")"
  meson_build "$A" "$sd" -Dintrospection=false \
      $(meson_opt_if_exists "$sd" docs false)
}

recipe_libepoxy() {
  sd="$(extract_to libepoxy "$BLD/$A")"
  meson_build "$A" "$sd" -Dglx=no -Degl=no -Dx11=false -Dtests=false
}

recipe_pango() {
  sd="$(extract_to pango "$BLD/$A")"
  meson_build "$A" "$sd" -Dintrospection=disabled -Dfontconfig=enabled \
      -Dfreetype=enabled -Dcairo=enabled \
      $(meson_opt_if_exists "$sd" xft disabled) \
      $(meson_opt_if_exists "$sd" libthai disabled) \
      $(meson_opt_if_exists "$sd" gtk_doc false)
}

recipe_gtk3() {
  sd="$(extract_to gtk3 "$BLD/$A")"
  meson_build "$A" "$sd" -Dquartz_backend=true -Dx11_backend=false \
      -Dwayland_backend=false -Dbroadway_backend=false \
      -Dintrospection=false -Ddemos=false -Dexamples=false -Dtests=false \
      $(meson_opt_if_exists "$sd" gtk_doc false) \
      $(meson_opt_if_exists "$sd" man false) \
      $(meson_opt_if_exists "$sd" builtin_immodules yes) \
      $(meson_opt_if_exists "$sd" installed_tests false)
}

recipe_libgsf() {
  sd="$(extract_to libgsf "$BLD/$A")"
  autotools_build "$A" "$sd" --disable-introspection --disable-gtk-doc
}

recipe_libcroco() {
  sd="$(extract_to libcroco "$BLD/$A")"
  # -Bsymbolic-functions is a GNU ld flag; Apple's ld lacks it.
  autotools_build "$A" "$sd" --disable-gtk-doc --disable-Bsymbolic
}

recipe_librsvg() {
  sd="$(extract_to librsvg "$BLD/$A")"
  # librsvg 2.40 predates libxml2 2.12's const-ified xmlStructuredErrorFunc;
  # modern clang raises the signature mismatch to an error. The ABI is
  # unchanged (same pointer layout), so demote it back to a warning.
  export CFLAGS="$CFLAGS -Wno-error=incompatible-function-pointer-types"
  autotools_build "$A" "$sd" --disable-introspection --enable-pixbuf-loader \
      --disable-gtk-doc --disable-Bsymbolic
}

recipe_hicolor() {
  [ "$A" = "$NATIVE_ARCH" ] || return 0   # pure data, once is enough
  sd="$(extract_to hicolor "$BLD/$A")"
  ( cd "$sd" && ./configure --prefix="$ROOT" && make install )
}

recipe_adwaita() {
  [ "$A" = "$NATIVE_ARCH" ] || return 0   # pure data, once is enough
  sd="$(extract_to adwaita "$BLD/$A")"
  ( cd "$sd" && ./configure --prefix="$ROOT" && make -j"$NPROC" && make install )
}

recipe_goffice() {
  sd="$(extract_to goffice "$BLD/$A")"
  # Relocation patch: honour GOFFICE_*DIR environment variables at runtime.
  python3 "$TOP/patches/relocate-goffice.py" "$sd/goffice/goffice.c"
  # macOS fix: fall back to gdk-pixbuf sniffing for untyped image buffers
  # (GLib's content-type backend cannot identify raw data on macOS).
  python3 "$TOP/patches/goffice-image-sniff.py" "$sd/goffice/utils/go-image.c"
  # Correctness fix (needed with gdk-pixbuf >= 2.44, harmless with ours):
  # close the pixbuf loader before fetching the decoded pixbuf.
  python3 "$TOP/patches/goffice-pixbuf-close.py" "$sd/goffice/utils/go-pixbuf.c"
  autotools_build "$A" "$sd" --without-lasem --disable-gtk-doc
}

recipe_gnumeric() {
  sd="$(extract_to gnumeric "$BLD/$A")"
  # Relocation patch: honour GNUMERIC_*DIR environment variables at runtime.
  python3 "$TOP/patches/relocate-gnumeric.py" "$sd/src/gutils.c"
  # macOS math.h only declares lgamma_r when _REENTRANT is defined. The
  # native pass detects this via a run-test; the cross pass cannot run it
  # and guesses wrong, so declare it explicitly for both.
  export CPPFLAGS="$CPPFLAGS -D_REENTRANT"
  export CFLAGS="$CFLAGS -D_REENTRANT"
  local hostflags=""
  if [ "$A" != "$NATIVE_ARCH" ]; then
    hostflags="--host=$(host_triple "$A") --build=$(host_triple "$NATIVE_ARCH") $CROSS_SEEDS"
  fi
  ( cd "$sd" && \
    ./configure --prefix="$ROOT" --disable-static --enable-shared \
        --disable-dependency-tracking $hostflags \
        --without-python --without-perl --without-psiconv \
        --without-paradox --without-gda \
        ITSTOOL="$TOOLS/bin/itstool" && \
    make -j"$NPROC" HELP_LINGUAS="" && \
    make install HELP_LINGUAS="" )
}

# ---------------------------------------------------------------------------
# STACK DRIVER
# ---------------------------------------------------------------------------
build_one() { # <arch> <pkg>
  local A="$1" p="$2"
  log "[$A] $p $(pkg_version "$p")"
  (
    set -e
    A="$A"
    ROOT="$(root_for "$A")"
    arch_env "$A"
    export A ROOT
    "recipe_$p" "$A"
  ) || die "[$A] $p failed. Fix and re-run:  RESUME_FROM=$p ./build.sh deps $A"
  mark_built "$A" "$p"
}

build_stack() { # <arch>
  local A="$1" p
  log "Building library stack for $A (deployment target macOS $MACOS_MIN)"
  mkdir -p "$BLD/$A"
  for p in $DEP_ORDER; do
    if should_skip "$A" "$p"; then
      echo "  [skip] $p"
      continue
    fi
    build_one "$A" "$p"
  done
  log "$A stack complete -> work/root-$A"
}
