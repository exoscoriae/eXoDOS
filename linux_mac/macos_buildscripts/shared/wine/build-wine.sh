#!/usr/bin/env bash
#
# build-wine.sh -- build a fully self-contained, portable wine.app for macOS 11+
#
#   * Wine 11.0, Unix side x86_64, PE side i386 + x86_64 (new WoW64)
#   * Every non-system library compiled from source and bundled
#   * MACOSX_DEPLOYMENT_TARGET=11.0 enforced and verified on every Mach-O
#   * wine-gecko and wine-mono staged so fresh prefixes need no network
#   * No Homebrew, no MacPorts: PATH is rebuilt from scratch
#
#   Output: dist/wine.app   (executable: Contents/MacOS/wine)
#
# Run  ./build-wine.sh --help  for options.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------- defaults
DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-11.0}"
BUILD_ROOT="${BUILD_ROOT:-$SCRIPT_DIR/build}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/dist}"
BUILD_ARCHS="${BUILD_ARCHS:-arm64 x86_64}"
STRICT_SHA="${STRICT_SHA:-0}"
SKIP_URL_CHECK="${SKIP_URL_CHECK:-0}"
SKIP_VERIFY="${SKIP_VERIFY:-0}"
WINE_OPENGL="${WINE_OPENGL:-off}"
AVAIL_GUARD="${AVAIL_GUARD--Werror=unguarded-availability-new}"

usage() {
  sed -n '2,13p' "$0" | sed 's/^#\{0,1\} \{0,1\}//'
  cat <<'EOF'

Options
  --build-dir DIR      scratch directory              (default ./build)
  --output DIR         where wine.app is written      (default ./dist)
  --archs "a b"        library architectures to build (default "arm64 x86_64")
                       use --archs x86_64 to halve build time; the arm64 slices
                       are currently inert (see README, "Why x86_64")
  --deployment-target V   minimum macOS version       (default 11.0)
  --with-opengl        pass --with-opengl to Wine (needs an EGL provider)
  --strict-sha         fail on any download without a pinned sha256
  --skip-url-check     skip the preflight URL reachability sweep
  --skip-verify        do not run verify-bundle.sh at the end
  --no-avail-guard     drop -Werror=unguarded-availability-new
  --clean              delete the scratch directory first
  --clean-wine         rebuild only Wine and the bundle, keeping dependencies
  -h, --help           this message

Environment
  Every version and URL in versions.sh can be overridden, e.g.
      FREETYPE_VERSION=2.13.2 ./build-wine.sh
  Set SDKROOT to build against a specific macOS SDK.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-dir)          BUILD_ROOT="$2"; shift 2 ;;
    --output)             OUTPUT_DIR="$2"; shift 2 ;;
    --archs)              BUILD_ARCHS="$2"; shift 2 ;;
    --deployment-target)  DEPLOYMENT_TARGET="$2"; shift 2 ;;
    --with-opengl)        WINE_OPENGL=on; shift ;;
    --strict-sha)         STRICT_SHA=1; shift ;;
    --skip-url-check)     SKIP_URL_CHECK=1; shift ;;
    --skip-verify)        SKIP_VERIFY=1; shift ;;
    --no-avail-guard)     AVAIL_GUARD=""; shift ;;
    --clean)              CLEAN_ALL=1; shift ;;
    --clean-wine)         CLEAN_WINE=1; shift ;;
    -h|--help)            usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

# --------------------------------------------------------------- layout
DOWNLOADS="$BUILD_ROOT/downloads"
SOURCES="$BUILD_ROOT/sources"
BUILD="$BUILD_ROOT/work"
STAMPS="$BUILD_ROOT/stamps"
LOGDIR="$BUILD_ROOT/logs"
TOOLS="$BUILD_ROOT/tools"
VENV="$TOOLS/venv"
MINGW_DIR="$TOOLS/llvm-mingw"
WINE_INSTALL="$BUILD/wine-install"
OBSERVED_SHA="$BUILD_ROOT/checksums.observed"

[[ "${CLEAN_ALL:-0}" == "1" ]] && rm -rf "$BUILD_ROOT"
mkdir -p "$DOWNLOADS" "$SOURCES" "$BUILD" "$STAMPS" "$LOGDIR" "$TOOLS/bin" "$OUTPUT_DIR"

# Both slices only make sense when both are actually built.
if [[ "$BUILD_ARCHS" == *arm64* && "$BUILD_ARCHS" == *x86_64* ]]; then
  UNIVERSAL_DEPS=1
else
  UNIVERSAL_DEPS=0
fi
case "$BUILD_ARCHS" in
  *x86_64*) ;;
  *) echo "x86_64 is mandatory: Wine's Unix side is built for it." >&2; exit 2 ;;
esac

# ---------------------------------------------------------------- includes
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
# shellcheck source=lib/gstreamer.sh
source "$SCRIPT_DIR/lib/gstreamer.sh"
# shellcheck source=lib/wine.sh
source "$SCRIPT_DIR/lib/wine.sh"
# shellcheck source=lib/bundle.sh
source "$SCRIPT_DIR/lib/bundle.sh"

if [[ "${CLEAN_WINE:-0}" == "1" ]]; then
  rm -f "$STAMPS"/wine-*.done
  rm -rf "$BUILD/obj/wine" "$WINE_INSTALL"
fi

START_TS=$(date +%s)
trap 'rc=$?; if [[ $rc -ne 0 ]]; then
        printf "\n%s\n" "${C_R}Build failed (exit $rc).${C_RST}"
        ls -t "$LOGDIR"/*.log 2>/dev/null | head -1 | while read -r l; do
          log_excerpt "$l"
        done
      fi' EXIT

# --------------------------------------------------------------------- go
printf '%s\n' "${C_B}Wine ${WINE_VERSION} universal bundle builder${C_RST}"
printf '  build dir   %s\n' "$BUILD_ROOT"
printf '  output      %s/wine.app\n' "$OUTPUT_DIR"
printf '  archs       %s (universal libs: %s)\n' "$BUILD_ARCHS" "$UNIVERSAL_DEPS"
printf '  min macOS   %s\n' "$DEPLOYMENT_TARGET"

scrub_environment "$TOOLS/bin:$VENV/bin"
run_preflight

build_toolchain

for a in $BUILD_ARCHS; do build_deps_for_arch "$a"; done
for a in $BUILD_ARCHS; do build_gstreamer_for_arch "$a"; done

step "Stage 3b: make the dependency prefixes relocatable"
for a in $BUILD_ARCHS; do
  say "rpathify prefix-$a"
  rpathify_prefix "$BUILD/prefix-$a"
done
ok "install names are @rpath-relative"

build_wine
build_bundle

trap - EXIT

if [[ "$SKIP_VERIFY" != "1" ]]; then
  step "Stage 6: verification"
  "$SCRIPT_DIR/verify-bundle.sh" "$OUTPUT_DIR/wine.app" || {
    printf '\n%s\n' "${C_R}The bundle was built but failed verification (see above).${C_RST}"
    exit 1
  }
fi

ELAPSED=$(( $(date +%s) - START_TS ))
printf '\n%s\n' "${C_G}${C_B}Done in $((ELAPSED/60))m $((ELAPSED%60))s${C_RST}"
printf '  %s\n' "$OUTPUT_DIR/wine.app"
printf '\nTry it:\n'
printf '  %s\n' "\"$OUTPUT_DIR/wine.app/Contents/MacOS/wine\" --version"
printf '  %s\n' "\"$OUTPUT_DIR/wine.app/Contents/MacOS/wine\" winecfg"
