#!/bin/bash
# =============================================================================
# build.sh - Portable universal Gnumeric.app builder for macOS 11+
#
# Builds Gnumeric 1.12.61 and its entire dependency stack from source,
# for both arm64 and x86_64, with MACOSX_DEPLOYMENT_TARGET=11.0, and
# assembles a fully self-contained, relocatable Gnumeric.app.
#
# No Homebrew. No MacPorts. Only Apple's Command Line Tools + network.
#
# Usage:
#   ./build.sh all                  # everything, start to finish
#   ./build.sh download             # fetch all source tarballs only
#   ./build.sh tools                # native host tools (pkg-config, meson, ...)
#   ./build.sh deps arm64           # build library stack for one arch
#   ./build.sh deps x86_64
#   ./build.sh bundle               # assemble universal Gnumeric.app
#   ./build.sh verify               # audit the finished bundle
#   ./build.sh clean                # remove build trees (keeps downloads)
#
#   RESUME_FROM=<pkg> ./build.sh deps arm64    # resume a failed stage
#   ONLY=<pkg>        ./build.sh deps arm64    # (re)build a single package
# =============================================================================
set -e
set -o pipefail

TOP="$(cd "$(dirname "$0")" && pwd)"
export TOP
. "$TOP/lib/common.sh"
. "$TOP/lib/recipes.sh"

usage() { sed -n '2,22p' "$0"; exit 1; }

cmd="${1:-}"
arg="${2:-}"

case "$cmd" in
  download)
    sanity_checks
    download_all
    ;;
  tools)
    sanity_checks
    download_all
    build_host_tools
    ;;
  deps)
    [ "$arg" = "arm64" ] || [ "$arg" = "x86_64" ] || usage
    sanity_checks
    build_host_tools
    build_stack "$arg"
    ;;
  bundle)
    sanity_checks
    . "$TOP/lib/bundle.sh"
    make_bundle
    ;;
  verify)
    exec "$TOP/verify.sh" "$TOP/dist/gnumeric.app"
    ;;
  all)
    sanity_checks
    download_all
    build_host_tools
    build_stack arm64
    build_stack x86_64
    . "$TOP/lib/bundle.sh"
    make_bundle
    "$TOP/verify.sh" "$TOP/dist/gnumeric.app"
    ;;
  clean)
    rm -rf "$TOP/work/build" "$TOP/work/root-arm64" "$TOP/work/root-x86_64" \
           "$TOP/work/tools" "$TOP/work/bundle-arm64" "$TOP/work/bundle-x86_64" \
           "$TOP/work/stamps"
    echo "Cleaned build trees (downloads in work/src kept)."
    ;;
  distclean)
    rm -rf "$TOP/work" "$TOP/dist"
    ;;
  *)
    usage
    ;;
esac

echo ""
echo "== '$cmd' finished OK =="
