#!/usr/bin/env bash
#
# verify-bundle.sh -- audit a built wine.app against every requirement.
#
#   ./verify-bundle.sh [path/to/wine.app] [--no-run] [--verbose]
#
# Standalone: it has no dependencies on the build scripts and can be pointed at
# any wine.app, including one that has been moved, zipped and unzipped.
#
# Exit status is 0 only if every hard check passes.
#
set -uo pipefail

APP=""
RUN_TESTS=1
VERBOSE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-run)  RUN_TESTS=0; shift ;;
    --verbose) VERBOSE=1; shift ;;
    -h|--help)
      echo "usage: verify-bundle.sh [path/to/wine.app] [--no-run] [--verbose]"; exit 0 ;;
    --*) echo "unknown option: $1" >&2; exit 2 ;;
    *)   APP="$1"; shift ;;
  esac
done
[[ -n "$APP" ]] || APP="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/dist/wine.app"
APP="${APP%/}"

MIN_OS="${DEPLOYMENT_TARGET:-11.0}"
WANT_WINE_VERSION="${WINE_VERSION:-11.0}"
WANT_GECKO="${GECKO_VERSION:-2.47.4}"
WANT_MONO="${MONO_VERSION:-10.4.1}"

# Published by Wine itself in dlls/appwiz.cpl/addons.c for wine-11.0.
GECKO_X86_SHA="26cecc47706b091908f7f814bddb074c61beb8063318e9efc5a7f789857793d6"
GECKO_X64_SHA="e590b7d988a32d6aa4cf1d8aa3aa3d33766fdd4cf4c89c2dcc2095ecb28d066f"
MONO_SHA="071f4b2887e1c97a11d791ff3d65be9429eed6dec4c2708888bfd546ba358e23"

if [[ -t 1 ]]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[1m'; C=$'\033[36m'; Z=$'\033[0m'
else R=""; G=""; Y=""; B=""; C=""; Z=""; fi

FAILURES=0; WARNINGS=0; CHECKS=0
sect() { printf '\n%s\n' "${B}${C}-- $* ${Z}"; }
pass() { CHECKS=$((CHECKS+1)); printf '  %sPASS%s  %s\n' "$G" "$Z" "$*"; }
fail() { CHECKS=$((CHECKS+1)); FAILURES=$((FAILURES+1)); printf '  %sFAIL%s  %s\n' "$R" "$Z" "$*"; }
warn() { WARNINGS=$((WARNINGS+1)); printf '  %swarn%s  %s\n' "$Y" "$Z" "$*"; }
info() { [[ $VERBOSE -eq 1 ]] && printf '        %s\n' "$*"; return 0; }

WINE_ROOT="$APP/Contents/Resources/wine"
LOADER="$WINE_ROOT/bin/wine"
LIBDIR="$WINE_ROOT/lib"

# ---------------------------------------------------------------- helpers
is_macho() {
  local m; m="$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')"
  case "$m" in cffaedfe|cefaedfe|feedfacf|feedface|cafebabe|bebafeca) return 0 ;; *) return 1 ;; esac
}

# The bundle holds thousands of files and every section below needs the Mach-O
# subset, so scan once and cache it.
MACHO_CACHE=""
macho_list() {
  if [[ -z "$MACHO_CACHE" ]]; then
    MACHO_CACHE="$(mktemp /tmp/wine-macho.XXXXXX)"
    local f
    while IFS= read -r -d '' f; do
      is_macho "$f" && printf '%s\n' "$f"
    done < <(find "$APP" -type f -print0) > "$MACHO_CACHE"
  fi
  cat "$MACHO_CACHE"
}
trap '[[ -n "${MACHO_CACHE:-}" ]] && rm -f "$MACHO_CACHE"' EXIT

ver_le() { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$1" ]]; }

plist_get() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null; }

# =========================================================================
sect "Bundle layout and naming"

if [[ -d "$APP" && "$(basename "$APP")" == "wine.app" ]]; then
  pass "bundle exists and is named wine.app"
else
  fail "expected a directory named wine.app, got: $APP"
  printf '\n%sCannot continue.%s\n' "$R" "$Z"; exit 1
fi

[[ -x "$APP/Contents/MacOS/wine" ]] \
  && pass "Contents/MacOS/wine is present and executable" \
  || fail "Contents/MacOS/wine is missing or not executable"

[[ -x "$LOADER" ]] \
  && pass "real loader present at Contents/Resources/wine/bin/wine" \
  || fail "Contents/Resources/wine/bin/wine is missing"

exe="$(plist_get "$APP/Contents/Info.plist" CFBundleExecutable)"
[[ "$exe" == "wine" ]] \
  && pass "Info.plist CFBundleExecutable = wine" \
  || fail "Info.plist CFBundleExecutable = '${exe:-<unset>}', expected 'wine'"

minsys="$(plist_get "$APP/Contents/Info.plist" LSMinimumSystemVersion)"
[[ "$minsys" == "$MIN_OS" ]] \
  && pass "Info.plist LSMinimumSystemVersion = $MIN_OS" \
  || fail "Info.plist LSMinimumSystemVersion = '${minsys:-<unset>}', expected $MIN_OS"

# =========================================================================
sect "Architectures"

archs="$(lipo -archs "$APP/Contents/MacOS/wine" 2>/dev/null)"
if [[ "$archs" == *arm64* && "$archs" == *x86_64* ]]; then
  pass "launcher is universal ($archs)"
else
  fail "launcher is not universal (got: ${archs:-none})"
fi

archs="$(lipo -archs "$LOADER" 2>/dev/null)"
[[ "$archs" == *x86_64* ]] \
  && pass "wine loader has an x86_64 slice ($archs)" \
  || fail "wine loader has no x86_64 slice (got: ${archs:-none})"

n="$(find "$WINE_ROOT/lib/wine/x86_64-unix" -name '*.so' 2>/dev/null | wc -l | tr -d ' ')"
[[ "$n" -gt 20 ]] \
  && pass "$n unix modules in lib/wine/x86_64-unix" \
  || fail "only $n modules in lib/wine/x86_64-unix"

for pe in i386-windows x86_64-windows; do
  n="$(find "$WINE_ROOT/lib/wine/$pe" -name '*.dll' 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$n" -gt 100 ]]; then
    pass "$n PE modules in lib/wine/$pe"
  else
    fail "only $n PE modules in lib/wine/$pe (32/64-bit Windows support needs both)"
  fi
