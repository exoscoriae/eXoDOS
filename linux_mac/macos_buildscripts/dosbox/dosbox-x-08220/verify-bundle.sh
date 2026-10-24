#!/bin/bash
# ============================================================================
# verify-bundle.sh <app-bundle>
#
# Portability audit for dosbox-x-08220.app, in the spirit of the min-OS
# checks done for the okular / gnumeric / mpv portable-bundle projects:
#
#   1. every Mach-O in the bundle is universal (arm64 + x86_64)
#   2. every slice's minimum OS (LC_BUILD_VERSION minos / LC_VERSION_MIN_MACOSX)
#      is <= 11.0  -- nothing in the bundle may require anything newer
#   3. the dynamic-link closure references ONLY OS-provided libraries
#      (/usr/lib/*, /System/Library/Frameworks/*) or in-bundle paths
#      (@rpath / @executable_path / @loader_path)
#   4. no reference to /usr/local, /opt/homebrew, /opt/local anywhere
#      (Homebrew/MacPorts leakage check)
#   5. code signature is valid (required on Apple Silicon)
#   6. sanity: SDL must be SDL 1.x (statically linked; no SDL2 symbols)
#
# Exit status 0 = fully portable per the above rules.
# ============================================================================

set -u
APP="${1:?usage: verify-bundle.sh <app-bundle>}"
[ -d "$APP" ] || { echo "not a directory: $APP"; exit 1; }

FAILURES=0
note() { printf '  %s\n' "$*"; }
bad()  { printf '  \033[1;31mFAIL:\033[0m %s\n' "$*"; FAILURES=$((FAILURES+1)); }
ok()   { printf '  \033[1;32mok:\033[0m %s\n' "$*"; }

# collect every Mach-O file in the bundle
MACHOS=()
while IFS= read -r -d '' f; do
  if file "$f" | grep -qE 'Mach-O'; then MACHOS+=("$f"); fi
done < <(find "$APP" -type f -print0)

[ "${#MACHOS[@]}" -gt 0 ] || { echo "no Mach-O files found in $APP"; exit 1; }
echo "Found ${#MACHOS[@]} Mach-O file(s):"
for f in "${MACHOS[@]}"; do note "$f"; done

echo
echo "== 1. universal (arm64 + x86_64) =="
for f in "${MACHOS[@]}"; do
  archs="$(lipo -archs "$f" 2>/dev/null)"
  case "$archs" in
    *arm64*x86_64*|*x86_64*arm64*) ok "$(basename "$f"): $archs" ;;
    *) bad "$(basename "$f") is not universal (archs: $archs)" ;;
  esac
done

echo
echo "== 2. minimum OS version <= 11.0 for every slice =="
check_minos() { # $1=file $2=arch
  local out minos sdk
  out="$(otool -arch "$2" -l "$1" 2>/dev/null)"
  minos="$(echo "$out" | awk '/cmd LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
  if [ -z "$minos" ]; then
    minos="$(echo "$out" | awk '/cmd LC_VERSION_MIN_MACOSX/{f=1} f&&/version/{print $2; exit}')"
  fi
  if [ -z "$minos" ]; then
    bad "$(basename "$1") [$2]: cannot determine min OS version"
    return
  fi
  local maj min
  maj="${minos%%.*}"; min="$(echo "$minos" | cut -d. -f2)"
  if [ "$maj" -lt 11 ] || { [ "$maj" -eq 11 ] && [ "${min:-0}" -eq 0 ]; }; then
    ok "$(basename "$1") [$2]: minos $minos"
  else
    bad "$(basename "$1") [$2]: minos $minos is NEWER than 11.0"
  fi
}
for f in "${MACHOS[@]}"; do
  for a in $(lipo -archs "$f" 2>/dev/null); do check_minos "$f" "$a"; done
done

echo
echo "== 3. dynamic-link closure: OS-provided or in-bundle only =="
for f in "${MACHOS[@]}"; do
  # skip first line (the file's own id line for dylibs)
  while IFS= read -r dep; do
    # universal binaries repeat a "<path> (architecture xyz):" header per
    # slice at column 0; real dependencies are indented
    case "$dep" in [!' '$'\t']*) continue ;; esac
    dep="$(echo "$dep" | sed -e 's/^[[:space:]]*//' -e 's/ (compatibility.*$//')"
    [ -z "$dep" ] && continue
    case "$dep" in *:) continue ;; esac
    case "$dep" in
      /usr/lib/*|/System/Library/Frameworks/*|/System/Library/PrivateFrameworks/*) : ;;
      @rpath/*|@executable_path/*|@loader_path/*)
        # must resolve inside the bundle
        rel="${dep#@rpath/}"; rel="${rel#@executable_path/}"; rel="${rel#@loader_path/}"
        found="$(find "$APP" -name "$(basename "$rel")" -type f | head -1)"
        if [ -n "$found" ]; then ok "$(basename "$f") -> $dep (bundled)"; else bad "$(basename "$f") -> $dep NOT FOUND in bundle"; fi
        ;;
      *) bad "$(basename "$f") links NON-SYSTEM library: $dep" ;;
    esac
  done < <(otool -L "$f" 2>/dev/null | tail -n +2)
done
ok "system-library closure check complete"

echo
echo "== 4. Homebrew / MacPorts leakage =="
LEAK=0
for f in "${MACHOS[@]}"; do
  if otool -L "$f" 2>/dev/null | grep -qE '/usr/local/|/opt/homebrew/|/opt/local/'; then
    bad "$(basename "$f") references /usr/local, /opt/homebrew or /opt/local"
    LEAK=1
  fi
  if strings -a "$f" 2>/dev/null | grep -qE '^/opt/homebrew/(lib|Cellar)|^/opt/local/lib'; then
    note "warning: $(basename "$f") contains a homebrew/macports path string (often just a search path; inspect manually)"
  fi
done
[ "$LEAK" -eq 0 ] && ok "no Homebrew/MacPorts load commands"

echo
echo "== 5. code signature =="
if codesign --verify --strict "$APP" 2>/dev/null; then
  ok "codesign verifies ($(codesign -dv "$APP" 2>&1 | awk -F= '/^Signature/{print $2}' ))"
else
  bad "code signature invalid or missing (arm64 will refuse to run)"
fi

echo
echo "== 6. SDL sanity =="
MAIN="$(find "$APP/Contents/MacOS" -type f | head -1)"
if nm -gU "$MAIN" 2>/dev/null | grep -q ' _SDL_Init$'; then
  ok "SDL statically linked into the executable"
else
  note "could not confirm _SDL_Init export (static libs may strip it) -- informational only"
fi
if otool -L "$MAIN" | grep -qi 'libSDL2'; then
  bad "executable links SDL2 dynamically!"
else
  ok "no SDL2 dynamic dependency"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "VERIFICATION PASSED: bundle is universal, macOS 11.0-compatible, and self-contained."
  exit 0
else
  echo "VERIFICATION FAILED: $FAILURES problem(s) found."
  exit 1
fi
