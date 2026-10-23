# shellcheck shell=bash
# ============================================================================
# scripts/verify.sh — prove the bundle meets the contract:
#   1. every Mach-O is universal (arm64 + x86_64)
#   2. every Mach-O's minimum-OS load command is <= macOS 11  (nothing newer)
#   3. NO bundled binary references Brew (/opt/homebrew, /usr/local/Cellar),
#      MacPorts (/opt/local), other third-party prefixes (/Library/Frameworks),
#      or the build-time $PREFIX — only @executable_path/@loader_path/@rpath,
#      /usr/lib, and /System/Library/Frameworks are allowed
#   4. mpv --version / --list-options runs and reports compiled features
#
# Exit non-zero on any violation so build.sh can fail loudly.
# ============================================================================

verify_bundle() {
  local app="${1:-$DIST/mpv.app}"
  local macos="$app/Contents/MacOS"
  [ -d "$macos" ] || die "no bundle at $app"

  local fail=0
  local files=()
  while IFS= read -r f; do files+=("$f"); done < <(_machos_in "$macos")
  log "verifying ${#files[@]} Mach-O objects in $app"

  # ---- 1 & 2: arch + min-OS -------------------------------------------------
  local f
  for f in "${files[@]}"; do
    local archs; archs="$(lipo -archs "$f" 2>/dev/null || echo '?')"
    case "$archs" in
      *arm64*x86_64*|*x86_64*arm64*) : ;;
      *) warn "NOT universal ($archs): ${f#"$app"/}"; fail=1 ;;
    esac
    local bad_minos
    bad_minos="$(_minos_too_new "$f")"
    [ -n "$bad_minos" ] && { warn "min-OS $bad_minos (> 11) in ${f#"$app"/}"; fail=1; }
  done
  [ "$fail" = 0 ] && ok "all objects are universal and target macOS <= 11"

  # ---- 3: forbidden linkage paths ------------------------------------------
  local linkfail=0
  for f in "${files[@]}"; do
    # Dependency lines are indented; the per-file and per-architecture HEADER
    # lines (e.g. "mpv (architecture arm64):") start in column 0. On a fat
    # binary otool prints one header per arch, so a plain `tail -n +2` would
    # mis-read the 2nd arch's header as a dependency. Keep only indented lines.
    local refs; refs="$( { otool -L "$f" 2>/dev/null | grep -E '^[[:space:]]' | awk '{print $1}'; } || true )"
    local r
    while IFS= read -r r; do
      [ -z "$r" ] && continue
      case "$r" in
        @executable_path/*|@loader_path/*|@rpath/*) ;;          # relocatable: OK
        /usr/lib/*|/System/Library/Frameworks/*) ;;             # base system: OK
        /opt/homebrew/*|/usr/local/*) warn "Homebrew ref in ${f#"$app"/}: $r"; linkfail=1 ;;
        /opt/local/*)                 warn "MacPorts ref in ${f#"$app"/}: $r"; linkfail=1 ;;
        /Library/Frameworks/*)        warn "3rd-party framework in ${f#"$app"/}: $r"; linkfail=1 ;;
        "$PREFIX"/*|"$WORK"/*)        warn "un-relocated build path in ${f#"$app"/}: $r"; linkfail=1 ;;
        /*)                           warn "unexpected absolute ref in ${f#"$app"/}: $r"; linkfail=1 ;;
      esac
    done <<< "$refs"
  done
  if [ "$linkfail" = 0 ]; then ok "no Brew/MacPorts/3rd-party/build-path linkage — fully portable"
  else fail=1; fi

  # ---- 3b: no STRONG references to symbols newer than macOS 11 -------------
  # Directly prevents the classic "_kIOMainPortDefault" dyld abort on macOS 11:
  # such a symbol is safe only when weakly linked (target < 12). A non-weak
  # undefined reference means it was built against too-new a target.
  local symfail=0 bad
  for f in "${files[@]}"; do
    bad="$(_forbidden_strong_symbols "$f")" || true
    [ -n "$bad" ] && { warn "strong ref to macOS>11 symbol in ${f#"$app"/}: $bad"; symfail=1; }
  done
  if [ "$symfail" = 0 ]; then ok "no strong references to symbols newer than macOS 11"
  else fail=1; fi

  # ---- 3c: DEFINITIVE symbol-availability audit vs a real macOS 11 SDK ------
  # The denylist in 3b only knows a handful of symbols. Point MACOS11_SDK at a
  # macOS 11.x SDK and we check EVERY strong import against what that SDK says
  # the system actually exported (plus our own bundled libs). This is the
  # comprehensive version of 3b — it catches any too-new symbol, including the
  # Swift-runtime back-deployment case.
  if [ -n "${MACOS11_SDK:-}" ]; then
    local sdk="${MACOS11_SDK/#\~/$HOME}"
    if [ -d "$sdk" ]; then
      log "deep audit: every strong import vs macOS 11 SDK ($sdk)"
      if python3 "$ROOT/scripts/sdk-symbol-audit.py" "$app" "$sdk"; then
        ok "deep SDK symbol audit passed — nothing references a post-11 symbol"
      else
        warn "deep SDK symbol audit FAILED (see above)"; fail=1
      fi
    else
      warn "MACOS11_SDK set but not a directory: $sdk — skipping deep audit"
    fi
  else
    log "set MACOS11_SDK=/path/to/MacOSX11.sdk for the definitive symbol audit"
  fi

  # ---- 4: it actually runs (only meaningful on macOS) ----------------------
  if [ "$(uname -s)" = "Darwin" ]; then
    if [ -x "$macos/mpv" ]; then
      log "mpv --version:"
      "$macos/mpv" --version 2>&1 | head -3 | sed 's/^/      /' || { warn "mpv failed to run"; fail=1; }
    fi
    # FFmpeg tools use `-version` (single dash) and print to stdout.
    local tool
    for tool in ffmpeg ffprobe ffplay; do
      [ -x "$macos/$tool" ] || continue
      log "$tool -version:"
      "$macos/$tool" -version 2>&1 | head -1 | sed 's/^/      /' || { warn "$tool failed to run"; fail=1; }
    done
  fi

  if [ "$fail" = 0 ]; then ok "VERIFICATION PASSED"; else die "VERIFICATION FAILED — see warnings above"; fi
}

# List every Mach-O file under a directory (binaries + dylibs, no symlinks).
_machos_in() {
  find "$1" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \) | while read -r f; do
    if file -b "$f" 2>/dev/null | grep -q 'Mach-O'; then echo "$f"; fi
  done
}

# Denylist of symbols introduced after macOS 11 that, if STRONGLY linked, abort
# at dyld load time on macOS 11. Extend as needed. nm marks a safe reference as
# "weak external"; we only flag non-weak "(undefined) external" lines.
_FORBIDDEN_SYMS='_kIOMainPortDefault'
_forbidden_strong_symbols() {
  local f="$1"
  # NB: the inner greps exit non-zero when they match nothing — which is the
  # GOOD case here. Under `set -e -o pipefail` that would otherwise abort the
  # whole verifier, so swallow the pipeline status with `|| true`.
  { nm -m "$f" 2>/dev/null \
      | grep -E "\(undefined\)" \
      | grep -Ev "weak" \
      | grep -Eo "$_FORBIDDEN_SYMS" \
      | sort -u | tr '\n' ' '; } || true
}

# Echo the offending "x.y" string if any min-OS load command is newer than 11.
_minos_too_new() {
  local f="$1" v
  # LC_BUILD_VERSION uses 'minos'; the legacy LC_VERSION_MIN_MACOSX uses 'version'.
  otool -l "$f" 2>/dev/null \
    | awk '/LC_BUILD_VERSION/{b=1} /LC_VERSION_MIN_MACOSX/{b=1} b && /minos|version/{print $2; b=0}' \
    | while read -r v; do
        local major="${v%%.*}"
        if [ "${major:-0}" -gt 11 ] 2>/dev/null; then echo "$v"; fi
      done | head -1
}
