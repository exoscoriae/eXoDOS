#!/usr/bin/env bash
# versions.sh -- pinned component versions for the DOSBox Daum universal bundle.
#
# Every value can be overridden from the environment:
#   SDL2_VERSION=2.30.8 ./build-dosbox-daum.sh
# shellcheck shell=bash

# ------------------------------------------------------------------ DOSBox Daum
# ykhwong's DOSBox SVN Daum, final release (2015-01-25).  Underneath it is
# DOSBox SVN r3xxx, which is why the DOSBox-X AArch64 backend below can be
# adapted onto it: both derive from the same core_dynrec.
DAUM_VERSION="${DAUM_VERSION:-20150125}"

# DO NOT use the 20150125 *tag* tarball.  That tag points at a commit containing
# nothing but LICENSE, so
#   .../archive/refs/tags/20150125.tar.gz
# downloads successfully, extracts to a 7 KB directory, and fails only later.
# The complete tree is on the default branch.
#
# DAUM_COMMIT pins it to a SHA once you have a build you trust; leave it empty
# to track the branch head (this repository has not changed since 2015).
DAUM_COMMIT="${DAUM_COMMIT:-}"
if [[ -n "$DAUM_COMMIT" ]]; then
  DAUM_URL="${DAUM_URL:-https://github.com/ykhwong/dosbox-svn-daum/archive/${DAUM_COMMIT}.tar.gz}"
else
  DAUM_URL="${DAUM_URL:-https://github.com/ykhwong/dosbox-svn-daum/archive/refs/heads/master.tar.gz}"
fi

# A verified copy of the complete source lives in vendor/, and is used by
# default.  Upstream cannot be relied on here: the tag tarball is empty, the
# branch head is a moving reference, and ykhwong's own site has been offline for
# years.  Vendoring 1.8 MB makes the build reproducible and lets it run with no
# network access to GitHub at all.
#
# Override to use a different copy, or set to empty to force the download:
#   DAUM_LOCAL_ARCHIVE=              ./build-dosbox-daum.sh   # fetch from GitHub
#   DAUM_LOCAL_ARCHIVE=/path/to.7z   ./build-dosbox-daum.sh   # use your own
# Anything macOS tar can read works, including .7z, since tar there is
# bsdtar/libarchive.
_DAUM_VENDORED="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/vendor/dosbox-svn-daum-${DAUM_VERSION}.7z"
if [[ -z "${DAUM_LOCAL_ARCHIVE+set}" && -f "$_DAUM_VENDORED" ]]; then
  DAUM_LOCAL_ARCHIVE="$_DAUM_VENDORED"
else
  DAUM_LOCAL_ARCHIVE="${DAUM_LOCAL_ARCHIVE:-}"
fi

# sha256 of the known-good source.7z (473 files, complete tree).  This is the
# archive the source patcher in lib/daum.sh was written and tested against, so
# a match means the six edits are known to apply.  Set to empty to skip the
# check.
DAUM_LOCAL_SHA256="${DAUM_LOCAL_SHA256:-061336cd3971e37fa0d342c6644e19776a2ddfc20d8f197abca1f8ee27dabea6}"

# ------------------------------------------------- AArch64 dynamic recompiler
# Daum has dynrec backends for x86, x86_64, ARMv4/v7 (32-bit) and MIPS.  It has
# nothing that emits AArch64, so `core=dynamic` cannot work natively on Apple
# Silicon without one.
#
# Rather than write ~1300 lines of untested code generation, we take DOSBox-X's
# risc_armv8le.h.  It implements exactly the gen_*/DRC_* interface Daum's
# core_dynrec expects, is GPLv2 like Daum, and is exercised daily on Apple
# Silicon and Raspberry Pi.
#
# This file is pinned by CONTENT, not by commit -- see ARMV8LE_LOCAL and
# ARMV8LE_SHA256 below.  DOSBOXX_COMMIT/ARMV8LE_URL are only consulted when no
# vendored copy is present.
DOSBOXX_REPO="${DOSBOXX_REPO:-joncampbell123/dosbox-x}"
DOSBOXX_COMMIT="${DOSBOXX_COMMIT:-master}"
ARMV8LE_URL="${ARMV8LE_URL:-https://raw.githubusercontent.com/${DOSBOXX_REPO}/${DOSBOXX_COMMIT}/src/cpu/core_dynrec/risc_armv8le.h}"

