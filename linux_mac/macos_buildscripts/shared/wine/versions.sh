#!/usr/bin/env bash
# versions.sh -- pinned component versions, download URLs and known checksums.
#
# Every value here can be overridden from the environment, e.g.
#   FREETYPE_VERSION=2.13.2 ./build-wine.sh
#
# CHECKSUMS
# ---------
# Hashes listed in KNOWN_SHA256 are enforced.  Anything not listed is downloaded,
# hashed, and the observed hash is appended to  build/checksums.observed  so you
# can promote it into this file for a reproducible re-run.  Run with --strict-sha
# to make an unpinned download a hard error instead.
#
# The gecko/mono hashes below are the ones Wine 11.0 itself verifies at install
# time (see dlls/appwiz.cpl/addons.c in the wine-11.0 tree) -- do not change them
# without changing WINE_VERSION.

# shellcheck shell=bash

# ---------------------------------------------------------------- Wine itself
WINE_VERSION="${WINE_VERSION:-11.0}"
WINE_SERIES="${WINE_SERIES:-${WINE_VERSION%%.*}.0}"
WINE_URL="${WINE_URL:-https://dl.winehq.org/wine/source/${WINE_SERIES}/wine-${WINE_VERSION}.tar.xz}"

# Addons.  Versions and hashes must match dlls/appwiz.cpl/addons.c for WINE_VERSION.
GECKO_VERSION="${GECKO_VERSION:-2.47.4}"
MONO_VERSION="${MONO_VERSION:-10.4.1}"
GECKO_BASE="${GECKO_BASE:-https://dl.winehq.org/wine/wine-gecko/${GECKO_VERSION}}"
MONO_BASE="${MONO_BASE:-https://dl.winehq.org/wine/wine-mono/${MONO_VERSION}}"

# --------------------------------------------------------------- Build tools
# These never ship inside wine.app.  They only have to run on the build machine.
M4_VERSION="${M4_VERSION:-1.4.19}"
M4_URL="https://ftp.gnu.org/gnu/m4/m4-${M4_VERSION}.tar.xz"

BISON_VERSION="${BISON_VERSION:-3.8.2}"
BISON_URL="https://ftp.gnu.org/gnu/bison/bison-${BISON_VERSION}.tar.xz"

PKGCONF_VERSION="${PKGCONF_VERSION:-2.3.0}"
PKGCONF_URL="https://distfiles.ariadne.space/pkgconf/pkgconf-${PKGCONF_VERSION}.tar.xz"

GETTEXT_VERSION="${GETTEXT_VERSION:-0.22.5}"
GETTEXT_URL="https://ftp.gnu.org/gnu/gettext/gettext-${GETTEXT_VERSION}.tar.xz"

NASM_VERSION="${NASM_VERSION:-2.16.03}"
NASM_URL="https://www.nasm.us/pub/nasm/releasebuilds/${NASM_VERSION}/nasm-${NASM_VERSION}.tar.xz"

# llvm-mingw supplies the PE cross compiler (clang + mingw-w64 headers/CRT) that
# Wine uses to build its Windows-side DLLs.  Build-time only.  Left empty means
# "resolve the newest macos-universal release from the GitHub API at build time".
LLVM_MINGW_RELEASE="${LLVM_MINGW_RELEASE:-}"
LLVM_MINGW_REPO="${LLVM_MINGW_REPO:-mstorsjo/llvm-mingw}"
LLVM_MINGW_ASSET_RE="${LLVM_MINGW_ASSET_RE:-ucrt-macos-universal\\.tar\\.xz$}"

# Python build system for glib/GStreamer.  Installed into a private venv.
MESON_VERSION="${MESON_VERSION:-1.6.1}"
NINJA_VERSION="${NINJA_VERSION:-1.11.1.4}"

# ----------------------------------------------------- Runtime libraries
# Everything below is compiled from source with MACOSX_DEPLOYMENT_TARGET=11.0
# and ends up inside wine.app/Contents/Resources/wine/lib.

FREETYPE_VERSION="${FREETYPE_VERSION:-2.13.3}"
FREETYPE_URL="https://download.savannah.gnu.org/releases/freetype/freetype-${FREETYPE_VERSION}.tar.xz"

GMP_VERSION="${GMP_VERSION:-6.3.0}"
GMP_URL="https://ftp.gnu.org/gnu/gmp/gmp-${GMP_VERSION}.tar.xz"

NETTLE_VERSION="${NETTLE_VERSION:-3.10}"
NETTLE_URL="https://ftp.gnu.org/gnu/nettle/nettle-${NETTLE_VERSION}.tar.gz"

LIBTASN1_VERSION="${LIBTASN1_VERSION:-4.19.0}"
LIBTASN1_URL="https://ftp.gnu.org/gnu/libtasn1/libtasn1-${LIBTASN1_VERSION}.tar.gz"

GNUTLS_VERSION="${GNUTLS_VERSION:-3.8.4}"
GNUTLS_SERIES="${GNUTLS_VERSION%.*}"
GNUTLS_URL="https://www.gnupg.org/ftp/gcrypt/gnutls/v${GNUTLS_SERIES}/gnutls-${GNUTLS_VERSION}.tar.xz"

SDL2_VERSION="${SDL2_VERSION:-2.30.9}"
SDL2_URL="https://github.com/libsdl-org/SDL/releases/download/release-${SDL2_VERSION}/SDL2-${SDL2_VERSION}.tar.gz"

FFMPEG_VERSION="${FFMPEG_VERSION:-7.1}"
FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"

# Vulkan headers for Wine's winevulkan unix side.  Leave the tag empty to
# resolve the newest release from the GitHub API at build time (recommended --
# Wine tracks the Vulkan spec closely and a stale pin causes missing enums).
VULKAN_HEADERS_REPO="${VULKAN_HEADERS_REPO:-KhronosGroup/Vulkan-Headers}"
VULKAN_HEADERS_TAG="${VULKAN_HEADERS_TAG:-}"

# MoltenVK 1.4.1 is the LAST release whose deployment target is macOS 11.0.
# 1.4.2 (2026-07-24) raised the floor to macOS 12.0 -- do not bump past 1.4.1
# unless the macOS 11 requirement is dropped.
MOLTENVK_VERSION="${MOLTENVK_VERSION:-1.4.1}"
MOLTENVK_URL="https://github.com/KhronosGroup/MoltenVK/archive/refs/tags/v${MOLTENVK_VERSION}.tar.gz"
MOLTENVK_PREBUILT_URL="https://github.com/KhronosGroup/MoltenVK/releases/download/v${MOLTENVK_VERSION}/MoltenVK-macos.tar"

# ------------------------------------------------------- GStreamer stack
# Do NOT go below 3.4.8 on Apple Silicon.  libffi's hand-written
# src/aarch64/sysv.S placed non-private labels between .cfi_startproc and
# .cfi_endproc, which Mach-O's .subsections_via_symbols does not allow; clang 17
# and later reject it with "invalid CFI advance_loc expression".  Upstream fixed
# it in Sep 2024 (libffi PR #857), i.e. after both 3.4.6 and 3.4.7 shipped.
LIBFFI_VERSION="${LIBFFI_VERSION:-3.5.2}"
LIBFFI_URL="https://github.com/libffi/libffi/releases/download/v${LIBFFI_VERSION}/libffi-${LIBFFI_VERSION}.tar.gz"

PCRE2_VERSION="${PCRE2_VERSION:-10.44}"
PCRE2_URL="https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE2_VERSION}/pcre2-${PCRE2_VERSION}.tar.bz2"

GLIB_VERSION="${GLIB_VERSION:-2.80.5}"
GLIB_SERIES="${GLIB_VERSION%.*}"
GLIB_URL="https://download.gnome.org/sources/glib/${GLIB_SERIES}/glib-${GLIB_VERSION}.tar.xz"

ORC_VERSION="${ORC_VERSION:-0.4.40}"
ORC_URL="https://gstreamer.freedesktop.org/src/orc/orc-${ORC_VERSION}.tar.xz"

GST_VERSION="${GST_VERSION:-1.24.12}"
GST_BASE_URL="https://gstreamer.freedesktop.org/src"
GST_CORE_URL="${GST_BASE_URL}/gstreamer/gstreamer-${GST_VERSION}.tar.xz"
GST_PLUGINS_BASE_URL="${GST_BASE_URL}/gst-plugins-base/gst-plugins-base-${GST_VERSION}.tar.xz"
GST_PLUGINS_GOOD_URL="${GST_BASE_URL}/gst-plugins-good/gst-plugins-good-${GST_VERSION}.tar.xz"
GST_PLUGINS_BAD_URL="${GST_BASE_URL}/gst-plugins-bad/gst-plugins-bad-${GST_VERSION}.tar.xz"
# gst-plugins-ugly is needed for asfdemux (WMV/ASF), which many Windows
# installers and in-game cutscenes still use.  Only LGPL plugins are enabled.
GST_PLUGINS_UGLY_URL="${GST_BASE_URL}/gst-plugins-ugly/gst-plugins-ugly-${GST_VERSION}.tar.xz"
GST_LIBAV_URL="${GST_BASE_URL}/gst-libav/gst-libav-${GST_VERSION}.tar.xz"

# ---------------------------------------------------------------- Checksums
# Format: "<basename> <sha256>".  Only the two Wine addons are pinned out of the
# box because their hashes are published inside the Wine source tree itself.
KNOWN_SHA256=(
  "wine-gecko-${GECKO_VERSION}-x86.msi        26cecc47706b091908f7f814bddb074c61beb8063318e9efc5a7f789857793d6"
  "wine-gecko-${GECKO_VERSION}-x86_64.msi     e590b7d988a32d6aa4cf1d8aa3aa3d33766fdd4cf4c89c2dcc2095ecb28d066f"
  "wine-mono-${MONO_VERSION}-x86.msi          071f4b2887e1c97a11d791ff3d65be9429eed6dec4c2708888bfd546ba358e23"
)

# All URLs that the preflight stage HEAD-checks before any work begins.
ALL_SOURCE_URLS=(
  "$WINE_URL"
  "${GECKO_BASE}/wine-gecko-${GECKO_VERSION}-x86.msi"
  "${GECKO_BASE}/wine-gecko-${GECKO_VERSION}-x86_64.msi"
  "${MONO_BASE}/wine-mono-${MONO_VERSION}-x86.msi"
  "$M4_URL" "$BISON_URL" "$PKGCONF_URL" "$GETTEXT_URL" "$NASM_URL"
  "$FREETYPE_URL" "$GMP_URL" "$NETTLE_URL" "$LIBTASN1_URL" "$GNUTLS_URL"
  "$SDL2_URL" "$FFMPEG_URL" "$MOLTENVK_URL"
  "$LIBFFI_URL" "$PCRE2_URL" "$GLIB_URL" "$ORC_URL"
  "$GST_CORE_URL" "$GST_PLUGINS_BASE_URL" "$GST_PLUGINS_GOOD_URL"
  "$GST_PLUGINS_BAD_URL" "$GST_PLUGINS_UGLY_URL" "$GST_LIBAV_URL"
)
