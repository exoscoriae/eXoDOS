#!/usr/bin/env bash
#
# build-all.sh — end-to-end driver: bootstrap -> pin -> build both arches ->
# merge universal -> audit. Run on an Apple Silicon Mac with Xcode CLT installed.
#
#   ./build-all.sh                 # full run
#   MAKE_DMG=1 ./build-all.sh      # also produce a .dmg
#
# Each stage is idempotent enough to re-run; if a stage fails, fix it and re-run
# the individual numbered script rather than the whole pipeline.
# ---------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"
THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log "Okular $OKULAR_VERSION universal (arm64+x86_64) for macOS $MACOSX_DEPLOYMENT_TARGET+"
log "Qt $QT_VERSION / KF $KF_VERSION / Craft-based / no Brew, no MacPorts"
echo

[[ "$(uname -s)" == "Darwin" ]] || die "This must run on macOS (you're on $(uname -s))."
xcode-select -p >/dev/null 2>&1 || die "Xcode command-line tools missing. Run: xcode-select --install"

# A from-source macOS-11 build must NOT reuse any prebuilt (macOS-12) library that
# an earlier cached run may have installed. CLEAN_ROOTS=1 (default) wipes the two
# CraftRoots first so the stack is rebuilt entirely from source. Set CLEAN_ROOTS=0
# to resume an interrupted from-source build without wiping.
if [[ "${CLEAN_ROOTS:-1}" == "1" ]]; then
  for arch in "${ARCHES[@]}"; do
    root="$(craft_root_for "$arch")"
    if [[ -d "$root" ]]; then
      warn "Wiping $root for a clean from-source build (CLEAN_ROOTS=0 to skip)."
      rm -rf "$root"
    fi
  done
fi

bash "$THIS_DIR/01-bootstrap-craft.sh"
bash "$THIS_DIR/02d-allow-kf621.sh"     # must run BEFORE pinning (makes KF 6.21 a valid target)
bash "$THIS_DIR/02-pin-versions.sh"
bash "$THIS_DIR/02b-prefetch-qt-source.sh"
bash "$THIS_DIR/02c-relax-toolchain.sh"
bash "$THIS_DIR/02e-agl-stub.sh"        # empty AGL.framework so OpenGL-enabled Qt links on macOS 26 SDK
bash "$THIS_DIR/02f-force-deploy.sh"    # clear stale per-package deploy args (global [General] handles the target)
bash "$THIS_DIR/02g-rebuild-perl.sh"    # rebuild Perl from source if cached one has a phantom SDK path (breaks XS modules)
bash "$THIS_DIR/02h-codec-workarounds.sh"  # ffmpeg: --disable-libvpx (its vpx decoder probe fails; VP8/VP9 irrelevant for Okular)
for arch in "${ARCHES[@]}"; do
  bash "$THIS_DIR/03-build-arch.sh" "$arch"
done
bash "$THIS_DIR/04-merge-universal.sh"
bash "$THIS_DIR/05-audit-bundle.sh" || warn "Audit reported findings — review them before distributing."

log "All stages finished. Final app: $DIST_DIR/Okular.app"
