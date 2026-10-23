#!/usr/bin/env bash
#
# 02h-codec-workarounds.sh — make the ffmpeg/qtmultimedia subtree build on the
# Qt 6.7.3 stack. Two fixes:
#
#  1. Pin ffmpeg to $FFMPEG_VERSION (6.1.1). Qt 6.7.3's bundled FFmpeg media plugin
#     was written against the ffmpeg 6.x API; ffmpeg 8.1.1 (the blueprint default)
#     removed symbols Qt still uses (AV_CODEC_CAP_SUBFRAMES, removed in ffmpeg 8.0),
#     so qtmultimedia fails to compile. 6.1.1 is the version Qt officially bundles
#     for the 6.7 series and is an offered target in the ffmpeg blueprint.
#
#  2. Drop libvpx from ffmpeg. Its configure dies "libvpx enabled but no supported
#     decoders found"; our libvpx exposes no VP8/VP9 decoder symbols ffmpeg accepts.
#     Setting args=--disable-libvpx loses to the blueprint's hardcoded
#     --enable-libvpx (ffmpeg honors the LAST flag), so we delete the flag (and the
#     libs/libvpx dependency) from the blueprint outright. VP8/VP9 are irrelevant to
#     a PDF viewer; the rest of ffmpeg (H.264/H.265/AV1/Opus/Vorbis/WebP) stays.
#
# Idempotent: re-runs re-apply the same pin/patch and clean only what exists.
# ---------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"

REL="etc/blueprints/locations/craft-blueprints-kde/libs/ffmpeg/ffmpeg.py"

run_craft() {
  local root="$1"; shift
  ( set +u; scrub_brew_env; source "$root/craft/craftenv.sh"; craft "$@" )
}

patch_ffmpeg() {
  local root="$1" bp="$root/$REL"
  if [[ ! -f "$bp" ]]; then
    warn "ffmpeg blueprint not found at $bp — skipped (will exist after bootstrap)."
    return 0
  fi
  local changed=0
  if grep -q '"--enable-libvpx"' "$bp"; then
    sed -i '' '/"--enable-libvpx",/d' "$bp"; changed=1
  fi
  if grep -q 'runtimeDependencies\["libs/libvpx"\]' "$bp"; then
    sed -i '' '/runtimeDependencies\["libs\/libvpx"\]/d' "$bp"; changed=1
  fi
  [[ "$changed" == "1" ]] && log "   patched ffmpeg blueprint (libvpx removed)" \
                          || log "   ffmpeg blueprint already libvpx-free"
  grep -q '"--enable-libvpx"' "$bp" && die "Failed to remove --enable-libvpx from $bp"
  return 0
}

for arch in "${ARCHES[@]}"; do
  root="$(craft_root_for "$arch")"
  [[ -f "$root/etc/CraftSettings.ini" ]] || die "Root for $arch not bootstrapped."
  log "[$arch] ffmpeg/qtmultimedia workarounds"

  # 1) libvpx out of the blueprint
  patch_ffmpeg "$root"

  # 2) pin ffmpeg to the Qt-6.7-compatible version
  if run_craft "$root" --set "version=$FFMPEG_VERSION" libs/ffmpeg >/dev/null 2>&1; then
    log "   pinned libs/ffmpeg -> $FFMPEG_VERSION"
  else
    warn "could not pin ffmpeg version"
  fi

  # 3) clear any previously-built newer ffmpeg + qtmultimedia so they rebuild/reconfigure
  #    cleanly against the pinned version (stale libav*.dylib and CMake cache otherwise
  #    linger and mis-detect). No-ops on a fresh root.
  run_craft "$root" --unmerge libs/ffmpeg >/dev/null 2>&1 || true
  rm -rf "$root/build/libs/ffmpeg/work" "$root/build/libs/qt6/qtmultimedia/work" 2>/dev/null || true
done

log "Codec workarounds applied. Next: ./03-build-arch.sh"
