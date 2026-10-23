#!/bin/bash
# =============================================================================
# verify.sh - audit a built Gnumeric.app for portability and macOS 11+ compat
#
#   ./verify.sh dist/gnumeric.app
#
# Checks, for EVERY Mach-O file in the bundle:
#   1. universal: contains both arm64 and x86_64 slices
#   2. min-OS: every slice's LC_BUILD_VERSION/LC_VERSION_MIN_MACOSX <= 11.0
#   3. linkage: only @rpath/@executable_path/@loader_path, /usr/lib, /System
#   4. rpaths: no absolute rpaths left behind
# Plus:
#   5. ODS (OpenDocument) plugin presence + plugin inventory
#   6. functional smoke test: csv -> ods -> csv via bundled ssconvert
# =============================================================================
set -u

APP="${1:-dist/gnumeric.app}"
[ -d "$APP" ] || { echo "usage: $0 path/to/gnumeric.app" >&2; exit 2; }
APP="$(cd "$APP" && pwd)"

FAILLOG="$(mktemp)"
trap 'rm -f "$FAILLOG"' EXIT
fail() { echo "FAIL: $*" | tee -a "$FAILLOG"; }

# min-OS of one slice; prints e.g. "11.0", empty if load command absent
slice_minos() { # <file> <arch>
  otool -arch "$2" -l "$1" 2>/dev/null | awk '
    /cmd LC_BUILD_VERSION/      {b=1}
    b && /minos/                {print $2; exit}
    /cmd LC_VERSION_MIN_MACOSX/ {v=1}
    v && /version /             {print $2; exit}'
}

minos_ok() { # <ver>  -> true if <= 11.0
  local maj min
  maj="${1%%.*}"
  min="$(echo "$1" | cut -d. -f2)"
  [ "$maj" -lt 11 ] && return 0
  [ "$maj" -eq 11 ] && [ "${min:-0}" -eq 0 ] && return 0
  return 1
}

echo "== Auditing $APP =="
NMACHO=0
MACHOS="$(mktemp)"
find "$APP" -type f | while IFS= read -r f; do
  file -b "$f" 2>/dev/null | grep -q 'Mach-O' && echo "$f"
done > "$MACHOS"

while IFS= read -r f; do
  NMACHO=$((NMACHO+1))
  rel="${f#$APP/}"

  # 1. universal
  archs="$(lipo -archs "$f" 2>/dev/null)"
  case "$archs" in
    *arm64*x86_64*|*x86_64*arm64*) : ;;
    *) fail "$rel: not universal (archs: ${archs:-unknown})" ;;
  esac

  # 2. min-OS per slice
  for a in arm64 x86_64; do
    echo "$archs" | grep -q "$a" || continue
    v="$(slice_minos "$f" "$a")"
    if [ -z "$v" ]; then
      fail "$rel [$a]: no LC_BUILD_VERSION/LC_VERSION_MIN_MACOSX found"
    elif ! minos_ok "$v"; then
      fail "$rel [$a]: requires macOS $v (> 11.0)"
    fi
  done

  # 3. linkage. Real dependency lines are tab-indented; header lines (one per
  # architecture slice in a fat binary!) start at column 0 and must be
  # ignored. Also skip the dylib's own ID line.
  # NOTE: no case/esac here - bash 3.2 cannot parse case inside $( ).
  selfid="$(otool -D "$f" 2>/dev/null | sed -n 2p)"
  baddeps="$(otool -L "$f" 2>/dev/null | \
    awk -v self="$selfid" '/^\t/ {
      d=$1
      if (d == "" || d == self) next
      if (d ~ /^@rpath\// || d ~ /^@executable_path\// || d ~ /^@loader_path\//) next
      if (d ~ /^\/usr\/lib\// || d ~ /^\/System\//) next
      print d
    }' | sort -u)"
  if [ -n "$baddeps" ]; then
    echo "$baddeps" | while IFS= read -r d; do
      fail "$rel: external dependency $d"
    done
  fi

  # 4. leftover absolute rpaths + dyld format check
  loadcmds="$(otool -l "$f" 2>/dev/null)"
  badrp="$(echo "$loadcmds" | \
    awk '/cmd LC_RPATH/{p=1;next} p && /path /{print $2; p=0}' | grep '^/' || true)"
  if [ -n "$badrp" ]; then
    echo "$badrp" | while IFS= read -r rp; do
      fail "$rel: absolute rpath $rp"
    done
  fi
  # chained fixups are a newer dyld format that macOS 11 cannot load;
  # a correct build targeting 11.0 must use classic dyld info
  if echo "$loadcmds" | grep -q 'LC_DYLD_CHAINED_FIXUPS'; then
    fail "$rel: uses LC_DYLD_CHAINED_FIXUPS (not loadable on macOS 11)"
  fi

  # 5. collect weak imports from system libraries for the availability audit
  nm -m "$f" 2>/dev/null | \
    awk '/undefined/ && /weak/ && (/from libSystem/ || /from \/usr\/lib/ || /from \/System/) {
      for (i=1;i<=NF;i++) if ($i ~ /^_/) { print $i; break }
    }' >> "$FAILLOG.weak" || true