done

# A PE file must start with MZ; if these were Mach-O the WoW64 build went wrong.
probe="$WINE_ROOT/lib/wine/i386-windows/kernel32.dll"
if [[ -f "$probe" ]] && [[ "$(head -c2 "$probe")" == "MZ" ]]; then
  pass "i386 builtins are real PE images"
else
  fail "lib/wine/i386-windows/kernel32.dll is missing or not a PE image"
fi

# =========================================================================
sect "Minimum macOS version (target: $MIN_OS)"

bad_minos=(); no_minos=()
while IFS= read -r f; do
  found=0
  while read -r v; do
    [[ -z "$v" ]] && continue
    found=1
    ver_le "$v" "$MIN_OS" || bad_minos+=("$(basename "$f")  minos=$v")
  done < <(/usr/bin/otool -l "$f" 2>/dev/null | awk '
      /^ *cmd LC_BUILD_VERSION/       { bv=1; next }
      /^ *cmd LC_VERSION_MIN_MACOSX/  { vm=1; next }
      bv && /^ *minos/   { print $2; bv=0 }
      vm && /^ *version/ { print $2; vm=0 }')
  [[ $found -eq 0 ]] && no_minos+=("$(basename "$f")")
done < <(macho_list)

total="$(macho_list | wc -l | tr -d ' ')"
if [[ ${#bad_minos[@]} -eq 0 ]]; then
  pass "all $total Mach-O files target macOS $MIN_OS or older"
else
  fail "${#bad_minos[@]} of $total Mach-O files require a newer macOS than $MIN_OS:"
  printf '        %s\n' "${bad_minos[@]}" | head -25
  [[ ${#bad_minos[@]} -gt 25 ]] && printf '        ... and %d more\n' $(( ${#bad_minos[@]} - 25 ))
fi
if [[ ${#no_minos[@]} -gt 0 ]]; then
  warn "${#no_minos[@]} file(s) carry no macOS version load command"
  printf '        %s\n' "${no_minos[@]}" | head -10
fi

# =========================================================================
sect "Self-containment"

# Index every filename in the bundle once, so the @rpath closure check below is
# a lookup rather than a find(1) per dependency per binary.
#
# A space-delimited string rather than an associative array: macOS ships bash
# 3.2, which has no `declare -A`, and this project deliberately does not depend
# on a package manager to supply a newer one.
BUNDLE_FILES=" $(find "$APP" \( -type f -o -type l \) | sed 's|.*/||' | sort -u | tr '\n' ' ') "

leaks=(); rpath_abs=(); unresolved=()
while IFS= read -r f; do
  while read -r dep; do
    case "$dep" in
      /usr/lib/*|/System/Library/*) ;;
      @rpath/*|@loader_path/*|@executable_path/*)
        base="${dep##*/}"
        case "$BUNDLE_FILES" in
          *" $base "*) ;;
          *) unresolved+=("${f##*/} -> $dep") ;;
        esac
        ;;
      "") ;;
      *) leaks+=("$(basename "$f") -> $dep") ;;
    esac
    # Only tab-indented lines are dependencies.  On a universal binary otool -L
    # emits an unindented "<path> (architecture x86_64):" header per slice, and
    # skipping just the first line makes every fat file look like it depends on
    # itself.
  done < <(/usr/bin/otool -L "$f" 2>/dev/null | awk '/^\t/{print $1}')

  while read -r rp; do
    case "$rp" in
      @loader_path*|@executable_path*) ;;
      "") ;;
      *) rpath_abs+=("$(basename "$f") rpath=$rp") ;;
    esac
  done < <(/usr/bin/otool -l "$f" 2>/dev/null | awk '/LC_RPATH/{r=1} r&&/path /{print $2; r=0}')
done < <(macho_list)

if [[ ${#leaks[@]} -eq 0 ]]; then
  pass "no binary links against anything outside the bundle or /usr/lib//System"
else
  fail "${#leaks[@]} external library reference(s):"
  printf '        %s\n' "${leaks[@]}" | head -25
fi

if [[ ${#unresolved[@]} -eq 0 ]]; then
  pass "every @rpath dependency is present inside the bundle"
else
  fail "${#unresolved[@]} unresolved @rpath dependenc(ies):"
  printf '        %s\n' "${unresolved[@]}" | head -25
fi

if [[ ${#rpath_abs[@]} -eq 0 ]]; then
  pass "all LC_RPATH entries are @loader_path/@executable_path relative"
else
  fail "${#rpath_abs[@]} absolute LC_RPATH entr(ies) -- the bundle is not relocatable:"
  printf '        %s\n' "${rpath_abs[@]}" | head -25
fi

# =========================================================================
sect "Package manager isolation"

pm_hits=0
while IFS= read -r f; do
  if LC_ALL=C grep -al -e '/opt/homebrew' -e '/opt/local/lib' -e '/usr/local/Cellar' "$f" >/dev/null 2>&1; then
    pm_hits=$((pm_hits+1))
    info "$(basename "$f") contains a package-manager path string"
  fi
done < <(macho_list)

[[ $pm_hits -eq 0 ]] \
  && pass "no Homebrew or MacPorts paths embedded in any binary" \
  || fail "$pm_hits binar(ies) contain Homebrew/MacPorts paths (re-run with --verbose to list)"

# =========================================================================
sect "Code signing"

if codesign --verify --deep --strict "$APP" 2>/dev/null; then
  pass "bundle signature verifies (--deep --strict)"
else
  fail "codesign --verify --deep --strict failed"
  codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/        /' | head -15
fi

unsigned=0
while IFS= read -r f; do
  codesign -v "$f" >/dev/null 2>&1 || { unsigned=$((unsigned+1)); info "unsigned: $f"; }
done < <(macho_list)
[[ $unsigned -eq 0 ]] \
  && pass "every Mach-O carries a valid signature" \
  || fail "$unsigned Mach-O file(s) are unsigned or have a broken signature"

for target in "$APP/Contents/MacOS/wine" "$LOADER"; do
  ents="$(codesign -d --entitlements - --xml "$target" 2>/dev/null)"
  if grep -q 'com.apple.security.cs.allow-jit' <<<"$ents"; then
    pass "$(basename "$(dirname "$target")")/$(basename "$target") has the JIT entitlement"
  else
    fail "$target is missing com.apple.security.cs.allow-jit (W^X will break Wine on Apple Silicon)"
  fi
done

if xattr -rl "$APP" 2>/dev/null | grep -q 'com.apple.quarantine'; then
  warn "quarantine attributes present -- run: xattr -cr '$APP'"
else
  pass "no quarantine attributes"
fi

# =========================================================================
sect "Bundled features"

check_file() {
  if compgen -G "$1" >/dev/null; then pass "$2"; else fail "$2 -- not found ($1)"; fi
}
check_file "$LIBDIR/libfreetype*.dylib"  "FreeType bundled"
check_file "$LIBDIR/libgnutls*.dylib"    "GnuTLS bundled (schannel/TLS)"
check_file "$LIBDIR/libSDL2*.dylib"      "SDL2 bundled (gamepads)"
check_file "$LIBDIR/libMoltenVK.dylib"   "MoltenVK bundled (Vulkan)"
check_file "$LIBDIR/libavcodec*.dylib"   "FFmpeg bundled (winedmo)"
check_file "$LIBDIR/libgstreamer-1.0*.dylib" "GStreamer bundled"

n="$(find "$LIBDIR/gstreamer-1.0" -name '*.dylib' 2>/dev/null | wc -l | tr -d ' ')"
[[ "$n" -ge 10 ]] \
  && pass "$n GStreamer plugins bundled" \
  || fail "only $n GStreamer plugins bundled"

[[ -x "$WINE_ROOT/libexec/gstreamer-1.0/gst-plugin-scanner" ]] \
  && pass "gst-plugin-scanner bundled" \
  || warn "gst-plugin-scanner missing; GStreamer will scan in-process"

for m in winegstreamer winedmo winevulkan wined3d dxgi mscoree mshtml; do
  if compgen -G "$WINE_ROOT/lib/wine/x86_64-windows/${m}.dll" >/dev/null; then
    pass "module ${m}.dll present"
  else
    fail "module ${m}.dll is missing"
  fi
done

# ------------------------------------------------------------ gecko / mono
verify_sha() {
  local f="$1" want="$2" label="$3" got
  if [[ ! -f "$f" ]]; then fail "$label is not bundled ($f)"; return; fi
  got="$(shasum -a 256 "$f" | awk '{print $1}')"
  if [[ "$got" == "$want" ]]; then
    pass "$label bundled with the checksum Wine expects"
  else
    fail "$label checksum mismatch (got $got)"
  fi
}
verify_sha "$WINE_ROOT/share/wine/gecko/wine-gecko-${WANT_GECKO}-x86.msi"    "$GECKO_X86_SHA" "wine-gecko $WANT_GECKO x86"
verify_sha "$WINE_ROOT/share/wine/gecko/wine-gecko-${WANT_GECKO}-x86_64.msi" "$GECKO_X64_SHA" "wine-gecko $WANT_GECKO x86_64"
verify_sha "$WINE_ROOT/share/wine/mono/wine-mono-${WANT_MONO}-x86.msi"       "$MONO_SHA"      "wine-mono $WANT_MONO"

# =========================================================================
sect "Runtime tests"

if [[ $RUN_TESTS -eq 0 ]]; then
  warn "skipped (--no-run)"
elif [[ "$(uname -m)" == "arm64" ]] && ! arch -x86_64 /usr/bin/true >/dev/null 2>&1; then
  warn "Rosetta 2 is not installed; skipping runtime tests"
  warn "install with: softwareupdate --install-rosetta --agree-to-license"
  RUN_TESTS=0
elif [[ "$(uname -m)" == "arm64" ]]; then
  pass "Rosetta 2 is available on this machine"
fi

if [[ $RUN_TESTS -eq 1 ]]; then
  # Portability: exercise the bundle from a different directory.  cp -Rc uses
  # APFS clonefile, so this costs almost nothing in time or disk.
  PORT_DIR="$(mktemp -d /tmp/wine-verify.XXXXXX)"
  if cp -Rc "$APP" "$PORT_DIR/" 2>/dev/null || cp -R "$APP" "$PORT_DIR/" 2>/dev/null; then
    RUN_APP="$PORT_DIR/wine.app"
    pass "bundle copied to $PORT_DIR for a relocation test"
  else
    RUN_APP="$APP"
    warn "could not clone the bundle; testing in place"
  fi
  WINE="$RUN_APP/Contents/MacOS/wine"

  export WINEPREFIX; WINEPREFIX="$(mktemp -d /tmp/wine-prefix.XXXXXX)/pfx"
  export WINEDEBUG=-all
  export DISPLAY=

  out="$("$WINE" --version 2>&1 | tr -d '\r')"
  if [[ "$out" == "wine-${WANT_WINE_VERSION}"* ]]; then
    pass "wine --version reports $out (from a relocated copy)"
  else
    fail "wine --version reported '${out}', expected wine-${WANT_WINE_VERSION}"
  fi

  printf '        creating a fresh prefix (installs gecko and mono, may take a minute)...\n'
  if "$WINE" wineboot -u >"$PORT_DIR/wineboot.log" 2>&1; then
    pass "wineboot created a prefix without network access"
  else
    fail "wineboot failed -- see $PORT_DIR/wineboot.log"
    tail -20 "$PORT_DIR/wineboot.log" | sed 's/^/        /'
  fi

  # Both worlds: system32 is 64-bit, syswow64 is 32-bit.
  out="$("$WINE" cmd /c ver 2>/dev/null | tr -d '\r')"
  [[ "$out" == *Windows* ]] \
    && pass "64-bit PE execution works (cmd.exe: ${out//$'\n'/ })" \
    || fail "64-bit cmd.exe did not run (got: ${out:-<nothing>})"

  out="$("$WINE" "C:\\windows\\syswow64\\cmd.exe" /c ver 2>/dev/null | tr -d '\r')"
  [[ "$out" == *Windows* ]] \
    && pass "32-bit PE execution works via WoW64 (syswow64 cmd.exe)" \
    || fail "32-bit cmd.exe did not run (got: ${out:-<nothing>})"

  # Search the whole windows tree rather than guessing between system32 and
  # syswow64: which one gets used depends on the prefix's bitness.
  gecko_dir() {
    find "$WINEPREFIX/drive_c/windows" -maxdepth 5 -type d -name wine_gecko 2>/dev/null | head -1
  }

  if [[ -n "$(gecko_dir)" ]]; then
    pass "wine-gecko installed into the new prefix by wineboot"
  else
    # Wine does not always install Gecko at prefix creation -- it can defer
    # until something first loads mshtml.  That is an upstream scheduling
    # decision and says nothing about whether the bundle is self-sufficient.
    # What actually matters here is that the staged MSI installs with no
    # network, so test that directly.
    msi="$RUN_APP/Contents/Resources/wine/share/wine/gecko/wine-gecko-${WANT_GECKO}-x86_64.msi"
    msi_win="$("$WINE" winepath -w "$msi" 2>/dev/null | tr -d '\r')"
    if [[ -n "$msi_win" ]] \
       && "$WINE" msiexec /i "$msi_win" /q >"$PORT_DIR/gecko.log" 2>&1 \
       && [[ -n "$(gecko_dir)" ]]; then
      pass "wine-gecko installs offline from the bundled MSI (wineboot deferred it)"
    else
      fail "wine-gecko could not be installed from the bundled MSI"
      [[ -f "$PORT_DIR/gecko.log" ]] && tail -12 "$PORT_DIR/gecko.log" | sed 's/^/        /'
      printf '        prefix gecko dirs: %s\n' \
        "$(find "$WINEPREFIX/drive_c/windows" -maxdepth 3 -iname 'gecko*' 2>/dev/null | tr '\n' ' ')"
    fi
  fi

  if compgen -G "$WINEPREFIX/drive_c/windows/mono/mono-2.0/*" >/dev/null; then
    pass "wine-mono installed into the new prefix offline"
  else
    fail "wine-mono was not installed into the prefix"
  fi

  "$WINE" wineserver -k >/dev/null 2>&1 || true
  sleep 1
  rm -rf "$(dirname "$WINEPREFIX")" "$PORT_DIR"
fi

# =========================================================================
printf '\n%s\n' "${B}Summary${Z}"
printf '  checks run : %d\n' "$CHECKS"
printf '  warnings   : %d\n' "$WARNINGS"
if [[ $FAILURES -eq 0 ]]; then
  printf '  %sfailures   : 0 -- bundle meets every requirement%s\n\n' "$G" "$Z"
  exit 0
else
  printf '  %sfailures   : %d%s\n\n' "$R" "$FAILURES" "$Z"
  exit 1
fi
