#!/usr/bin/env bash
#
# 02i-restore-libz.sh — restore the one casualty of an earlier, mistaken
# `craft --unmerge libs/zlib`: it deleted libz.1.dylib from CraftRoot-arm64/lib,
# which (a) broke Craft's own curl ("Library not loaded: …/libz.1.dylib") and
# (b) left macdeployqt with no libz to bundle. Put it back by extracting this
# arch's slice from the already-built universal app in $DIST_DIR.
#
# The ACTUAL deployment-target fix (relabel any minos>11 Mach-O to 11.0) now lives
# in 04, applied to the FINAL universal bundle — that is what ships and what 05
# audits, and doing it there sidesteps the murky CraftRoot-vs-stale-archive
# question entirely. 06-symbol-availability.sh then proves the relabel is honest.
#
# Run this, then ./04-merge-universal.sh && ./05-audit-bundle.sh, then 06.
# ---------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"

command -v lipo >/dev/null || die "lipo not found (install Xcode command-line tools)."

DIST_FW="$DIST_DIR/Okular.app/Contents/Frameworks"

restore_libz() {
  local arch="$1" root
  root="$(craft_root_for "$arch")"
  [[ -d "$root/lib" ]] || die "[$arch] lib dir missing: $root/lib"

  if [[ -e "$root/lib/libz.1.dylib" ]]; then
    log "[$arch] libz.1.dylib present — nothing to restore."
    return 0
  fi

  log "[$arch] libz.1.dylib missing (deleted by the earlier --unmerge). Restoring from the universal bundle."
  local src="$DIST_FW/libz.1.3.1.dylib"
  [[ -e "$src" ]] || die "[$arch] cannot restore libz: $src not found (need the last good dist build)."

  if [[ "$(lipo -archs "$src" 2>/dev/null | wc -w)" -gt 1 ]]; then
    lipo "$src" -thin "$arch" -output "$root/lib/libz.1.3.1.dylib" \
      || die "[$arch] lipo could not extract the $arch slice of libz from $src"
  else
    /bin/cp "$src" "$root/lib/libz.1.3.1.dylib"
  fi
  ln -sfn libz.1.3.1.dylib "$root/lib/libz.1.dylib"
  ln -sfn libz.1.dylib     "$root/lib/libz.dylib"
  # Conventional absolute install id; dyld loads it by the path recorded in
  # curl/git/dependents, which exists again now.
  install_name_tool -id "$root/lib/libz.1.dylib" "$root/lib/libz.1.3.1.dylib" 2>/dev/null || true
  log "[$arch]   restored $root/lib/libz.1.3.1.dylib (+ libz.1.dylib, libz.dylib symlinks)"
}

for arch in "${ARCHES[@]}"; do
  log "=== [$arch] Restoring libz casualty ==="
  restore_libz "$arch"
done

log "Done. Next: ./04-merge-universal.sh && ./05-audit-bundle.sh"
log "(04 now relabels any minos>11 Mach-O in the bundle to 11.0; 05 verifies; then run 06.)"
