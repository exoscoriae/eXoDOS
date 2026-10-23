#!/usr/bin/env bash
#
# build-dosbox-daum.sh -- portable universal dosbox-daum.app for macOS 11+
#
#   * DOSBox SVN Daum 20150125, the final release
#   * Native arm64 AND x86_64 -- no Rosetta, dynamic recompiler on both
#   * AArch64 dynrec backend grafted in from DOSBox-X (GPLv2, same as Daum)
#   * W^X and 16 KB pages handled for Apple Silicon
#   * SDL 1.2 API provided by sdl12-compat over SDL2
#   * MT-32, FluidSynth, IPX/modem, video capture, 3dfx voodoo
#   * No Homebrew, no MacPorts: PATH is rebuilt from scratch
#
#   Output: dist/dosbox-daum.app   (executable: Contents/MacOS/dosbox-daum)
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename -- "${BASH_SOURCE[0]}")"

DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-11.0}"
BUILD_ROOT="${BUILD_ROOT:-$SCRIPT_DIR/build}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/dist}"
BUILD_ARCHS="${BUILD_ARCHS:-arm64 x86_64}"
STRICT_SHA="${STRICT_SHA:-0}"
SKIP_URL_CHECK="${SKIP_URL_CHECK:-0}"
SKIP_VERIFY="${SKIP_VERIFY:-0}"
AVAIL_GUARD="${AVAIL_GUARD--Werror=unguarded-availability-new}"

usage() {
  sed -n '2,16p' "$0" | sed 's/^#\{0,1\} \{0,1\}//'
  cat <<'EOF'

Options
  --build-dir DIR      scratch directory            (default ./build)
  --output DIR         where the .app is written    (default ./dist)
  --archs "a b"        architectures to build       (default "arm64 x86_64")
  --deployment-target V   minimum macOS             (default 11.0)
  --strict-sha         fail on any download without a verifiable checksum
  --skip-url-check     skip the preflight URL sweep
  --skip-verify        do not run verify-bundle.sh
  --no-avail-guard     drop -Werror=unguarded-availability-new
  --clean              delete the scratch directory first
  --clean-daum         rebuild only DOSBox and the bundle, keeping dependencies
  -h, --help           this message

Environment
  Every version in versions.sh can be overridden.  Most important:
      DOSBOXX_COMMIT=<sha>   pin the AArch64 backend to a known-good commit
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-dir)         BUILD_ROOT="$2"; shift 2 ;;
    --output)            OUTPUT_DIR="$2"; shift 2 ;;
    --archs)             BUILD_ARCHS="$2"; shift 2 ;;
    --deployment-target) DEPLOYMENT_TARGET="$2"; shift 2 ;;
    --strict-sha)        STRICT_SHA=1; shift ;;
    --skip-url-check)    SKIP_URL_CHECK=1; shift ;;
    --skip-verify)       SKIP_VERIFY=1; shift ;;
    --no-avail-guard)    AVAIL_GUARD=""; shift ;;
    --clean)             CLEAN_ALL=1; shift ;;
    --clean-daum)        CLEAN_DAUM=1; shift ;;
    -h|--help)           usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

DOWNLOADS="$BUILD_ROOT/downloads"
SOURCES="$BUILD_ROOT/sources"
BUILD="$BUILD_ROOT/work"
STAMPS="$BUILD_ROOT/stamps"
LOGDIR="$BUILD_ROOT/logs"
TOOLS="$BUILD_ROOT/tools"
VENV="$TOOLS/venv"
OBSERVED_SHA="$BUILD_ROOT/checksums.observed"

[[ "${CLEAN_ALL:-0}" == "1" ]] && rm -rf "$BUILD_ROOT"
mkdir -p "$DOWNLOADS" "$SOURCES" "$BUILD" "$STAMPS" "$LOGDIR" "$TOOLS/bin" "$OUTPUT_DIR"

if [[ "$BUILD_ARCHS" == *arm64* && "$BUILD_ARCHS" == *x86_64* ]]; then
  UNIVERSAL_DEPS=1
else
  UNIVERSAL_DEPS=0
fi

