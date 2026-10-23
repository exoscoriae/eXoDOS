#!/usr/bin/env bash
# lib/gstreamer.sh -- the GStreamer stack used by winegstreamer.
#
# Wine 11.0 still uses GStreamer as the default Media Foundation byte stream
# handler, with FFmpeg/winedmo as the alternative.  Building both means video
# works whichever path an application takes.
#
# Every module is configured with --wrap-mode=nodownload and an isolated
# PKG_CONFIG_LIBDIR, so meson can only ever see the libraries we built plus
# macOS system frameworks.  auto_features then disables everything whose
# dependencies are absent, which is far more robust across GStreamer releases
# than hand-listing a hundred plugin switches.
# shellcheck shell=bash

gst_libffi() {
  local src; src="$(extract "$(fetch "$LIBFFI_URL")")"
  build_autotools libffi "$src" --disable-multi-os-directory --disable-dependency-tracking
}

gst_pcre2() {
  local src; src="$(extract "$(fetch "$PCRE2_URL")")"
  build_autotools pcre2 "$src" \
    --enable-unicode --enable-jit --disable-dependency-tracking
}

# GNU libintl, from the gettext-runtime subtree of the tarball we already fetch
# for msgfmt.
#
# glib needs this even with -Dnls=disabled: that option only suppresses building
# glib's own .mo catalogues, while g_dgettext() and friends are public API that
# must resolve regardless.  On glibc systems meson's 'intl' dependency is
# satisfied by libc itself; macOS has no such thing, so glib falls back to
# downloading the proxy-libintl stub -- which --wrap-mode=nodownload blocks, by
# design.  Building the real library keeps every shipped byte pinned and
# checksummed.
gst_libintl() {
  local src; src="$(extract "$(fetch "$GETTEXT_URL")")"
  build_autotools libintl "$src/gettext-runtime" \
    --disable-dependency-tracking \
    --disable-java --disable-csharp --disable-openmp \
    --disable-libasprintf --without-emacs
  [[ -f "$ARCH_PREFIX/include/libintl.h" ]] \
    || die "gettext-runtime did not install libintl.h into $ARCH_PREFIX"
}

gst_glib() {
  local src; src="$(extract "$(fetch "$GLIB_URL")")"
  # Escape hatch: GLIB_ALLOW_WRAP=1 lets glib pull the proxy-libintl stub from
  # wrapdb if the real libintl above somehow is not picked up.  It is a no-op
  # shim, so with -Dnls=disabled the functional result is the same -- but it is
  # an unpinned download, hence opt-in.
  local wrap="--wrap-mode=nodownload"
  [[ "${GLIB_ALLOW_WRAP:-0}" == "1" ]] && wrap="--wrap-mode=default"

  build_meson glib "$src" \
    "$wrap" \
    -Dtests=false \
    -Dnls=disabled \
    -Dintrospection=disabled \
    -Dlibmount=disabled
}

gst_orc() {
  local src; src="$(extract "$(fetch "$ORC_URL")")"
  build_meson orc "$src" \
    --wrap-mode=nodownload \
    -Dtests=disabled -Dbenchmarks=disabled -Dexamples=disabled \
    -Dtools=disabled -Dgtk_doc=disabled
}

gst_core() {
  local src; src="$(extract "$(fetch "$GST_CORE_URL")")"
  build_meson gstreamer "$src" \
    --wrap-mode=nodownload \
    -Dtests=disabled -Dexamples=disabled -Dbenchmarks=disabled \
    -Dintrospection=disabled -Ddoc=disabled -Dnls=disabled \
    -Dtools=enabled -Dgst_debug=true
}

gst_base() {
  local src; src="$(extract "$(fetch "$GST_PLUGINS_BASE_URL")")"
  build_meson gst-plugins-base "$src" \
    --wrap-mode=nodownload \
    -Dtests=disabled -Dexamples=disabled -Dintrospection=disabled \
    -Ddoc=disabled -Dnls=disabled -Dgl=disabled
}

gst_good() {
  local src; src="$(extract "$(fetch "$GST_PLUGINS_GOOD_URL")")"
  build_meson gst-plugins-good "$src" \
    --wrap-mode=nodownload \
    -Dtests=disabled -Dexamples=disabled -Dintrospection=disabled \
    -Ddoc=disabled -Dnls=disabled
}

gst_bad() {
  local src; src="$(extract "$(fetch "$GST_PLUGINS_BAD_URL")")"
  # applemedia is disabled because it hard-depends on gst-gl: avfvideosrc.m
  # includes glcontexthelper.h -> <gst/gl/gl.h> unconditionally, and gst-gl only
  # exists if gst-plugins-base is built with -Dgl=enabled, which on macOS means
  # building against the deprecated OpenGL.framework.
  #
  # Nothing is really lost here.  Wine's winegstreamer path feeds compressed
  # data to decodebin and pulls raw frames from appsink; it never touches
  # gst-gl.  Hardware video decode is still available through winedmo, whose
  # FFmpeg is configured --enable-videotoolbox.  Enabling gl in gst_base above
  # would bring applemedia back if a webcam source is ever needed.
  build_meson gst-plugins-bad "$src" \
    --wrap-mode=nodownload \
    -Dtests=disabled -Dexamples=disabled -Dintrospection=disabled \
    -Ddoc=disabled -Dnls=disabled -Dgl=disabled -Dapplemedia=disabled
}

gst_ugly() {
  local src; src="$(extract "$(fetch "$GST_PLUGINS_UGLY_URL")")"
  # auto_features=disabled + asfdemux only: keeps the GPL-encumbered plugins
  # (x264, mpeg2dec, ...) out of the bundle while still giving Wine WMV/ASF.
  build_meson gst-plugins-ugly "$src" \
    --wrap-mode=nodownload \
    -Dauto_features=disabled \
    -Dasfdemux=enabled \
    -Dtests=disabled -Ddoc=disabled -Dnls=disabled
}

gst_libav() {
  local src; src="$(extract "$(fetch "$GST_LIBAV_URL")")"
  build_meson gst-libav "$src" \
    --wrap-mode=nodownload \
    -Dtests=disabled -Ddoc=disabled
}

build_gstreamer_for_arch() {
  set_arch "$1"
  step "Stage 3: GStreamer stack ($ARCH)"
  once "gst-libffi-$ARCH"  gst_libffi
  once "gst-pcre2-$ARCH"   gst_pcre2
  once "gst-libintl-$ARCH" gst_libintl
  once "gst-glib-$ARCH"    gst_glib
  once "gst-orc-$ARCH"    gst_orc
  once "gst-core-$ARCH"   gst_core
  once "gst-base-$ARCH"   gst_base
  once "gst-good-$ARCH"   gst_good
  once "gst-bad-$ARCH"    gst_bad
  once "gst-ugly-$ARCH"   gst_ugly
  once "gst-libav-$ARCH"  gst_libav

  local n
  n="$(find "$ARCH_PREFIX/lib/gstreamer-1.0" -name '*.dylib' 2>/dev/null | wc -l | tr -d ' ')"
  ok "$n GStreamer plugins built for $ARCH"
  [[ "$n" -gt 10 ]] || warn "unexpectedly few GStreamer plugins; check $LOGDIR/gst-*.${ARCH}.log"
}
