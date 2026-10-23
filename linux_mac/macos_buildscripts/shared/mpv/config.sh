# shellcheck shell=bash
# ============================================================================
# config.sh — Top-level configuration for the portable mpv build.
#
# Sourced by build.sh and every script under scripts/. Edit the values here
# to change the deployment target, output locations, parallelism, and which
# optional feature groups get compiled in.
# ============================================================================

# ----------------------------------------------------------------------------
# Hard compatibility floor.  Nothing in the resulting .app may require a macOS
# newer than this.  This value is exported into CFLAGS/CXXFLAGS/LDFLAGS and the
# meson cross/native files for *every* library, and is re-checked by verify.sh
# against each Mach-O's LC_BUILD_VERSION.
# ----------------------------------------------------------------------------
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"

# Architectures that make up the universal binary.  Order is irrelevant.
ARCHS=("arm64" "x86_64")

# ----------------------------------------------------------------------------
# Layout.  ROOT is the directory containing build.sh (set by build.sh).
#   WORK      scratch space: sources, per-arch staging, the merged prefix
#   PREFIX    the *final* install path that gets baked into every dylib id.
#             It must be identical across both arch builds.  It does NOT need
#             to exist on the end-user's machine — dylib_unhell rewrites all
#             references to @executable_path/lib when the .app is bundled — but
#             keep it short and on a path you control during the build.
#   DIST      where the finished mpv.app is written.
# ----------------------------------------------------------------------------
: "${ROOT:?config.sh must be sourced after ROOT is set}"
WORK="${WORK:-$ROOT/work}"
PREFIX="${PREFIX:-$WORK/prefix}"           # universal (merged) prefix
SRC_DIR="$WORK/src"                        # downloaded + extracted sources
STAGE_DIR="$WORK/stage"                    # per-arch DESTDIR staging
TOOLS_PREFIX="$WORK/toolsprefix"           # host build tools (nasm, pkgconf, cmake, meson)
DIST="${DIST:-$ROOT/dist}"                 # final mpv.app lands here
LOG_DIR="$WORK/logs"

# mpv source tarball.  By default we look for the tarball the user dropped in
# the project folder; override MPV_TARBALL to point elsewhere.
MPV_TARBALL="${MPV_TARBALL:-$ROOT/../mpv-0.41.0.tar.gz}"

# Parallelism.
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

# ----------------------------------------------------------------------------
# Feature toggles.  "1" = build, "0" = skip.  The defaults give the maximal,
# GPL-clean, no-nonfree, no-Swift configuration.  Flip individual groups off to
# shrink the build, or flip the nonfree/extra-network ones on if you accept the
# licensing / size trade-offs (see README "Licensing" section).
# ----------------------------------------------------------------------------

# Core (always required — listed for documentation only; do not disable).
ENABLE_CORE=1            # ffmpeg, libplacebo, libass + their mandatory deps

# Video / audio codec libraries linked into FFmpeg.
ENABLE_AV1=1             # dav1d (decode) + SVT-AV1 + aom (encode/decode)
ENABLE_VPX=1             # libvpx (VP8/VP9)
ENABLE_X264=1            # H.264 encoder (GPL)
ENABLE_X265=1            # H.265 encoder (GPL)
ENABLE_AUDIO_CODECS=1    # opus, vorbis, ogg, flac, lame, theora
ENABLE_WEBP=1            # libwebp
# zimg (high-quality CPU scaler). Upstream ships no release tarball with a
# configure script (only a bare GitHub source archive), so when this is enabled
# the bootstrap step also builds a host autotools toolchain (m4/autoconf/
# automake/libtool) and the zimg recipe runs autoreconf to generate configure.
ENABLE_ZIMG=1            # high-quality software scaler (autoreconf'd from source)

# Subtitles / text shaping (required by libass; effectively core).
ENABLE_TEXT=1            # freetype, harfbuzz, fribidi, fontconfig, libunibreak

# Scripting & extras.
ENABLE_LUA=1             # Lua 5.2 (osc, user scripts)
ENABLE_JAVASCRIPT=1      # MuJS (JS user scripts)
ENABLE_LIBARCHIVE=1      # play media inside zip/rar/7z/iso
ENABLE_UCHARDET=1        # subtitle charset autodetection
ENABLE_RUBBERBAND=1      # high-quality audio pitch/tempo correction
ENABLE_JPEG=1            # libjpeg-turbo (jpeg screenshot writer)

# Optical media / discs (maximal set).
ENABLE_DISC=1            # libxml2, libbluray, libdvdread/nav/css, libcdio(+paranoia)

# FFmpeg command-line tools. When 1, dep_ffmpeg also builds the ffmpeg, ffprobe
# and ffplay programs (into $PREFIX/bin, lipo'd universal by the merge) and the
# build produces a fully-portable dist/ffmpeg.app alongside mpv.app. ffplay
# needs SDL2, so this also builds and bundles SDL2.
ENABLE_FFMPEG_TOOLS=1

# GPU stack.
# NOTE: libplacebo always drives mpv's gpu/gpu-next renderer. On macOS WITHOUT
# the Swift backend there is no C Vulkan windowing context, so a Vulkan surface
# cannot be created for on-screen output regardless — the working windowed path
# is gl-cocoa (OpenGL) carrying gpu-next via libplacebo. We therefore build
# libplacebo with the OpenGL backend and leave Vulkan OFF by default: turning it
# on pulls in the fragile MoltenVK-from-source build for zero on-screen benefit
# in a no-Swift bundle. Flip to 1 only if you later add the Swift backend.
ENABLE_VULKAN=0          # MoltenVK + Vulkan-Loader + headers + glslang for libplacebo

# ----- Opt-in groups (OFF by default) --------------------------------------
ENABLE_FDK_AAC=0         # Fraunhofer AAC encoder — NONFREE, do not redistribute
ENABLE_OPENSSL=0         # bundle OpenSSL for TLS instead of SecureTransport.
                         # Implies ffmpeg --enable-nonfree under GPL. Off = use
                         # macOS SecureTransport (no extra dylib, GPL-clean).
ENABLE_SRT=0             # libsrt  (needs OpenSSL)
ENABLE_RIST=0            # librist (needs OpenSSL)
ENABLE_VAPOURSYNTH=0     # VapourSynth bridge (pulls in Python + zimg)

# ----------------------------------------------------------------------------
# Codesigning.  osxbundle.py ad-hoc signs ("-s -") by default, which is enough
# to run locally.  To sign with a Developer ID for distribution/notarization,
# set CODESIGN_IDENTITY to your identity string; bundle.sh will re-sign.
# ----------------------------------------------------------------------------
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"   # e.g. "Developer ID Application: Name (TEAMID)"