# shellcheck source=versions.sh
source "$SCRIPT_DIR/versions.sh"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/preflight.sh
source "$SCRIPT_DIR/lib/preflight.sh"
# shellcheck source=lib/toolchain.sh
source "$SCRIPT_DIR/lib/toolchain.sh"
# shellcheck source=lib/deps.sh
source "$SCRIPT_DIR/lib/deps.sh"
# shellcheck source=lib/daum.sh
source "$SCRIPT_DIR/lib/daum.sh"
# shellcheck source=lib/bundle.sh
source "$SCRIPT_DIR/lib/bundle.sh"

if [[ "${CLEAN_DAUM:-0}" == "1" ]]; then
  rm -f "$STAMPS"/daum-*.done
  rm -rf "$BUILD"/obj/*/daum "$BUILD"/daum-install-*
  # Delete the extracted tree, not just its stamp.  The source edits are applied
  # in place and are not all idempotent, so a patched tree cannot be re-patched;
  # it has to be re-extracted.  (The previous glob here was dosbox-svn-daum-*,
  # which never matched daum_prepare's $SOURCES/daum-$DAUM_VERSION, so
  # --clean-daum quietly rebuilt against the old patch set.  daum_prepare now
  # fingerprints the patch set and re-extracts on its own, making this flag a
  # convenience rather than the thing correctness depends on.)
  rm -rf "$SOURCES"/daum-*
fi

START_TS=$(date +%s)
trap 'rc=$?; if [[ $rc -ne 0 ]]; then
        printf "\n%s\n" "${C_R}Build failed (exit $rc).${C_RST}"
        ls -t "$LOGDIR"/*.log 2>/dev/null | head -1 | while read -r l; do
          log_excerpt "$l"
        done
      fi' EXIT

printf '%s\n' "${C_B}DOSBox Daum ${DAUM_VERSION} universal bundle builder${C_RST}"
printf '  build dir   %s\n' "$BUILD_ROOT"
printf '  output      %s/dosbox-daum.app\n' "$OUTPUT_DIR"
printf '  archs       %s\n' "$BUILD_ARCHS"
printf '  min macOS   %s\n' "$DEPLOYMENT_TARGET"

scrub_environment "$TOOLS/bin"
run_preflight

build_toolchain
for a in $BUILD_ARCHS; do build_deps_for_arch "$a"; done

step "Stage 2b: make the dependency prefixes relocatable"
for a in $BUILD_ARCHS; do
  say "rpathify prefix-$a"
  rpathify_prefix "$BUILD/prefix-$a"
done
ok "install names are @rpath-relative"

build_daum
build_bundle

trap - EXIT

if [[ "$SKIP_VERIFY" != "1" ]]; then
  step "Stage 5: verification"
  # Run it through bash rather than executing it, so the build does not depend
  # on a mode bit surviving whatever touched the file last.
  #
  # It did not survive: an editor rewrote verify-bundle.sh, the +x went with it,
  # and a build that had passed every one of its own checks died at
  # "Permission denied" after the whole 15 minutes of work.  lib/daum.sh already
  # carries daum_restore_exec_bits() for exactly this failure in the Daum source
  # tree -- the same lesson had simply never been applied to the repo's own
  # scripts.  Removing the dependency is better than restoring the bit, because
  # it cannot silently come undone again.
  [[ -f "$SCRIPT_DIR/verify-bundle.sh" ]] \
    || die "verify-bundle.sh is missing from $SCRIPT_DIR"
  bash "$SCRIPT_DIR/verify-bundle.sh" "$OUTPUT_DIR/dosbox-daum.app" || {
    printf '\n%s\n' "${C_R}The bundle was built but failed verification (see above).${C_RST}"
    exit 1
  }
fi

ELAPSED=$(( $(date +%s) - START_TS ))
printf '\n%s\n' "${C_G}${C_B}Done in $((ELAPSED/60))m $((ELAPSED%60))s${C_RST}"
printf '  %s\n\n' "$OUTPUT_DIR/dosbox-daum.app"
printf 'Try it:\n'
printf '  %s\n' "\"$OUTPUT_DIR/dosbox-daum.app/Contents/MacOS/dosbox-daum\" -version"
printf '  %s\n' "\"$OUTPUT_DIR/dosbox-daum.app/Contents/MacOS/dosbox-daum\" -c 'echo hello' -c exit"
