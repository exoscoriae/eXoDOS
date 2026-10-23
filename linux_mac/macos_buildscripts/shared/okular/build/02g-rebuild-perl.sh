#!/usr/bin/env bash
#
# 02g-rebuild-perl.sh — rebuild Craft's Perl from source when the installed (cached)
# one carries a phantom SDK path.
#
# Craft's binary-cache Perl was built on KDE CI with full Xcode, so its $Config{ccflags}
# embed `-isysroot /Applications/Xcode.app/.../MacOSX.sdk` and `-mmacosx-version-min=13`.
# On a Command-Line-Tools-only machine that SDK path doesn't exist, so EVERY Perl XS
# module (xml-parser, uri-url, ...) fails to compile with "stdlib.h file not found".
# A source-built Perl picks up the real CLT SDK and our macOS-11 target, fixing the
# whole class at once. Idempotent: only rebuilds if the perl SDK path is missing, so
# re-runs (after a source rebuild) are no-ops.
# ---------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"

run_craft() {
  local root="$1"; shift
  ( set +u; scrub_brew_env; source "$root/craft/craftenv.sh"; craft "$@" )
}

for arch in "${ARCHES[@]}"; do
  root="$(craft_root_for "$arch")"
  perlbin="$root/bin/perl"
  if [[ ! -x "$perlbin" ]]; then
    log "[$arch] perl not yet installed — it'll build from source on demand (--no-cache)."
    continue
  fi
  # Extract the -isysroot path baked into perl's compile flags.
  sysroot="$("$perlbin" -V:ccflags 2>/dev/null | grep -o "\-isysroot[ =][^ ']*" | head -n1 | sed -E 's/-isysroot[ =]//')"
  if [[ -n "$sysroot" && ! -d "$sysroot" ]]; then
    warn "[$arch] perl's \$Config points at a missing SDK ($sysroot) — rebuilding perl from source."
    run_craft "$root" --unmerge dev-utils/perl || true
    run_craft "$root" --no-cache dev-utils/perl
  else
    log "[$arch] perl SDK OK (${sysroot:-none}) — no rebuild needed."
  fi
done

log "Perl check done. Next: ./03-build-arch.sh"
