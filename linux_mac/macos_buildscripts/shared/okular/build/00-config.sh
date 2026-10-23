#!/usr/bin/env bash
#
# 00-config.sh — shared configuration for the Okular 26.04 universal macOS 11 build.
#
# Sourced by every other script. Edit values here; do not duplicate them elsewhere.
# ---------------------------------------------------------------------------

set -euo pipefail

# ---------------------------------------------------------------------------
# LOCKED VERSION MATRIX  (see README.md for the reasoning behind every number)
# ---------------------------------------------------------------------------
# Qt 6.7.3 is the NEWEST Qt that still supports macOS 11. Qt 6.8+ requires macOS 12.
#
# IMPORTANT: KDE's declared "minimum Qt" is NOT compile-tested against that minimum
# (their CI builds against the latest Qt), so a KF that *claims* Qt 6.7 support can
# still call Qt 6.8 APIs (observed: KF 6.19 karchive used Qt 6.8 QHash lookup). The
# only reliably Qt-6.7-clean stack is one KDE actually shipped while Qt 6.7 was the
# current Qt (April–Oct 2024, before Qt 6.8.0 on 2024-10-08). That is:
#   - KF 6.5.0      (Aug 2024, last Frameworks before Qt 6.8)
#   - Okular 24.08.3 (KDE Gear 24.08, developed against Qt 6.7; needs only KF >= 6.0)
# This is a tested-together stack, so it avoids the open-ended Qt-6.8-API patching
# that Okular 26.04 + KF 6.19 would have required on Qt 6.7.3.
export QT_VERSION="${QT_VERSION:-6.7.3}"
export KF_VERSION="${KF_VERSION:-6.5.0}"
export OKULAR_VERSION="${OKULAR_VERSION:-24.08.3}"

# FFmpeg must match the version Qt's media plugin was written against. Qt 6.7.x
# bundles FFmpeg 6.1.1; newer ffmpeg (7.x/8.x) removed APIs that Qt 6.7.3 still
# uses (e.g. AV_CODEC_CAP_SUBFRAMES, removed in ffmpeg 8.0), breaking qtmultimedia's
# FFmpeg plugin. 6.1.1 is an offered target in the ffmpeg blueprint.
export FFMPEG_VERSION="${FFMPEG_VERSION:-6.1.1}"

# Plasma packages (plasma-activities, breeze) are versioned on the Plasma train, NOT
# the Frameworks train. The blueprint default (6.5.1) requires ECM/KF 6.18, which
# clashes with our KF 6.5.0. Plasma 6.1.x is the series contemporary with KF 6.5.0
# (Plasma 6.1 needs only KF 6.3; Plasma 6.2 jumped to KF 6.7), so 6.1.5 (last 6.1.x)
# builds cleanly against our stack. 02d adds it to kde/plasma/version.ini.
export PLASMA_VERSION="${PLASMA_VERSION:-6.1.5}"

# ---------------------------------------------------------------------------
# macOS / architecture targets
# ---------------------------------------------------------------------------
# 11.0 = Big Sur. Nothing in the bundle may require anything newer than this.
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"

# Deployment target is enforced GLOBALLY via [General] MacDeploymentTarget=11.0 in
# 01-bootstrap (Craft exports it as MACOSX_DEPLOYMENT_TARGET for every sub-build —
# CMake AND autotools). Do NOT inject a per-package -DCMAKE_OSX_DEPLOYMENT_TARGET:
# autotools configure scripts (ghostscript, djvu) reject -D options and fail. This
# is empty so 02c/02f clear any stale -D that an earlier version set.
export CMAKE_DEPLOY_ARG=""

# The two architectures we build separately and then lipo together.
export ARCHES=("arm64" "x86_64")

# ---------------------------------------------------------------------------
# Filesystem layout
# ---------------------------------------------------------------------------
# Root of this project (the directory that contains build/, dist/, etc.).
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export PROJECT_ROOT

# One independent CraftRoot per architecture. Keep them OUTSIDE the project tree
# (Craft paths get long and the project may live on a synced/cloud folder).
export CRAFT_BASE="${CRAFT_BASE:-$HOME/okular-craft}"
export CRAFT_ROOT_ARM64="${CRAFT_BASE}/CraftRoot-arm64"
export CRAFT_ROOT_X86_64="${CRAFT_BASE}/CraftRoot-x86_64"

# Where the merged universal app and final artifacts are written.
export DIST_DIR="${DIST_DIR:-$PROJECT_ROOT/dist}"

