#!/usr/bin/env bash
#
# 02d-allow-versions.sh — make our pinned KF and Okular (Gear) versions valid build
# targets in the (current) Craft blueprints by editing the central version.ini files.
#
#   kde/frameworks/version.ini    <- add $KF_VERSION (6.5.0), set as default
#   kde/version.ini (Gear/apps)   <- add $OKULAR_VERSION (24.08.3), set as default
#
# Without this, `craft --set version=...` is rejected as an "invalid target" (the
# blueprints only list the last few releases). The digests are fetched from KDE
# (tarballDigestUrl), so no checksums are needed. If a release has been moved off
# stable/ into KDE's Attic/, the tarball URLs are repointed (we only build the one
# pinned version, so changing the shared URL is safe).
#
# Setting defaulttarget makes EVERY package in that category use our version, incl.
# ones we don't pin (breeze-icons; the Gear apps libkexiv2 / kdegraphics-mobipocket).
#
# Must run BEFORE 02 (pin). 03 no longer runs `craft --update` (would revert these).
# ---------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"

command -v curl >/dev/null || die "curl not found."

url_ok() { curl -fsSI --max-time 25 "$1" >/dev/null 2>&1; }

# patch_version_ini <ini> <version> <probe-url-stable>
# Adds <version> to tarballs, sets defaulttarget, and if the stable probe URL 404s
# (i.e. the release moved to Attic) rewrites /stable/ -> /Attic/ in the tarball URLs.
patch_version_ini() {
  local ini="$1" ver="$2" probe="$3"
  [[ -f "$ini" ]] || die "version.ini not found: $ini"

  local attic=0
  if url_ok "$probe"; then
    log "  $ver found under stable/"
  elif url_ok "${probe/\/stable\//\/Attic\/}"; then
    attic=1
    log "  $ver moved to Attic/ — repointing URLs"
  else
    warn "  could not confirm $ver at stable OR Attic; proceeding with stable URL"
  fi

  python3 - "$ini" "$ver" "$attic" <<'PY'
import re, sys
ini, ver, attic = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
src = open(ini).read(); orig = src

def add_tarball(m):
    parts = [v for v in m.group(1).strip().split(';') if v]
    if ver not in parts: parts = [ver] + parts
    return "tarballs = " + ";".join(parts)
src = re.sub(r'tarballs\s*=\s*(.+)', add_tarball, src, count=1)
src = re.sub(r'defaulttarget\s*=\s*.+', f'defaulttarget = {ver}', src, count=1)
if attic:
    # only touch the tarball URL lines (not gitUrl)
    src = re.sub(r'(tarball(?:Digest)?Url\s*=\s*https://download\.kde\.org/)stable/',
                 r'\1Attic/', src)
if src != orig:
    open(ini, "w").write(src); print("  patched", ini)
else:
    print("  no change", ini)
PY
}

for arch in "${ARCHES[@]}"; do
  root="$(craft_root_for "$arch")"
  bp="$root/etc/blueprints/locations/craft-blueprints-kde"
  [[ -d "$bp" ]] || die "blueprints not found for $arch (bootstrap first)."
  kf_pin="${KF_VERSION%.*}"   # 6.5.0 -> 6.5

  log "[$arch] Allowing KF $KF_VERSION + Okular $OKULAR_VERSION + Plasma $PLASMA_VERSION as build targets"
  patch_version_ini "$bp/kde/frameworks/version.ini" "$KF_VERSION" \
    "https://download.kde.org/stable/frameworks/$kf_pin/extra-cmake-modules-$KF_VERSION.tar.xz"
  patch_version_ini "$bp/kde/version.ini" "$OKULAR_VERSION" \
    "https://download.kde.org/stable/release-service/$OKULAR_VERSION/src/okular-$OKULAR_VERSION.tar.xz"
  # Plasma train (plasma-activities, breeze). Probe with plasma-activities since it's
  # the one in Okular's dep closure that surfaced the clash.
  patch_version_ini "$bp/kde/plasma/version.ini" "$PLASMA_VERSION" \
    "https://download.kde.org/stable/plasma/$PLASMA_VERSION/plasma-activities-$PLASMA_VERSION.tar.xz"
done

log "Versions allowed. Next: ./02-pin-versions.sh"