# A verified copy lives in vendor/ and is preferred when present.  This is a
# stronger pin than DOSBOXX_COMMIT: a commit SHA can be force-pushed or a tag
# moved, whereas a content hash cannot lie, and vendoring removes the network
# dependency on the single most important input to the build.
#
#   ARMV8LE_LOCAL=            ./build-dosbox-daum.sh   # force the download
#   ARMV8LE_LOCAL=/path/to.h  ./build-dosbox-daum.sh   # use your own copy
_ARMV8LE_VENDORED="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/vendor/risc_armv8le.h"
if [[ -z "${ARMV8LE_LOCAL+set}" && -f "$_ARMV8LE_VENDORED" ]]; then
  ARMV8LE_LOCAL="$_ARMV8LE_VENDORED"
else
  ARMV8LE_LOCAL="${ARMV8LE_LOCAL:-}"
fi
# sha256 of the vendored copy.  Checked whether the file is vendored or fetched,
# so a silently changed upstream is a hard failure rather than a surprise.
#
# NOTE: the vendored copy is no longer byte-identical to DOSBox-X's.  It carries
# one local fix, so this hash is OURS, not upstream's:
#
#   LDP64_IMM / STP64_IMM mask their signed imm7 field.  Without the mask a
#   negative offset sign-extends through the opcode -- `ldp x1,x2,[x3,#-64]`
#   assembled as an STP, turning a load into a store -- and the branch macros
#   got the same treatment for consistency with gen_fill_branch(), which
#   already masked.  Verified against a real assembler by
#   tools/armv8-encoding-check/run.sh; upstream (9f408cb6...) fails that check
#   on 2 of its 80 encodings.
#
# Upstream's hash was 9f408cb62b1b3c5bf7d1419aff4c56c8d379dd32b2fb14fb4a7a400068a0ac76.
# Diff against it before taking a newer DOSBox-X revision, or the fix is lost.
ARMV8LE_SHA256="${ARMV8LE_SHA256:-d42d0c819744c91d7546a897895bde73dd2183e92ed57f97b6c54b8ea9164f5d}"

# ---------------------------------------------------------------- OpenGL-HQ
# vendor/openglhq/ -- the ARB fragment programs and edge table from
# openglhq.patch, plus the renderer that drives them from DOSBox's own GL path.
# Selected with output=openglhq; falls back to plain opengl at run time if the
# GL context cannot supply what it needs.
OPENGLHQ_DIR="${OPENGLHQ_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/vendor/openglhq}"

# ---------------------------------------------------------------- SoftFloat
# vendor/bochs-fpu -- Berkeley SoftFloat-3e (BSD-3-Clause) and Bochs' x87
# transcendentals (LGPL), both GPLv2-compatible.  Gives every slice the same
# 80-bit arithmetic; see vendor/fpu_instructions_softfloat.h.
SOFTFLOAT_DIR="${SOFTFLOAT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/vendor/bochs-fpu}"

# ---------------------------------------------------------------- Profiler
# vendor/dbprof.h -- header-only main-loop profiler for the output=opengl +
# cycles=max investigation.  It is compiled in but does nothing at all unless
# $DOSBOX_PROF is set in the environment of the finished binary, so a shipped
# bundle behaves exactly as it did before and a suspect run needs no rebuild.
#
#   DAUM_PROFILE=0 ./build-dosbox-daum.sh    leave it out of the build entirely
DAUM_PROFILE="${DAUM_PROFILE:-1}"

# ---------------------------------------------------------------- Banner
# The two lines Daum prints above the welcome box, from src/shell/shell.cpp.
# Upstream's attribution line is kept -- this is ykhwong's work and the GPL
# lineage should stay visible -- and only the date line is replaced.
DAUM_BANNER_NOTICE="${DAUM_BANNER_NOTICE:-Retro eXo modified: Jul 29, 2026}"

# EXPORTED, deliberately.  The source patcher is a python3 child process and
# reads these with os.environ.get(); a plain shell assignment is not visible to
# a child, so without this the patcher silently uses its own defaults instead.
#
# For DAUM_PROFILE that was already true and had escaped notice because both
# normal invocations happen to work: unset, the patcher defaults to "on" and the
# shell side installs dbprof.h; `DAUM_PROFILE=0 ./build-dosbox-daum.sh` puts it
# in the environment as a command-line assignment, so both sides see 0.  It only
# breaks if someone edits the default above -- then the shell skips installing
# dbprof.h while the patcher still instruments for it, and the build fails on a
# missing header.  Two readers of one setting, reached by different routes.
export DAUM_PROFILE DAUM_BANNER_NOTICE
DBPROF_HEADER="${DBPROF_HEADER:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/vendor/dbprof.h}"