# Upstream Craft (the meta-build system itself). Pinned by branch; you may pin a
# commit with CRAFT_GIT_REF for full reproducibility.
export CRAFT_GIT_URL="https://invent.kde.org/packaging/craft.git"
export CRAFT_GIT_REF="${CRAFT_GIT_REF:-master}"

# ---------------------------------------------------------------------------
# Build tuning
# ---------------------------------------------------------------------------
export CRAFT_JOBS="${CRAFT_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
export CRAFT_BUILD_TYPE="${CRAFT_BUILD_TYPE:-RelWithDebInfo}"

# The top-level Craft blueprint to build. Okular pulls in Qt, KF, and all backend
# libraries transitively, so this single target builds the whole stack.
export OKULAR_BLUEPRINT="${OKULAR_BLUEPRINT:-kde/applications/okular}"

# ---------------------------------------------------------------------------
# FROM-SOURCE policy (the macOS-11 requirement forces this)
# ---------------------------------------------------------------------------
# KDE's prebuilt binary cache (files.kde.org/craft/...) is built on macOS 12 and
# ships current Qt 6.9+/KF, which require macOS 12. None of it is safe for a
# macOS-11 bundle. So every package that lands in the app is built from source
# with `craft --no-cache`. Dev-tools fetched during bootstrap don't ship in the
# bundle, so those may still come from cache.
export CRAFT_NOCACHE_FLAG="${CRAFT_NOCACHE_FLAG:---no-cache}"

# Pinning Qt to 6.7.3 forces a source build, but 6.7.3 has been moved to Qt's
# ARCHIVE area; the blueprint's default 'official_releases' URL 404s for it
# (verified). 02b-prefetch-qt-source.sh pre-places the tarballs from here into
# each root's download/archives/ so Craft finds them locally and skips the dead URL.
export QT_ARCHIVE_BASE="${QT_ARCHIVE_BASE:-https://download.qt.io/archive/qt/6.7/6.7.3/submodules}"

# Qt 6 source submodules to pre-place (blueprint leaf name == tarball name stem).
# Extra entries are harmless; missing ones are skipped. Okular needs qtbase plus
# these; qtshadertools/qttranslations are build-time deps of qtdeclarative/qttools.
export QT_SUBMODULES=(
  qtbase qtshadertools qtsvg qtimageformats qtlanguageserver qtdeclarative
  qttools qttranslations qt5compat qtmultimedia qtspeech qtwayland
)

# ---------------------------------------------------------------------------
# Helper: return the CraftRoot path for a given architecture
# ---------------------------------------------------------------------------
craft_root_for() {
  case "$1" in
    arm64)  echo "$CRAFT_ROOT_ARM64" ;;
    x86_64) echo "$CRAFT_ROOT_X86_64" ;;
    *) echo "Unknown arch: $1" >&2; return 1 ;;
  esac
}

# Craft ABI string for a given architecture.
craft_abi_for() {
  case "$1" in
    arm64)  echo "macos-clang-arm64" ;;
    x86_64) echo "macos-clang-x86_64" ;;
    *) echo "Unknown arch: $1" >&2; return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Homebrew / MacPorts scrubbing
# ---------------------------------------------------------------------------
# The project forbids ANY Brew/MacPorts involvement. If those are installed and
# on PATH, autotools configure scripts (e.g. gnutls) silently pick up their tools
# (ginstall, gmkdir) and can link their libraries. We run every craft command
# with a PATH that contains ONLY system + Craft directories. Craft is
# self-contained (its dev-utils provide cmake, ninja, autotools, coreutils), so
# nothing of value is lost. CMake packages additionally get
# -DCMAKE_IGNORE_PREFIX_PATH for /opt/homebrew (Craft adds this itself).
export CLEAN_BASE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

# Apply inside a craft subshell BEFORE sourcing craftenv.sh, so Craft prepends
# its own tool dirs to a Homebrew-free base.
scrub_brew_env() {
  export PATH="$CLEAN_BASE_PATH"
  unset HOMEBREW_PREFIX HOMEBREW_CELLAR HOMEBREW_REPOSITORY HOMEBREW_SHELLENV_PREFIX 2>/dev/null || true
  # Don't let pkg-config / autoconf reach into Brew/MacPorts trees.
  unset PKG_CONFIG_PATH ACLOCAL_PATH CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH LIBRARY_PATH LD_LIBRARY_PATH 2>/dev/null || true
}

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }
