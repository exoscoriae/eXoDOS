#!/usr/bin/env bash
#
# 02-pin-versions.sh — pin Qt, KDE Frameworks, and Okular to the locked versions
# in BOTH CraftRoots via Craft's per-blueprint version override (etc/BlueprintSettings.ini).
#
#   Qt 6 modules        -> $QT_VERSION   (6.7.3  — newest Qt that runs on macOS 11)
#   KDE Frameworks      -> $KF_VERSION   (6.21.0 — last KF6 that supports Qt 6.7)
#   Okular              -> $OKULAR_VERSION (26.04.2)
#
# Pinning is what keeps the whole stack on the macOS-11-safe side of the line.
# Without it, Craft would pull today's defaults (Qt 6.9+/KF 6.27+), which require
# macOS 12+.
# ---------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Run a craft command inside a given CraftRoot's environment.
run_craft() {
  local root="$1"; shift
  ( set +u
    scrub_brew_env
    # shellcheck disable=SC1091
    source "$root/craft/craftenv.sh"
    craft "$@"
  )
}

# Pin one blueprint to a version; tolerate "not found" (renamed/folded modules).
pin() {
  local root="$1" blueprint="$2" version="$3"
  if run_craft "$root" --set "version=$version" "$blueprint" >/dev/null 2>&1; then
    printf '   pinned %-45s -> %s\n' "$blueprint" "$version"
  else
    warn "could not pin $blueprint (blueprint missing or unversioned) — skipped"
  fi
}

pin_list_file() {
  local root="$1" file="$2" version="$3"
  while IFS= read -r line; do
    line="${line%%#*}"; line="$(echo "$line" | xargs)"   # strip comments + ws
    [[ -z "$line" ]] && continue
    pin "$root" "$line" "$version"
  done < "$file"
}

for arch in "${ARCHES[@]}"; do
  root="$(craft_root_for "$arch")"
  [[ -f "$root/etc/CraftSettings.ini" ]] || die "Root for $arch not bootstrapped. Run ./01-bootstrap-craft.sh first."
  log "Pinning versions in $arch root ($root)"

  log " Qt 6 modules -> $QT_VERSION"
  pin_list_file "$root" "$THIS_DIR/qt6-modules.txt" "$QT_VERSION"

  log " KDE Frameworks -> $KF_VERSION"
  pin_list_file "$root" "$THIS_DIR/kf6-frameworks.txt" "$KF_VERSION"

  log " Okular -> $OKULAR_VERSION"
  pin "$root" "$OKULAR_BLUEPRINT" "$OKULAR_VERSION"
done

log "Version pinning complete. Inspect with:"
log "   cat \"$CRAFT_ROOT_ARM64/etc/BlueprintSettings.ini\""
log "Next: ./03-build-arch.sh arm64   (then x86_64), or ./build-all.sh"