done < "$MACHOS"

# weak system imports resolve to NULL at runtime on macOS 11 if the API is
# newer than 11.0 - the min-OS load check cannot catch that, only this audit.
if [ -s "$FAILLOG.weak" ]; then
  echo "-- weak system-library imports (each must be an API that exists on 11.0,"
  echo "   or be behind a runtime availability check):"
  sort -u "$FAILLOG.weak" | sed 's/^/     /'
else
  echo "-- no weak system-library imports (nothing can resolve to NULL on 11.0)"
fi
rm -f "$FAILLOG.weak"
echo "-- scanned $(wc -l < "$MACHOS" | tr -d ' ') Mach-O files"
rm -f "$MACHOS"

# 5. plugin inventory / ODS
GNM_VER="$(ls "$APP/Contents/Resources/lib/gnumeric" 2>/dev/null | head -1)"
PLUGDIR="$APP/Contents/Resources/lib/gnumeric/$GNM_VER/plugins"
if [ -d "$PLUGDIR/openoffice" ]; then
  echo "OK: ODS plugin (openoffice) present"
else
  fail "ODS plugin missing at $PLUGDIR/openoffice"
fi
echo "-- $(ls "$PLUGDIR" 2>/dev/null | wc -l | tr -d ' ') gnumeric plugins installed"

# 6. smoke test, PER ARCHITECTURE (needs a Mac that can execute the slices).
# The payload is deliberately large so content.xml spans many decompression
# chunks - small files can hide arch-specific stream-corruption bugs.
SS="$APP/Contents/MacOS/ssconvert"
if [ -x "$SS" ]; then
  TMP="$(mktemp -d)"
  {
    echo "a,b,c"
    i=1
    while [ "$i" -le 2000 ]; do
      echo "$i,$((i*2)),=A$((i+1))+B$((i+1))"
      i=$((i+1))
    done
  } > "$TMP/t.csv"
  RTFAIL=0
  for a in arm64 x86_64; do
    if ! arch -"$a" "$SS" --version >/dev/null 2>&1; then
      echo "note: $a slice not executable on this Mac (Rosetta missing?); roundtrip skipped"
      continue
    fi
    if arch -"$a" "$SS" "$TMP/t.csv" "$TMP/t-$a.ods" 2>/dev/null && \
       arch -"$a" "$SS" "$TMP/t-$a.ods" "$TMP/back-$a.csv" 2>/dev/null && \
       grep -q '^2000,4000,6000' "$TMP/back-$a.csv"; then
      echo "OK: [$a] 2000-row csv -> ods -> csv roundtrip works"
    else
      fail "[$a] ssconvert ODS roundtrip failed (artifacts in $TMP)"
      RTFAIL=1
    fi
  done
  [ "$RTFAIL" -eq 0 ] && rm -rf "$TMP"
else
  echo "note: ssconvert wrapper missing; smoke test skipped"
fi

echo ""
NFAIL="$(wc -l < "$FAILLOG" | tr -d ' ')"
if [ "$NFAIL" -eq 0 ]; then
  echo "== VERIFY PASSED: universal, macOS 11.0-safe, fully self-contained =="
  exit 0
else
  echo "== VERIFY FAILED: $NFAIL problem(s) found =="
  exit 1
fi
