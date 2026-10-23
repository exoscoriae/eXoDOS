#!/usr/bin/env bash
# ============================================================================
# build.sh — top-level driver for the portable, universal mpv 0.41 app bundle.
#
#   ./build.sh                 # full build: tools -> deps -> mpv -> bundle -> verify
#   ./build.sh deps            # only build/refresh dependencies
#   ./build.sh mpv             # only (re)build mpv + bundle + verify (deps must exist)
#   ./build.sh bundle          # only re-bundle the already-built mpv
#   ./build.sh verify          # only verify dist/mpv.app
#   ./build.sh clean           # remove work/ (sources + staging + prefix)
#   ./build.sh distclean       # remove work/ AND dist/
#
# Run on macOS 11+ with Xcode Command Line Tools installed. Nothing else is
# required on the host — Brew and MacPorts are neither used nor consulted.
# Configuration lives in config.sh; pinned versions in versions.sh.
# ============================================================================
set -euo pipefail

# PID of this top-level shell. die() (in lib.sh) signals it so a failure inside
# any command-substitution subshell aborts the whole build instead of being
# swallowed by a caller's `|| return 0`.
MAIN_PID=$$; export MAIN_PID
trap 'exit 1' TERM

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ROOT

# shellcheck source=config.sh
source "$ROOT/config.sh"
# shellcheck source=versions.sh
source "$ROOT/versions.sh"
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"
# shellcheck source=scripts/bootstrap.sh
source "$ROOT/scripts/bootstrap.sh"
# shellcheck source=scripts/deps.sh
source "$ROOT/scripts/deps.sh"
# shellcheck source=scripts/build-mpv.sh
source "$ROOT/scripts/build-mpv.sh"
# shellcheck source=scripts/bundle.sh
source "$ROOT/scripts/bundle.sh"
# shellcheck source=scripts/verify.sh
source "$ROOT/scripts/verify.sh"

DL_DIR="$WORK/downloads"

preflight() {
  [ "$(uname -s)" = "Darwin" ] || die "This build must run on macOS (host is $(uname -s))."
  mkdir -p "$WORK" "$DL_DIR" "$SRC_DIR" "$STAGE_DIR" "$TOOLS_PREFIX" "$LOG_DIR" "$DIST"
  # Loudly refuse to let Brew/MacPorts leak in even if the operator's shell has them.
  case ":$PATH:" in
    *":/opt/homebrew/bin:"*|*":/usr/local/bin:"*|*":/opt/local/bin:"*)
      warn "Brew/MacPorts dirs are on your PATH; the build sanitizes PATH internally and will ignore them." ;;
  esac
  log "ROOT=$ROOT"
  log "PREFIX=$PREFIX   DIST=$DIST   JOBS=$JOBS   TARGET=macOS $MACOSX_DEPLOYMENT_TARGET   ARCHS=${ARCHS[*]}"
}

stage_all() {
  bootstrap_tools; build_all_deps; build_mpv; bundle_mpv; verify_bundle
  if [ "${ENABLE_FFMPEG_TOOLS:-0}" = 1 ]; then
    bundle_ffmpeg; verify_bundle "$DIST/ffmpeg.app"
  fi
}

case "${1:-all}" in
  all)       preflight; stage_all ;;
  tools)     preflight; bootstrap_tools ;;
  deps)      preflight; bootstrap_tools; build_all_deps ;;
  refresh-dep) preflight; bootstrap_tools; shift; refresh_deps "$@" ;;
  mpv)       preflight; bootstrap_tools; build_mpv; bundle_mpv; verify_bundle ;;
  bundle)    preflight; bootstrap_tools; build_mpv; bundle_mpv ;;
  ffmpeg-app) preflight; bundle_ffmpeg; verify_bundle "$DIST/ffmpeg.app" ;;
  verify)    preflight; verify_bundle "${2:-$DIST/mpv.app}" ;;
  normalize) preflight; normalize_install_names "$PREFIX/lib" ;;
  clean)     rm -rf "$WORK"; ok "removed $WORK" ;;
  distclean) rm -rf "$WORK" "$DIST"; ok "removed $WORK and $DIST" ;;
  *) die "unknown command '$1' (use: all|tools|deps|refresh-dep|mpv|bundle|ffmpeg-app|verify|clean|distclean)" ;;
esac
