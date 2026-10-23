#!/usr/bin/env bash
#
# patch-build-kf.sh <blueprint> [arch] — build ONE package from source with local
# source patches applied, to work around KDE frameworks that call Qt 6.8 APIs even
# though they declare a Qt 6.7 requirement (they won't compile on our Qt 6.7.3).
#
#   ./patch-build-kf.sh kde/frameworks/tier1/karchive arm64
#
# It runs Craft's actions separately so the patch survives:
#   fetch + unpack  ->  apply seds  ->  configure + make + install + qmerge
# Because it INSTALLS the package, a subsequent `build-all` sees it as already
# built and skips it, continuing to the next framework.
#
# Re-running re-extracts a clean source and re-applies ALL registered seds, so add
# new seds to apply_patches() as you discover more spots, then just re-run.
# ---------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"

BP="${1:-}"; ARCH="${2:-arm64}"
[[ -n "$BP" ]] || die "usage: $0 <blueprint> [arch]"
ROOT="$(craft_root_for "$ARCH")"
[[ -f "$ROOT/etc/CraftSettings.ini" ]] || die "Root for $ARCH not bootstrapped."

run_craft() { ( set +u; scrub_brew_env
  export CFLAGS="${CFLAGS:-} -Wno-error=implicit-function-declaration"
  export CXXFLAGS="${CXXFLAGS:-} -Wno-error=implicit-function-declaration"
  [[ "$ARCH" == "x86_64" && "$(uname -m)" == "arm64" ]] && {
    export CFLAGS="$CFLAGS -arch x86_64"; export CXXFLAGS="$CXXFLAGS -arch x86_64"
    export LDFLAGS="${LDFLAGS:-} -arch x86_64"; }
  source "$ROOT/craft/craftenv.sh"; craft "$@" ); }

# Source dir of the just-unpacked package (the single dir under work/).
src_dir() {
  local work="$ROOT/build/$BP/work"
  find "$work" -mindepth 1 -maxdepth 1 -type d ! -name build 2>/dev/null | head -n1
}

# --- Per-blueprint patch registry --------------------------------------------
# Each case edits files under $1 (the unpacked source dir). Add cases as needed.
apply_patches() {
  local s="$1"
  case "$BP" in
    kde/frameworks/tier1/karchive)
      # QHash<QString,*>::value(QStringView) needs Qt 6.8 heterogeneous lookup.
      # Force a QString so it resolves on Qt 6.7.3.
      perl -0pi -e 's/entries\.value\(name\)/entries.value(name.toString())/g' "$s/src/karchive.cpp"
      log "  patched src/karchive.cpp (QStringView -> QString in entries.value)"
      ;;
    perl-modules/xml-parser)
      # XML::Parser's Makefile.PL probes expat with Devel::CheckLib::check_lib,
      # which compiles using Craft-perl's $Config flags -> those clash with Clang 21
      # and the probe fails even though expat is present and links fine (verified).
      # Short-circuit the gate; the real Expat.xs build still links against expat
      # via EXPATINCPATH/EXPATLIBPATH (passed by the blueprint).
      perl -0pi -e 's/\bcheck_lib\(/1 || check_lib(/' "$s/Makefile.PL"
      log "  patched Makefile.PL (bypass broken Devel::CheckLib expat probe)"
      ;;
    *)
      warn "No registered patches for $BP — building it as-is."
      ;;
  esac
}

log "[$ARCH] Patched build of $BP"
run_craft --no-cache --fetch --unpack "$BP"

S="$(src_dir)"
[[ -n "$S" && -d "$S" ]] || die "Could not locate unpacked source under $ROOT/build/$BP/work"
log "Source: $S"
apply_patches "$S"

run_craft --no-cache --configure --make --install --qmerge "$BP"
log "[$ARCH] $BP built with patches. Resume with: CLEAN_ROOTS=0 ./build-all.sh"
