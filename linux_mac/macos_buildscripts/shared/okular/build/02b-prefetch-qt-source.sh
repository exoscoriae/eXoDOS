#!/usr/bin/env bash
#
# 02b-prefetch-qt-source.sh — pre-place Qt 6.7.3 source tarballs so the from-source
# build doesn't hit Qt's dead 'official_releases' URL for this archived version.
#
# Qt 6.7.3 was moved to https://download.qt.io/archive/qt/6.7/6.7.3/submodules/ .
# Craft's qtbase blueprint still builds the official_releases URL, which 404s
# (verified on the first run). Craft checks its local download/archives/ directory
# BEFORE downloading, so if we drop the correct tarball there, it uses it directly.
#
# We place each tarball at:
#   <root>/download/archives/libs/qt6/<module>/<module>-everywhere-src-6.7.3.tar.xz
# which is exactly the path Craft tried to write to.
# ---------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"

command -v curl >/dev/null || die "curl not found."

# ---------------------------------------------------------------------------
# Repoint the qt6 blueprint URL at the working /archive/ location.
# ---------------------------------------------------------------------------
# The bundled blueprints template the Qt source URL as
# download.qt.io/official_releases/... which 404s for the archived 6.7.3. Craft
# only skips its own download when the LOCAL tarball's hash matches the blueprint's
# expected digest; otherwise it re-fetches from that dead URL (with `curl -C -`),
# which is why a prefetched file alone isn't reliable. Rewriting tarballUrl AND
# tarballDigestUrl in libs/qt6/version.ini to download.qt.io/archive makes Craft
# fetch + verify straight from the archive (which serves both the .tar.xz and its
# .sha256). The prefetch below then just warms the cache. Idempotent.
patch_qt_versionini() {
  local root="$1" dir="$root/etc/blueprints/locations/craft-blueprints-kde/libs/qt6"
  local base='https://download.qt.io/archive/qt/${VERSION_MAJOR}.${VERSION_MINOR}/${VERSION}/submodules/${PACKAGE_NAME}-everywhere-src-${VERSION}'
  # 6.7.3 is declared in version_upstream.ini (version.ini only owns <=6.5.2), and
  # Craft takes the URL from whichever ini declares the version. So patch ALL of the
  # chained qt6 version inis, not just the top one.
  local f patched=0
  for f in version.ini version_upstream.ini version_unstable.ini; do
    local ini="$dir/$f"
    [[ -f "$ini" ]] || continue
    python3 - "$ini" "$base" <<'PY'
import re, sys
ini, base = sys.argv[1], sys.argv[2]
src = open(ini).read(); orig = src
# Only rewrite ACTIVE (non-commented) lines, and only those still on official_releases.
src = re.sub(r'(?m)^(\s*)tarballUrl\s*=\s*https://download\.qt\.io/official_releases/.*$',
             rf'\1tarballUrl = {base}.tar.xz', src)
src = re.sub(r'(?m)^(\s*)tarballDigestUrl\s*=\s*https://download\.qt\.io/official_releases/.*$',
             rf'\1tarballDigestUrl = {base}.tar.xz.sha256', src)
open(ini,"w").write(src)
print("CHANGED" if src != orig else "same")
PY
  done >/tmp/_qtini.$$ 2>&1
  if grep -q CHANGED /tmp/_qtini.$$; then
    log "   patched qt6 version inis -> /archive/ URLs"; patched=1
  else
    log "   qt6 version inis already archive-pointed"
  fi
  rm -f /tmp/_qtini.$$
}

# Download <module> archive into one root, if not already present. Returns 0 on
# success/exists, 1 if the module isn't published as a standalone tarball.
prefetch_one() {
  local root="$1" module="$2"
  local destdir="$root/download/archives/libs/qt6/$module"
  local file="$module-everywhere-src-$QT_VERSION.tar.xz"
  local dest="$destdir/$file"
  local url="$QT_ARCHIVE_BASE/$file"

  # Only accept an existing file if it's a COMPLETE, valid .tar.xz. A truncated
  # tarball (interrupted prefetch) passes a mere -s test but makes Craft try to
  # RESUME it with `curl -C -` against the dead official_releases URL -> 404. Verify
  # by listing the archive; if that fails, drop it and re-download.
  if [[ -s "$dest" ]]; then
    if tar -tf "$dest" >/dev/null 2>&1; then
      printf '   have   %s\n' "$module"; return 0
    fi
    warn "   bad/partial archive for $module — re-downloading"
    rm -f "$dest"
  fi
  mkdir -p "$destdir"
  if curl -fL --retry 5 --progress-bar -o "$dest.part" "$url"; then
    mv "$dest.part" "$dest"
    printf '   got    %s\n' "$module"; return 0
  else
    rm -f "$dest.part"
    warn "   skip   $module (no standalone tarball at archive — Craft will resolve it)"
    return 1
  fi
}

for arch in "${ARCHES[@]}"; do
  root="$(craft_root_for "$arch")"
  [[ -d "$root" ]] || die "Root for $arch missing. Run ./01-bootstrap-craft.sh first."
  log "Repointing qt6 source URL to /archive/ ($arch)"
  patch_qt_versionini "$root"
  log "Prefetching Qt $QT_VERSION source into $arch root"
  for m in "${QT_SUBMODULES[@]}"; do
    prefetch_one "$root" "$m" || true
  done
done

log "Qt source prefetch done."
log "Next: ./03-build-arch.sh arm64   (then x86_64)"