# vendor/dbfpu.h -- the FPU coverage/anomaly histogram.  Always installed: it is
# a correctness instrument, not a performance one, and DAUM_PROFILE=0 must not
# take away the ability to ask which FPU paths a workload reached.
DBFPU_HEADER="${DBFPU_HEADER:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/vendor/dbfpu.h}"

# 3Dfx Glide SDK headers.  include/glide.h expects these in a sibling
# "openglide" directory; they were never part of the Daum source drop.  Taken
# from OpenGlide, which redistributes the Glide 2.x SDK headers unmodified.
OPENGLIDE_REPO="${OPENGLIDE_REPO:-voyageur/openglide}"
OPENGLIDE_REF="${OPENGLIDE_REF:-master}"
OPENGLIDE_RAW="${OPENGLIDE_RAW:-https://raw.githubusercontent.com/${OPENGLIDE_REPO}/${OPENGLIDE_REF}}"
GLIDE_SDK_HEADERS="sdk2_glide.h sdk2_3dfx.h sdk2_glidesys.h sdk2_sst1vid.h sdk2_glideutl.h"

# ---------------------------------------------------------------- Build tools
M4_VERSION="${M4_VERSION:-1.4.19}"
M4_URL="https://ftp.gnu.org/gnu/m4/m4-${M4_VERSION}.tar.xz"

AUTOCONF_VERSION="${AUTOCONF_VERSION:-2.72}"
AUTOCONF_URL="https://ftp.gnu.org/gnu/autoconf/autoconf-${AUTOCONF_VERSION}.tar.xz"

AUTOMAKE_VERSION="${AUTOMAKE_VERSION:-1.17}"
AUTOMAKE_URL="https://ftp.gnu.org/gnu/automake/automake-${AUTOMAKE_VERSION}.tar.xz"

LIBTOOL_VERSION="${LIBTOOL_VERSION:-2.5.4}"
LIBTOOL_URL="https://ftp.gnu.org/gnu/libtool/libtool-${LIBTOOL_VERSION}.tar.xz"

PKGCONF_VERSION="${PKGCONF_VERSION:-2.3.0}"
PKGCONF_URL="https://distfiles.ariadne.space/pkgconf/pkgconf-${PKGCONF_VERSION}.tar.xz"

# nasm assembles two things: ffmpeg's x86_64 SIMD, and vendor/fputest.asm for
# the FPU acceptance check.  Neither is optional -- without it the Intel slice
# loses ffmpeg's hand-written assembly.
NASM_VERSION="${NASM_VERSION:-2.16.03}"
NASM_URL="https://www.nasm.us/pub/nasm/releasebuilds/${NASM_VERSION}/nasm-${NASM_VERSION}.tar.xz"

# sdl12-compat, munt and fluidsynth are all CMake-only projects, and macOS does
# not ship cmake.  With Homebrew and MacPorts off the table it has to be built
# from source; it bootstraps with nothing but a C++ compiler.
CMAKE_VERSION="${CMAKE_VERSION:-3.30.5}"
CMAKE_URL="https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}.tar.gz"

# No meson/ninja: nothing in this project uses them (see FluidSynth note below).

# ------------------------------------------------------------ Runtime libraries
# Daum targets SDL 1.2.  Rather than resurrect SDL 1.2.15 -- which predates
# ARM64 and leans on long-removed Carbon APIs -- we build SDL2 and put
# sdl12-compat on top, which implements the SDL 1.2 API against it.  Daum's
# source needs no changes.
SDL2_VERSION="${SDL2_VERSION:-2.30.9}"
SDL2_URL="https://github.com/libsdl-org/SDL/releases/download/release-${SDL2_VERSION}/SDL2-${SDL2_VERSION}.tar.gz"

SDL12COMPAT_VERSION="${SDL12COMPAT_VERSION:-1.2.68}"
SDL12COMPAT_URL="https://github.com/libsdl-org/sdl12-compat/archive/refs/tags/release-${SDL12COMPAT_VERSION}.tar.gz"

# SDL_net for IPX tunnelling and modem emulation.  The 1.2 series, not the SDL2
# one: Daum uses the SDL_net 1.2 API, and since sdl12-compat provides the SDL
# 1.2 API, classic SDL_net builds against it unmodified.  Mixing in SDL2_net
# would mean patching Daum's networking code for no gain.
SDL_NET_VERSION="${SDL_NET_VERSION:-1.2.8}"
SDL_NET_URL="https://www.libsdl.org/projects/SDL_net/release/SDL_net-${SDL_NET_VERSION}.tar.gz"

LIBPNG_VERSION="${LIBPNG_VERSION:-1.6.58}"
LIBPNG_URL="https://download.sourceforge.net/libpng/libpng-${LIBPNG_VERSION}.tar.xz"

# The three below exist purely to keep Daum's own features alive.  Reading
# Daum's configure.ac shows each one silently disables a feature if absent --
# it only prints AC_MSG_WARN and carries on, so a build that omits them looks
# successful and quietly loses functionality.
#
#   freetype  -> C_PRINTER   (Daum's printer emulation renders glyphs)
#   SDL_sound -> C_SDL_SOUND (compressed CD-DA: ogg/mp3 track images)
#   physfs    -> C_HAVE_PHYSFS
FREETYPE_VERSION="${FREETYPE_VERSION:-2.13.3}"
FREETYPE_URL="https://download.savannah.gnu.org/releases/freetype/freetype-${FREETYPE_VERSION}.tar.xz"

SDL_SOUND_VERSION="${SDL_SOUND_VERSION:-1.0.3}"
SDL_SOUND_URL="https://www.icculus.org/SDL_sound/downloads/SDL_sound-${SDL_SOUND_VERSION}.tar.gz"

# 3.0.2 is the newest release on icculus.org (2019); later versions live only on
# GitHub.  It is also the right choice on API grounds: Daum's drive_physfs.cpp
# is 2015 code using PHYSFS_getLastError, PHYSFS_isDirectory, PHYSFS_read/write
# and the PHYSFS_file spelling.  All of those are still exported by 3.0.2 -- two
# carry PHYSFS_DEPRECATED, the rest are not deprecated at all -- so it compiles
# with warnings rather than errors.  Do not "upgrade" this without checking
# those symbols still exist.
PHYSFS_VERSION="${PHYSFS_VERSION:-3.0.2}"
PHYSFS_URL="https://icculus.org/physfs/downloads/physfs-${PHYSFS_VERSION}.tar.bz2"

# No munt/mt32emu entry: Daum vendors the whole MT-32 emulator in src/gui.

# SoundFont MIDI.
#
# 2.5.0 or newer is required, and not for features: every FluidSynth up to and
# including 2.4.x hard-depends on GLib2.  Pulling glib in would drag along
# libffi, pcre2 and gettext, plus a meson/ninja venv this project otherwise has
# no use for -- five extra components to build, audit for macOS 11 and bundle,
# for one MIDI backend.
#
# 2.5.0 introduced a C++11 OS abstraction layer as a GLib replacement, selected
# with -Dosal=cpp11.  The cost is that libfluidsynth then links the C++ standard
# library, which on macOS is the system libc++ -- nothing extra to ship.
FLUIDSYNTH_VERSION="${FLUIDSYNTH_VERSION:-2.5.0}"
FLUIDSYNTH_URL="https://github.com/FluidSynth/fluidsynth/archive/refs/tags/v${FLUIDSYNTH_VERSION}.tar.gz"

# Video capture.  LGPL configuration only.
FFMPEG_VERSION="${FFMPEG_VERSION:-7.1}"
FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"

