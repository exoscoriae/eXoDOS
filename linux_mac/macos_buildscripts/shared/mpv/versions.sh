# shellcheck shell=bash
# ============================================================================
# versions.sh — Pinned versions and canonical source URLs for every component.
#
# Every URL points at an upstream project's own release host (ffmpeg.org,
# videolan.org, xiph.org, freedesktop.org, GitHub release assets, etc.) — never
# a package manager.  All of these meet or exceed mpv 0.41's minimum version
# floors and build cleanly against a macOS 11 deployment target.
#
# Bump a version by editing the *_VER and *_URL pair.  Keep tarballs that ship
# a pre-generated ./configure (autotools) where possible to avoid needing
# autoconf/automake on the build host.
#
# Last reviewed against upstream latest-stable: June 2026.
#
# Deliberate holds (NOT bumped to the absolute newest, on purpose):
#   * cmake 3.30.5  — CMake 4.x makes cmake_minimum_required(<3.5) a hard error,
#                     which breaks uchardet (and other) recipes. Host-only tool;
#                     does not ship in the bundle, so staying on 3.x is free.
#   * m4/autoconf/automake/libtool — host-only, used ONLY to autoreconf zimg.
#                     The current set works; bumping risks zimg's bootstrap for
#                     zero change to the produced bundle.
#   * lua 5.2.4     — mpv 0.41's `lua` meson option only accepts lua52/lua51/
#                     luajit; it has NO lua53/lua54 choice. 5.2.4 is the newest
#                     release of the (5.2) series mpv 0.41 can actually use.
# ============================================================================

# --- Build tools (host-only, not bundled) ----------------------------------
PKGCONF_VER="2.5.1";  PKGCONF_URL="https://distfiles.ariadne.space/pkgconf/pkgconf-${PKGCONF_VER}.tar.xz"
NASM_VER="2.16.03";   NASM_URL="https://www.nasm.us/pub/nasm/releasebuilds/${NASM_VER}/nasm-${NASM_VER}.tar.xz"
# Held at 3.x on purpose (see header): CMake 4.x rejects cmake_minimum_required<3.5.
CMAKE_VER="3.30.5";   CMAKE_URL="https://github.com/Kitware/CMake/releases/download/v${CMAKE_VER}/cmake-${CMAKE_VER}-macos-universal.tar.gz"

# GNU autotools — host-only, built from source, used to generate configure for
# the few deps that ship only a source archive (currently just zimg). Only
# built when a dependency needs them (see bootstrap.sh). Order: m4 -> autoconf
# -> automake -> libtool.  Held at a known-good set (see header).
M4_VER="1.4.19";      M4_URL="https://ftp.gnu.org/gnu/m4/m4-${M4_VER}.tar.xz"
AUTOCONF_VER="2.72";  AUTOCONF_URL="https://ftp.gnu.org/gnu/autoconf/autoconf-${AUTOCONF_VER}.tar.xz"
AUTOMAKE_VER="1.16.5";AUTOMAKE_URL="https://ftp.gnu.org/gnu/automake/automake-${AUTOMAKE_VER}.tar.xz"
LIBTOOL_VER="2.4.7";  LIBTOOL_URL="https://ftp.gnu.org/gnu/libtool/libtool-${LIBTOOL_VER}.tar.xz"

# --- Core ------------------------------------------------------------------
# Current stable. mpv 0.41 requires libavcodec >= 60.31.102 (FFmpeg 7.0+) and
# builds cleanly against FFmpeg 8.x. If this exact point release ever 404s,
# drop to the latest available 8.1.x on https://ffmpeg.org/releases/.
FFMPEG_VER="8.1.2";   FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VER}.tar.xz"
# libplacebo has git submodules (glad, etc.); we clone --recursive at this tag.
LIBPLACEBO_VER="v7.360.1"; LIBPLACEBO_GIT="https://code.videolan.org/videolan/libplacebo.git"
LIBASS_VER="0.17.4";  LIBASS_URL="https://github.com/libass/libass/releases/download/${LIBASS_VER}/libass-${LIBASS_VER}.tar.gz"

# --- Text / subtitle stack -------------------------------------------------
FREETYPE_VER="2.13.3";  FREETYPE_URL="https://download.savannah.gnu.org/releases/freetype/freetype-${FREETYPE_VER}.tar.xz"
HARFBUZZ_VER="13.0.1";  HARFBUZZ_URL="https://github.com/harfbuzz/harfbuzz/releases/download/${HARFBUZZ_VER}/harfbuzz-${HARFBUZZ_VER}.tar.xz"
FRIBIDI_VER="1.0.16";   FRIBIDI_URL="https://github.com/fribidi/fribidi/releases/download/v${FRIBIDI_VER}/fribidi-${FRIBIDI_VER}.tar.xz"
EXPAT_VER="2.8.1";      EXPAT_REL="R_2_8_1"; EXPAT_URL="https://github.com/libexpat/libexpat/releases/download/${EXPAT_REL}/expat-${EXPAT_VER}.tar.xz"
# fontconfig releases after 2.16.0 are published on the freedesktop GitLab
# package registry (project 890), NOT the old release/ dir. The tarball still
# ships a pre-generated ./configure, so run_autotools works as before.
FONTCONFIG_VER="2.18.1";FONTCONFIG_URL="https://gitlab.freedesktop.org/api/v4/projects/890/packages/generic/fontconfig/${FONTCONFIG_VER}/fontconfig-${FONTCONFIG_VER}.tar.xz"
LIBUNIBREAK_VER="7.0";  LIBUNIBREAK_URL="https://github.com/adah1972/libunibreak/releases/download/libunibreak_7_0/libunibreak-${LIBUNIBREAK_VER}.tar.gz"

# --- Compression (FFmpeg + libarchive deps) --------------------------------
# xz: 5.8.x is the current stable line, well past the backdoored 5.6.0/5.6.1
# (CVE-2024-3094, excised after upstream remediation). 5.8.3 also carries
# security fixes (CVE-2025-31115 etc.).
XZ_VER="5.8.3";   XZ_URL="https://github.com/tukaani-project/xz/releases/download/v${XZ_VER}/xz-${XZ_VER}.tar.xz"
ZSTD_VER="1.5.7"; ZSTD_URL="https://github.com/facebook/zstd/releases/download/v${ZSTD_VER}/zstd-${ZSTD_VER}.tar.gz"
LIBPNG_VER="1.6.58"; LIBPNG_URL="https://download.sourceforge.net/libpng/libpng-${LIBPNG_VER}.tar.xz"

# --- Audio codecs ----------------------------------------------------------
OGG_VER="1.3.6";     OGG_URL="https://downloads.xiph.org/releases/ogg/libogg-${OGG_VER}.tar.xz"
VORBIS_VER="1.3.7";  VORBIS_URL="https://downloads.xiph.org/releases/vorbis/libvorbis-${VORBIS_VER}.tar.xz"
OPUS_VER="1.6.1";    OPUS_URL="https://downloads.xiph.org/releases/opus/opus-${OPUS_VER}.tar.gz"
FLAC_VER="1.5.0";    FLAC_URL="https://downloads.xiph.org/releases/flac/flac-${FLAC_VER}.tar.xz"
THEORA_VER="1.2.0";  THEORA_URL="https://downloads.xiph.org/releases/theora/libtheora-${THEORA_VER}.tar.gz"
LAME_VER="3.100";    LAME_URL="https://downloads.sourceforge.net/lame/lame-${LAME_VER}.tar.gz"
# Use the SourceForge release tarball (ships a pre-generated ./configure); the
# GitHub tag archive would require autoconf/automake on the build host.
FDKAAC_VER="2.0.3";  FDKAAC_URL="https://downloads.sourceforge.net/opencore-amr/fdk-aac-${FDKAAC_VER}.tar.gz"

# --- Video codecs ----------------------------------------------------------
DAV1D_VER="1.5.3";   DAV1D_URL="https://code.videolan.org/videolan/dav1d/-/archive/${DAV1D_VER}/dav1d-${DAV1D_VER}.tar.bz2"
SVTAV1_VER="4.1.0";  SVTAV1_URL="https://gitlab.com/AOMediaCodec/SVT-AV1/-/archive/v${SVTAV1_VER}/SVT-AV1-v${SVTAV1_VER}.tar.bz2"
AOM_VER="3.13.3";    AOM_GIT="https://aomedia.googlesource.com/aom"   # tag v${AOM_VER}
VPX_VER="1.15.2";    VPX_URL="https://github.com/webmproject/libvpx/archive/refs/tags/v${VPX_VER}.tar.gz"
X264_GIT="https://code.videolan.org/videolan/x264.git"   # branch: stable
X265_VER="4.1";      X265_URL="https://bitbucket.org/multicoreware/x265_git/downloads/x265_${X265_VER}.tar.gz"
WEBP_VER="1.6.0";    WEBP_URL="https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-${WEBP_VER}.tar.gz"
# zimg has no release asset with a configure script; only the GitHub source
# archive exists, so this needs host autotools (autogen.sh). 3.0.6 is the latest
# release. URL is the source archive.
ZIMG_VER="3.0.6";    ZIMG_URL="https://github.com/sekrit-twc/zimg/archive/refs/tags/release-${ZIMG_VER}.tar.gz"

# --- ffplay video output ----------------------------------------------------
# SDL2 (required by FFmpeg's ffplay). 2.32.10 is the latest release of the
# SDL2 (2.x) line; the active SDL line is SDL3, but ffplay targets SDL2.
SDL2_VER="2.32.10"; SDL2_URL="https://github.com/libsdl-org/SDL/releases/download/release-${SDL2_VER}/SDL2-${SDL2_VER}.tar.gz"

# --- Image / color ---------------------------------------------------------
JPEGTURBO_VER="3.1.4.1"; JPEGTURBO_URL="https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/${JPEGTURBO_VER}/libjpeg-turbo-${JPEGTURBO_VER}.tar.gz"
LCMS2_VER="2.19";      LCMS2_URL="https://github.com/mm2/Little-CMS/releases/download/lcms${LCMS2_VER}/lcms2-${LCMS2_VER}.tar.gz"

# --- GPU / Vulkan ----------------------------------------------------------
# OFF by default (ENABLE_VULKAN=0). These tags are approximate-latest and are
# NOT exercised by the default build; re-verify before enabling Vulkan. Note the
# Vulkan-Headers/Loader tag scheme changed to "vulkan-sdk-X.Y.Z.W".
VULKAN_HEADERS_VER="vulkan-sdk-1.4.313.0"; VULKAN_HEADERS_GIT="https://github.com/KhronosGroup/Vulkan-Headers.git"
VULKAN_LOADER_VER="vulkan-sdk-1.4.313.0";  VULKAN_LOADER_GIT="https://github.com/KhronosGroup/Vulkan-Loader.git"
MOLTENVK_VER="v1.3.0";         MOLTENVK_GIT="https://github.com/KhronosGroup/MoltenVK.git"
GLSLANG_VER="16.3.0";          GLSLANG_GIT="https://github.com/KhronosGroup/glslang.git"  # tag ${GLSLANG_VER}

# --- Scripting -------------------------------------------------------------
# Lua 5.2.4: mpv 0.41's lua option accepts only lua52/lua51/luajit (no 5.3/5.4),
# so this is the newest usable Lua. build-mpv.sh uses -Dlua=lua52 and dep_lua
# writes the lua5.2 pkg-config names.
LUA_VER="5.2.4";  LUA_URL="https://www.lua.org/ftp/lua-${LUA_VER}.tar.gz"
MUJS_VER="1.3.9"; MUJS_URL="https://mujs.com/downloads/mujs-${MUJS_VER}.tar.gz"

# --- Extras ----------------------------------------------------------------
LIBARCHIVE_VER="3.8.7"; LIBARCHIVE_URL="https://github.com/libarchive/libarchive/releases/download/v${LIBARCHIVE_VER}/libarchive-${LIBARCHIVE_VER}.tar.xz"
UCHARDET_VER="0.0.8";   UCHARDET_URL="https://www.freedesktop.org/software/uchardet/releases/uchardet-${UCHARDET_VER}.tar.xz"
RUBBERBAND_VER="4.0.0"; RUBBERBAND_URL="https://breakfastquay.com/files/releases/rubberband-${RUBBERBAND_VER}.tar.bz2"

# --- Optical media ---------------------------------------------------------
# NOTE: libbluray 1.4.0 and libdvdcss/read/nav (1.5.0 / 7.0.0) switched their
# build system to Meson — their recipes in deps.sh use run_meson accordingly.
LIBXML2_VER="2.15.3"; LIBXML2_URL="https://download.gnome.org/sources/libxml2/2.15/libxml2-${LIBXML2_VER}.tar.xz"
# The new Meson-era VideoLAN releases ship .tar.xz (older autotools ones were .bz2).
LIBBLURAY_VER="1.4.0"; LIBBLURAY_URL="https://download.videolan.org/pub/videolan/libbluray/${LIBBLURAY_VER}/libbluray-${LIBBLURAY_VER}.tar.xz"
LIBDVDREAD_VER="7.0.0"; LIBDVDREAD_URL="https://download.videolan.org/pub/videolan/libdvdread/${LIBDVDREAD_VER}/libdvdread-${LIBDVDREAD_VER}.tar.xz"
LIBDVDNAV_VER="7.0.0";  LIBDVDNAV_URL="https://download.videolan.org/pub/videolan/libdvdnav/${LIBDVDNAV_VER}/libdvdnav-${LIBDVDNAV_VER}.tar.xz"
LIBDVDCSS_VER="1.5.0";  LIBDVDCSS_URL="https://download.videolan.org/pub/videolan/libdvdcss/${LIBDVDCSS_VER}/libdvdcss-${LIBDVDCSS_VER}.tar.xz"
# Held at 2.1.0: this is the newest libcdio on the canonical GNU release host
# (ftp.gnu.org tops out at 2.1.0, ships a pre-generated ./configure). 2.2.0
# exists only as a GitHub source archive that would require autoreconf + gettext
# to bootstrap; not worth it for a minor ABI-version bump.
LIBCDIO_VER="2.1.0";    LIBCDIO_URL="https://ftp.gnu.org/gnu/libcdio/libcdio-${LIBCDIO_VER}.tar.bz2"
LIBCDIO_PARANOIA_VER="10.2+2.0.2"; LIBCDIO_PARANOIA_URL="https://ftp.gnu.org/gnu/libcdio/libcdio-paranoia-${LIBCDIO_PARANOIA_VER}.tar.bz2"

# --- Opt-in network --------------------------------------------------------
OPENSSL_VER="3.5.7"; OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VER}/openssl-${OPENSSL_VER}.tar.gz"
SRT_VER="1.5.4";      SRT_URL="https://github.com/Haivision/srt/archive/refs/tags/v${SRT_VER}.tar.gz"
RIST_VER="0.2.11";    RIST_URL="https://code.videolan.org/rist/librist/-/archive/v${RIST_VER}/librist-v${RIST_VER}.tar.bz2"