# ---------------------------------------------------------------- Checksums
# Nothing is pinned out of the box.  fetch() falls back to the upstream
# .sha256sum sidecar where one exists, records everything else in
# build/checksums.observed, and --strict-sha turns an unverifiable download into
# an error.  Promote entries here once you have a build you trust -- especially
# risc_armv8le.h, which is unpinned code fetched from a moving branch.
KNOWN_SHA256=(
  # "risc_armv8le.h  <sha256>"
  # Published on http://www.libpng.org/pub/png/libpng.html.  SourceForge
  # serves no .sha256sum sidecar, so fetch() cannot pick this up on its own.
  "libpng-${LIBPNG_VERSION}.tar.xz  28eb403f51f0f7405249132cecfe82ea5c0ef97f1b32c5a65828814ae0d34775"
  # Pinned because nasm has a mirror below, and a mirror without a pin is just
  # a stranger's file.  Taken from Debian's PGP-signed nasm_2.16.03-1.dsc, which
  # covers nasm_2.16.03.orig.tar.xz -- the pristine upstream tarball under
  # Debian's naming (a 3.0 (quilt) .orig with no +dfsg suffix is unrepacked),
  # 1032388 bytes.  If you bump NASM_VERSION, this line must go or move with it.
  "nasm-${NASM_VERSION}.tar.xz  1412a1c760bbd05db026b6c0d1657affd6631cd0a63cddb6f73cc6d4aa616148"
  # Same reason -- freetype has mirrors below.  Savannah publishes only a GPG
  # .sig, no sha256 sidecar, so fetch() had nothing to check this against; and
  # Debian is no help here because its freetype is +dfsg (repacked), so its
  # .orig tarball is NOT the upstream file.  Corroborated instead by two
  # independently maintained hash files that agree:
  #   FreeBSD ports 2024Q4  print/freetype2/distinfo   (also gives 2617564 bytes)
  #   Buildroot 2025.02     package/freetype/freetype.hash
  "freetype-${FREETYPE_VERSION}.tar.xz  0550350666d427c74daeb85d5ac7bb353acba5f76956395995311a9c6f063289"
)

# ------------------------------------------------------------------ Mirrors
# "<name fetch saves it as>  <url> [<url> ...]".  Tried in order, only after the
# primary URL fails, and only ever accepted if the sha256 matches -- so every
# entry here needs a KNOWN_SHA256 pin above.
#
# nasm.us earned its entry: it refused connections outright (curl reports 000,
# a connection failure rather than a 404) while its own front page was serving
# normally, which is exactly the kind of outage that should not stop a build of
# twenty other things.
SOURCE_MIRRORS=(
  "nasm-${NASM_VERSION}.tar.xz  http://deb.debian.org/debian/pool/main/n/nasm/nasm_${NASM_VERSION}.orig.tar.xz"
  # download.savannah.gnu.org answered 502.  download-mirror is Savannah's own
  # mirror redirector and SourceForge is FreeType's other official channel --
  # the one Buildroot's hash file cites.  Two entries because the two Savannah
  # hostnames can share whatever is having the bad day.
  "freetype-${FREETYPE_VERSION}.tar.xz  https://download-mirror.savannah.gnu.org/releases/freetype/freetype-${FREETYPE_VERSION}.tar.xz https://downloads.sourceforge.net/project/freetype/freetype2/${FREETYPE_VERSION}/freetype-${FREETYPE_VERSION}.tar.xz"
)

ALL_SOURCE_URLS=(
  "${OPENGLIDE_RAW}/sdk2_glide.h"    "${OPENGLIDE_RAW}/sdk2_3dfx.h"
  "${OPENGLIDE_RAW}/sdk2_glidesys.h" "${OPENGLIDE_RAW}/sdk2_sst1vid.h"
  "${OPENGLIDE_RAW}/sdk2_glideutl.h"
  "$M4_URL" "$AUTOCONF_URL" "$AUTOMAKE_URL" "$LIBTOOL_URL" "$PKGCONF_URL" "$NASM_URL"
  "$CMAKE_URL"
  "$SDL2_URL" "$SDL12COMPAT_URL" "$SDL_NET_URL" "$LIBPNG_URL"
  "$FREETYPE_URL" "$SDL_SOUND_URL" "$PHYSFS_URL"
  "$FLUIDSYNTH_URL" "$FFMPEG_URL"
)

# Only sweep the Daum tarball when it is actually going to be downloaded.  With
# the vendored archive in use, a GitHub outage is irrelevant and preflight
# should not fail over it.
#
# Written as an if block, not `[[ ... ]] && ...`.  This file is sourced under
# `set -e`, so a trailing short-circuit whose test is false makes source return
# 1 and kills the caller silently, with no output at all.
if [[ -z "$DAUM_LOCAL_ARCHIVE" ]]; then
  ALL_SOURCE_URLS+=("$DAUM_URL")
fi

# Never let this file end on a non-zero status.
:

if [[ -z "$ARMV8LE_LOCAL" ]]; then
  ALL_SOURCE_URLS+=("$ARMV8LE_URL")
fi
:
