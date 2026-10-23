#!/usr/bin/env bash
#
# verify-bundle.sh -- audit a built dosbox-daum.app against every requirement.
#
#   ./verify-bundle.sh [path/to/dosbox-daum.app] [--no-run] [--verbose]
#
# Standalone; can be pointed at any dosbox-daum.app, including one that has been
# zipped, moved and unzipped elsewhere.
#
set -uo pipefail

APP=""
RUN_TESTS=1
VERBOSE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-run)  RUN_TESTS=0; shift ;;
    --verbose) VERBOSE=1; shift ;;
    -h|--help) echo "usage: verify-bundle.sh [path/to/dosbox-daum.app] [--no-run] [--verbose]"; exit 0 ;;
    --*) echo "unknown option: $1" >&2; exit 2 ;;
    *)   APP="$1"; shift ;;
  esac
done
[[ -n "$APP" ]] || APP="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/dist/dosbox-daum.app"
APP="${APP%/}"

MIN_OS="${DEPLOYMENT_TARGET:-11.0}"

if [[ -t 1 ]]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[1m'; C=$'\033[36m'; Z=$'\033[0m'
else R=""; G=""; Y=""; B=""; C=""; Z=""; fi

FAILURES=0; WARNINGS=0; CHECKS=0
sect() { printf '\n%s\n' "${B}${C}-- $* ${Z}"; }
pass() { CHECKS=$((CHECKS+1)); printf '  %sPASS%s  %s\n' "$G" "$Z" "$*"; }
fail() { CHECKS=$((CHECKS+1)); FAILURES=$((FAILURES+1)); printf '  %sFAIL%s  %s\n' "$R" "$Z" "$*"; }
warn() { WARNINGS=$((WARNINGS+1)); printf '  %swarn%s  %s\n' "$Y" "$Z" "$*"; }
info() { [[ $VERBOSE -eq 1 ]] && printf '        %s\n' "$*"; return 0; }

ROOT="$APP/Contents/Resources/daum"
DOSBOX="$ROOT/bin/dosbox"
LIBDIR="$ROOT/lib"

is_macho() {
  local m; m="$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')"
  case "$m" in cffaedfe|cefaedfe|feedfacf|feedface|cafebabe|bebafeca) return 0 ;; *) return 1 ;; esac
}

MACHO_CACHE=""
macho_list() {
  if [[ -z "$MACHO_CACHE" ]]; then
    MACHO_CACHE="$(mktemp /tmp/daum-macho.XXXXXX)"
    local f
    while IFS= read -r -d '' f; do is_macho "$f" && printf '%s\n' "$f"; done \
      < <(find "$APP" -type f -print0) > "$MACHO_CACHE"
  fi
  cat "$MACHO_CACHE"
}
trap '[[ -n "${MACHO_CACHE:-}" ]] && rm -f "$MACHO_CACHE"; rm -f "${RUN_TIMEOUT_FLAG:-}" "${RUN_TRUNC_FLAG:-}" "${RUN_UNANSWERED_FLAG:-}"' EXIT

ver_le() { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$1" ]]; }
plist_get() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null; }

# =========================================================================
sect "Bundle layout and naming"

if [[ -d "$APP" && "$(basename "$APP")" == "dosbox-daum.app" ]]; then
  pass "bundle exists and is named dosbox-daum.app"
else
  fail "expected a directory named dosbox-daum.app, got: $APP"
  printf '\n%sCannot continue.%s\n' "$R" "$Z"; exit 1
fi

[[ -x "$APP/Contents/MacOS/dosbox-daum" ]] \
  && pass "Contents/MacOS/dosbox-daum is present and executable" \
  || fail "Contents/MacOS/dosbox-daum is missing or not executable"

[[ -x "$DOSBOX" ]] \
  && pass "real binary present at Contents/Resources/daum/bin/dosbox" \
  || fail "Contents/Resources/daum/bin/dosbox is missing"

exe="$(plist_get "$APP/Contents/Info.plist" CFBundleExecutable)"
[[ "$exe" == "dosbox-daum" ]] \
  && pass "Info.plist CFBundleExecutable = dosbox-daum" \
  || fail "Info.plist CFBundleExecutable = '${exe:-<unset>}'"

minsys="$(plist_get "$APP/Contents/Info.plist" LSMinimumSystemVersion)"
[[ "$minsys" == "$MIN_OS" ]] \
  && pass "Info.plist LSMinimumSystemVersion = $MIN_OS" \
  || fail "Info.plist LSMinimumSystemVersion = '${minsys:-<unset>}'"

# =========================================================================
sect "Architectures"

for t in "$APP/Contents/MacOS/dosbox-daum" "$DOSBOX"; do
  archs="$(lipo -archs "$t" 2>/dev/null)"
  if [[ "$archs" == *arm64* && "$archs" == *x86_64* ]]; then
    pass "$(basename "$t") is universal ($archs)"
  else
    fail "$(basename "$t") is not universal (got: ${archs:-none})"
  fi
done

thin=0
while IFS= read -r f; do
  case "$f" in *.dylib) ;; *) continue ;; esac
  a="$(lipo -archs "$f" 2>/dev/null)"
  [[ "$a" == *arm64* && "$a" == *x86_64* ]] || { thin=$((thin+1)); info "thin: $f ($a)"; }
done < <(macho_list)
[[ $thin -eq 0 ]] \
  && pass "every bundled dylib is universal" \
  || fail "$thin bundled dylib(s) are not universal (--verbose to list)"

# =========================================================================
sect "Minimum macOS version (target: $MIN_OS)"

bad=()
while IFS= read -r f; do
  while read -r v; do
    [[ -z "$v" ]] && continue
    ver_le "$v" "$MIN_OS" || bad+=("$(basename "$f")  minos=$v")
  done < <(/usr/bin/otool -l "$f" 2>/dev/null | awk '
      /^ *cmd LC_BUILD_VERSION/       { bv=1; next }
      /^ *cmd LC_VERSION_MIN_MACOSX/  { vm=1; next }
      bv && /^ *minos/   { print $2; bv=0 }
      vm && /^ *version/ { print $2; vm=0 }')
done < <(macho_list)

total="$(macho_list | wc -l | tr -d ' ')"
if [[ ${#bad[@]} -eq 0 ]]; then
  pass "all $total Mach-O files target macOS $MIN_OS or older"
else
  fail "${#bad[@]} of $total Mach-O files require a newer macOS than $MIN_OS:"
  printf '        %s\n' "${bad[@]}" | head -25
fi

# =========================================================================
sect "Self-containment"

BUNDLE_FILES=" $(find "$APP" \( -type f -o -type l \) | sed 's|.*/||' | sort -u | tr '\n' ' ') "
leaks=(); rpath_abs=(); unresolved=()
while IFS= read -r f; do
  while read -r dep; do
    case "$dep" in
      /usr/lib/*|/System/Library/*) ;;
      @rpath/*|@loader_path/*|@executable_path/*)
        base="${dep##*/}"
        case "$BUNDLE_FILES" in *" $base "*) ;; *) unresolved+=("${f##*/} -> $dep") ;; esac ;;
      "") ;;
      *) leaks+=("${f##*/} -> $dep") ;;
    esac
  done < <(/usr/bin/otool -L "$f" 2>/dev/null | awk '/^\t/{print $1}')

  while read -r rp; do
    case "$rp" in
      @loader_path*|@executable_path*|"") ;;
      *) rpath_abs+=("${f##*/} rpath=$rp") ;;
    esac
  done < <(/usr/bin/otool -l "$f" 2>/dev/null | awk '/LC_RPATH/{r=1} r&&/^ *path /{print $2; r=0}')
done < <(macho_list)

[[ ${#leaks[@]} -eq 0 ]] \
  && pass "no binary links outside the bundle or /usr/lib//System" \
  || { fail "${#leaks[@]} external library reference(s):"; printf '        %s\n' "${leaks[@]}" | head -20; }

[[ ${#unresolved[@]} -eq 0 ]] \
  && pass "every @rpath dependency is present inside the bundle" \
  || { fail "${#unresolved[@]} unresolved @rpath dependenc(ies):"; printf '        %s\n' "${unresolved[@]}" | head -20; }

[[ ${#rpath_abs[@]} -eq 0 ]] \
  && pass "all LC_RPATH entries are @loader_path/@executable_path relative" \
  || { fail "${#rpath_abs[@]} absolute LC_RPATH entr(ies):"; printf '        %s\n' "${rpath_abs[@]}" | head -20; }

pm=0
while IFS= read -r f; do
  # /usr/local/opt was the gap: Intel Homebrew's canonical linkage path is
  # /usr/local/opt/<pkg>/lib/..., not /usr/local/Cellar, and this bundle ships
  # an x86_64 slice that would have been built against exactly that.  MacPorts
  # is matched on the bare prefix rather than /opt/local/lib for the same
  # reason -- headers, share/ and bin/ paths get embedded too.
  LC_ALL=C grep -al -e '/opt/homebrew' -e '/opt/local/' \
                    -e '/usr/local/Cellar' -e '/usr/local/opt/' "$f" >/dev/null 2>&1 \
    && { pm=$((pm+1)); info "package-manager path in $f"; }
done < <(macho_list)
[[ $pm -eq 0 ]] \
  && pass "no Homebrew or MacPorts paths embedded in any binary" \
  || fail "$pm binar(ies) contain Homebrew/MacPorts paths"

# =========================================================================
sect "Code signing"

codesign --verify --deep --strict "$APP" 2>/dev/null \
  && pass "bundle signature verifies (--deep --strict)" \
  || fail "codesign --verify --deep --strict failed"

unsigned=0
while IFS= read -r f; do
  codesign -v "$f" >/dev/null 2>&1 || { unsigned=$((unsigned+1)); info "unsigned: $f"; }
done < <(macho_list)
[[ $unsigned -eq 0 ]] \
  && pass "every Mach-O carries a valid signature" \
  || fail "$unsigned Mach-O file(s) are unsigned or broken"

# The JIT entitlements have to be on the binary that actually allocates the
# code cache -- entitlements do not survive exec().
for t in "$APP/Contents/MacOS/dosbox-daum" "$DOSBOX"; do
  ents="$(codesign -d --entitlements - --xml "$t" 2>/dev/null)"
  if grep -q 'allow-unsigned-executable-memory' <<<"$ents"; then
    pass "$(basename "$t") has the executable-memory entitlement"
  else
    fail "$t lacks allow-unsigned-executable-memory -- the dynamic core will not get an RWX cache"
  fi
done

# =========================================================================
sect "Bundled features"

check_file() { compgen -G "$1" >/dev/null && pass "$2" || fail "$2 -- not found ($1)"; }

# No DOSBox invocation may be able to hang the verifier.  These open real GUI
# windows and GL contexts; a context that never comes up (Rosetta is a good way
# to find one) stalls the script forever with no output and no diagnosis.
# macOS ships no timeout(1), so: watchdog in bash.
#
# On normal completion nothing is killed and the output is complete -- output is
# only ever lost in the timeout case, where there was nothing useful to lose.
# The launcher execv()s the real binary and `arch` execs its target, so in both
# cases $! stays the PID that actually needs killing.
# The timeout flag is passed through a FILE, not a variable.  run_limited is
# almost always called as out="$(run_limited ...)", and a command substitution
# is a subshell -- any variable it sets is discarded when it exits, so a
# variable-based flag reads as "no timeout" every single time.  Tested, not
# assumed: the first version of this did exactly that.
RUN_TIMEOUT_FLAG="${TMPDIR:-/tmp}/daum-verify-timeout.$$"
RUN_MAX_BYTES=2000000
# Same lesson as the timeout flag: run_limited runs inside $( ), so a variable
# it sets is discarded.  Both signals travel by file.
RUN_TRUNC_FLAG="${TMPDIR:-/tmp}/daum-verify-trunc.$$"
run_truncated()   { [[ -s "$RUN_TRUNC_FLAG" ]]; }
run_trunc_bytes() { cat "$RUN_TRUNC_FLAG" 2>/dev/null || echo 0; }
run_timed_out() { [[ -f "$RUN_TIMEOUT_FLAG" ]]; }
# run_until's flag is a DIFFERENT statement, so it gets a different name.
# "Timed out" would be wrong for the case where the process exits by itself
# without ever answering -- which for DOSBox means it died, not that it was
# slow.  What both share is that the question went unanswered.
RUN_UNANSWERED_FLAG="${TMPDIR:-/tmp}/daum-verify-unanswered.$$"
run_unanswered() { [[ -f "$RUN_UNANSWERED_FLAG" ]]; }

# Bound what a run hands back.  A run that loops and logs can produce gigabytes,
# and out="$(run_... )" slurps the lot into memory -- bash then dies with
#   xrealloc: cannot allocate 18446744071562067968 bytes
# and takes the whole verifier with it, after the checks have passed.
#
# Keep BOTH ends.  Keeping only the head hid the cause completely once: startup
# chatter filled the window, the repeating line never appeared, and the
# frequency histogram topped out at 21 and told us nothing.  The "bytes elided"
# marker is load-bearing -- the raw-sample diagnostic greps for it to find the
# looping region.
emit_capped() {
  local f="$1" size
  size="$(wc -c <"$f" | tr -d ' ')"
  if (( size > RUN_MAX_BYTES )); then
    printf '%s' "$size" > "$RUN_TRUNC_FLAG"
    head -c $(( RUN_MAX_BYTES / 2 )) "$f"
    printf '\n...[%s bytes elided]...\n' "$(( size - RUN_MAX_BYTES ))"
    tail -c $(( RUN_MAX_BYTES / 2 )) "$f"
  else
    cat "$f"
  fi
}

# Run something that is NOT expected to exit, and stop it as soon as a file it
# writes answers the question.
#
# run_limited is the wrong shape for this.  It assumes the process ends on its
# own and treats a kill as a warning -- correct for `-c exit` runs, wrong for
# the openglhq probe, where being killed is the normal ending.  That probe used
# to end with `-c exit` purely so stdio would flush, and that raced the thing
# being measured: GFX_SetSize runs from a PIC event, so quitting early means the
# mode set never happens and the check sees nothing.  Now the evidence is a file
# that is flushed line by line (see OpenGLHQ_ProbeLog), so the run can simply be
# killed -- and polling means the usual case costs a second or two rather than
# the whole grace period.
run_until() {
  local secs="$1" watch="$2" want="$3"; shift 3
  local tmp pid waited=0
  tmp="$(mktemp "${TMPDIR:-/tmp}/daum-run.XXXXXX")"
  rm -f "$RUN_UNANSWERED_FLAG" "$RUN_TRUNC_FLAG"
  "$@" >"$tmp" 2>&1 &
  pid=$!
  while (( waited < secs )); do
    grep -qE "$want" "$watch" 2>/dev/null && break
    kill -0 "$pid" 2>/dev/null || break     # it exited by itself; stop waiting
    sleep 1; waited=$((waited+1))
  done
  # Record the flag on "the watched line never appeared", not on the kill --
  # here the kill is the ordinary way this ends, so keying off it would flag
  # every healthy run.
  grep -qE "$want" "$watch" 2>/dev/null || : > "$RUN_UNANSWERED_FLAG"
  pkill -P "$pid" 2>/dev/null || true
  kill -TERM "$pid" 2>/dev/null || true
  sleep 1
  pkill -9 -P "$pid" 2>/dev/null || true
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  emit_capped "$tmp"
  rm -f "$tmp"
}

run_limited() {
  local secs="$1"; shift
  local tmp pid waited=0
  tmp="$(mktemp "${TMPDIR:-/tmp}/daum-run.XXXXXX")"
  rm -f "$RUN_TIMEOUT_FLAG" "$RUN_TRUNC_FLAG"
  "$@" >"$tmp" 2>&1 &
  pid=$!
  while (( waited < secs )) && kill -0 "$pid" 2>/dev/null; do
    sleep 1; waited=$((waited+1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    : > "$RUN_TIMEOUT_FLAG"
    # The launcher execv()s and `arch` execs, so $pid is normally the process
    # that matters -- but reap any direct children too rather than relying on
    # that, or a survivor keeps the GL window up for the rest of the run.
    pkill -P "$pid" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
    sleep 1
    pkill -9 -P "$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
  emit_capped "$tmp"
  rm -f "$tmp"
}
check_file "$LIBDIR/libSDL2*.dylib"     "SDL2 bundled"
check_file "$LIBDIR/libSDL-1.2*.dylib"  "sdl12-compat bundled (SDL 1.2 API)"
check_file "$LIBDIR/libSDL_net*.dylib"  "SDL_net bundled (IPX / modem)"
check_file "$LIBDIR/libpng*.dylib"      "libpng bundled (screenshots)"
check_file "$LIBDIR/libfreetype*.dylib" "FreeType bundled (printer emulation)"
check_file "$LIBDIR/libSDL_sound*.dylib" "SDL_sound bundled (compressed CD-DA)"
check_file "$LIBDIR/libphysfs*.dylib"   "PhysFS bundled (archive-as-drive)"
check_file "$LIBDIR/libfluidsynth*.dylib" "FluidSynth bundled (SoundFont MIDI)"
check_file "$LIBDIR/libavcodec*.dylib"  "FFmpeg bundled (video capture)"

# =========================================================================
sect "Daum-specific features"

# Daum carries hardware emulation no other DOSBox fork reproduces.  Every one of
# these units is compiled unconditionally from src/hardware/Makefile.am, so if a
# unit's strings are missing from the binary something went badly wrong in the
# build -- a silently skipped source file, or the wrong tree.
#
# Look for the SYMBOL each unit defines, not for a string it might emit.
#
# Two rounds of getting this wrong are the reason it is worth spelling out:
#
#   1. Property names ("voodoo", "glide", "ne2000") prove nothing.  They are
#      registered from dosbox.cpp and appear in the built-in dosbox.conf
#      template whether or not the hardware file compiled.  "voodoo" is also a
#      substring of "voodoomem", so the two could never be told apart.
#   2. Log messages prove nothing either.  ne2000.h does `#define BX_INFO` and
#      `#define BX_DEBUG` to nothing, so every one of ne2000.cpp's messages is
#      compiled out -- and the string I first picked, "NE2000 ethernet NIC", was
#      inside a commented-out line to begin with.  It read as "unit missing" on
#      a build where the unit was present and working.
#
# A Section init function is the right evidence: <UNIT>_Init(Section*) exists in
# exactly one translation unit, the config system takes its address, and it
# cannot be optimised away.  If the symbol is in the binary, that file was
# compiled and linked.
#
# The binary is not stripped (the build never asks for it), so the names are
# present.  If that ever changes, this check fails loudly and honestly rather
# than degrading to a guess -- which is the outcome to want.
daum_units="
voodoo|3dfx Voodoo graphics|VOODOO_Init
glide|Glide 2.x pass-through|GLIDE_Init
ne2000|NE2000 ethernet|NE2K_Init
innova|Innovation SSI-2001|INNOVA_Init
ide|IDE controller|IDE_Init
dongle|parallel-port dongle|DONGLE_Init
"
missing_props=""
while IFS='|' read -r unit desc marker; do
  [[ -z "$unit" ]] && continue
  if LC_ALL=C grep -aqF "$marker" "$DOSBOX" 2>/dev/null; then
    info "$unit ($desc) linked -- found $marker"
  else
    missing_props="$missing_props $unit"
  fi
done <<<"$daum_units"
if [[ -z "$missing_props" ]]; then
  pass "all Daum hardware units linked in (voodoo glide ne2000 innova ide dongle)"
else
  fail "Daum hardware unit(s) not linked into the binary:$missing_props
Looked for each unit's <UNIT>_Init(Section*) symbol.  If the binary has been
stripped these will all be absent and the finding is about the strip, not the
build -- check with:  nm '$DOSBOX' | grep _Init"
fi

# Voodoo is the one distinctive feature that IS conditional: it is compiled only
# when C_OPENGL is defined.  configure.ac defines that unconditionally for
# darwin, so a miss here means the darwin branch was not taken.
if LC_ALL=C grep -aq 'voodoo' "$DOSBOX" && otool -L "$DOSBOX" | grep -q 'OpenGL.framework'; then
  pass "3dfx Voodoo emulation compiled in and linked against OpenGL.framework"
else
  fail "Voodoo emulation is missing or OpenGL.framework is not linked (C_OPENGL was not set)"
fi

# =========================================================================
sect "Runtime tests"

if [[ $RUN_TESTS -eq 0 ]]; then
  warn "skipped (--no-run)"
else
  PORT_DIR="$(mktemp -d /tmp/daum-verify.XXXXXX)"
  if cp -Rc "$APP" "$PORT_DIR/" 2>/dev/null || cp -R "$APP" "$PORT_DIR/" 2>/dev/null; then
    RUN_APP="$PORT_DIR/dosbox-daum.app"
    pass "bundle copied to $PORT_DIR for a relocation test"
  else
    RUN_APP="$APP"; warn "could not clone the bundle; testing in place"
  fi
  BIN="$RUN_APP/Contents/MacOS/dosbox-daum"
  export SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy

  # Match the banner sdlmain.cpp actually prints, not the word "dosbox".
  #
  #     printf("\nDOSBox version %s, copyright 2002-2015 DOSBox Team.\n\n",VERSION)
  #
  # `grep -qi dosbox` was the old test and it could not fail: 2>&1 captures
  # stderr, and every dyld error names the binary it could not load --
  #     dyld[…]: Library not loaded: @rpath/libSDL2-2.0.0.dylib
  #       Referenced from: …/Contents/Resources/daum/bin/dosbox
  # -- so a bundle with every dylib missing passed, and printed the loader
  # error as its version string.  Anchor on the banner, and reject loader
  # failures by name so the diagnosis is right when it does break.
  #
  # `[0-9]` after "version" would be wrong: Daum's VERSION is the string
  # "SVN-Daum", so the banner reads "DOSBox version SVN-Daum, copyright ...".
  # Anchoring on a digit made this fail on a perfectly good build -- the same
  # mistake in the other direction, and caught only because the build was
  # actually run.  Match the shape of the banner instead, which a loader error
  # cannot produce.
  out="$("$BIN" -version 2>&1 | head -6)"
  if grep -qE '^DOSBox version [^ ]+, copyright' <<<"$out"; then
    pass "runs from a relocated copy: $(grep -m1 -E '^DOSBox version' <<<"$out")"
  elif grep -qE 'dyld|Library not loaded|image not found|code signature' <<<"$out"; then
    fail "the binary will not load from a relocated copy -- dynamic loader error:"
    printf '        %s\n' "$(grep -m3 -E 'dyld|Library not loaded|Referenced from|Reason' <<<"$out")"
  else
    fail "could not run the binary (got: ${out:-<nothing>})"
  fi

  # The point of the whole exercise: confirm the dynamic recompiler is present
  # and is what actually runs, natively, on this machine's architecture.
  conf="$PORT_DIR/test.conf"
  cat > "$conf" <<'EOF'
[cpu]
core=dynamic
cycles=10000
EOF
  # Observe the result through the filesystem, not stdout.  DOSBox's `echo`
  # writes to the emulated DOS screen, so grepping the host stdout for a marker
  # can never succeed -- it reports failure even on a perfectly good build.
  # Redirecting to a file on a mounted drive proves the shell ran, the guest
  # executed, and the DOS filesystem worked, and leaves evidence we can read.
  dyndir="$PORT_DIR/dyn"; mkdir -p "$dyndir"
  out="$(run_limited 60 "$BIN" -conf "$conf" \
         -c "mount c $dyndir" -c 'echo DYNTEST > c:\dyn.txt' -c exit)"
  if [[ -f "$dyndir/dyn.txt" ]] && grep -q 'DYNTEST' "$dyndir/dyn.txt" 2>/dev/null; then
    pass "core=dynamic runs DOS commands on $(uname -m) (verified via mounted drive)"
  elif run_timed_out; then
    # run_timed_out() existed and was never called, so "hung for the full 60s"
    # and "died in the first second" arrived as the same sentence.  They want
    # different answers: a hang is usually a window or GL context that never
    # comes up, a fast death is a link or entitlement problem.
    fail "core=dynamic did not finish -- killed after the timeout, still running.
That is a hang, not a crash: DOSBox started and never reached -c exit."
    printf '        %s\n' "$(tail -12 <<<"$out")"
  else
    fail "core=dynamic did not run -- DOSBox exited on its own without writing
the marker file."
    printf '        %s\n' "$(tail -12 <<<"$out")"
  fi

  # This is the only check in the suite that can fail when the dynamic
  # recompiler is not what runs, so it is a `fail`, not a `warn`.
  #
  # Why it is sound: cache_init's LOG_MSG is reached only from
  # CPU_Core_Dynrec_Cache_Init(core == "dynamic"), which cpu.cpp compiles only
  # under `#elif (C_DYNREC)`.  So the line proves three things at once -- the
  # recompiler was compiled in, the config's core=dynamic was accepted, and the
  # cache was actually allocated.  In that same arm cpudecoder is set to
  # CPU_Core_Dynrec_Run unconditionally, so it is a sound proxy for "the dynrec
  # is the decoder".  It is a proxy, though: it observes the allocation, not the
  # dispatch.
  #
  # The DYNTEST check above cannot stand in for this.  It passes identically on
  # the interpreter -- it proves the shell ran, not which decoder ran.
  if grep -q 'DRC: code cache' <<<"$out"; then
    pass "$(grep -o 'DRC: code cache[^\"]*' <<<"$out" | head -1)"
  else
    fail "no 'DRC: code cache' line -- the dynamic recompiler did not allocate a
cache, so core=dynamic was not honoured.  DOS commands still running above
proves nothing here: the interpreter runs them just as well.  Check that
config.h has C_DYNREC 1 for this slice:
    grep C_DYNREC build/obj/*/daum/config.h"
  fi
  # The strings this used to look for -- 'dynamic core not supported' and
  # 'CPU:Forcing normal core' -- appear nowhere in Daum, and 'falling back'
  # appears only in vga_draw's vsync message and in
  # 'SDL:OPENGL:No support for texturesize of %d, falling back to surface'.
  # So the check passed unconditionally, and its one live pattern would have
  # blamed the CPU core for a GL texture-size problem.
  #
  # cpu.cpp:2724 is what actually prints when core=dynamic cannot be honoured:
  #     LOG_MSG("CPU:Unknown core type %s, switching back to normal.",...)
  # It is reached because the `else if (core == "dynamic")` arm only exists
  # inside #if C_DYNAMIC_X86 / #elif C_DYNREC -- with neither, "dynamic" falls
  # through to the unknown-core branch.
  if grep -qi 'Unknown core type\|switching back to normal' <<<"$out"; then
    fail "DOSBox fell back off the dynamic core:"
    printf '        %s\n' "$(grep -i 'Unknown core type\|switching back to normal' <<<"$out" | head -5)"
  else
    pass "no fallback to the interpreter reported"
  fi

  # ---------------------------------------------------------------- profiler
  # The main-loop profiler is compiled in but must be inert unless asked for.
  # Both halves matter: a profiler that never fires is useless, and one that
  # fires by default has changed the shipped binary's behaviour.  The run above
  # was made with DOSBOX_PROF unset, so its output is the "off" sample.
  if grep -q '\[prof\]' <<<"$out"; then
    fail "profiler emitted output with DOSBOX_PROF unset -- it is not inert"
  else
    pass "profiler silent by default (DOSBOX_PROF unset)"
  fi

  proflog="$PORT_DIR/prof.log"
  DOSBOX_PROF=1 DOSBOX_PROF_LOG="$proflog" DOSBOX_PROF_EVERY_MS=200 \
    run_limited 60 "$BIN" -conf "$conf" -c "mount c $dyndir" -c exit >/dev/null 2>&1 || true
  if [[ -s "$proflog" ]] && grep -q '^\[prof\]' "$proflog"; then
    pass "profiler active under DOSBOX_PROF=1 ($(grep -c '^\[prof\]' "$proflog") lines)"
    info "$(head -2 "$proflog")"
    # Exactly one banner means exactly one shared DBProfState.  If dbprof() ever
    # regains internal linkage (`static inline`), every .cpp gets a private copy,
    # each opens the log with "w", and only one of them is ever reported -- so
    # sdlmain.cpp's GL and title counters all read zero.  That looks like a
    # finding, not a bug, which is exactly why it needs a check rather than a
    # comment.
    banners="$(grep -c 'prof\] enabled' "$proflog")"
    if [[ "$banners" == "1" ]]; then
      pass "profiler state is shared across translation units (1 banner)"
    else
      fail "profiler state split across translation units ($banners banners) -- dbprof() must be 'inline', not 'static inline'"
    fi
  else
    # A build made with DAUM_PROFILE=0 lands here legitimately, so this is not
    # a hard failure -- but it is worth saying out loud, because the alternative
    # explanation is that the instrumentation silently did not apply.
    warn "no profiler output under DOSBOX_PROF=1 (built with DAUM_PROFILE=0?)"
  fi

  # ---------------------------------------------------------------- openglhq
  # The three ARB fragment programs are string literals in openglhq.cpp, so
  # their presence in the binary proves the object actually got linked -- which
  # a "does output=openglhq start?" test alone would not, because that path
  # falls back to plain opengl on any failure and still runs fine.
  # Search the DOSBox binary, not $BIN -- $BIN is the launcher trampoline in
  # Contents/MacOS, which contains none of DOSBox's code.
  #
  # And carry a control string.  A count of zero has now twice meant "looked in
  # the wrong place" rather than "the feature is absent", and the two are
  # indistinguishable from the count alone.  SDL:OPENGL: is emitted by
  # sdlmain.cpp in every build, so if the control is missing too, the finding is
  # about the file, not about openglhq.
  scan() {
    if command -v strings >/dev/null 2>&1; then
      strings -a "$1" 2>/dev/null | grep -c "$2" || true
    else
      LC_ALL=C grep -ao "$2" "$1" 2>/dev/null | wc -l | tr -d ' '
    fi
  }
  if [[ ! -f "$DOSBOX" ]]; then
    fail "cannot scan for openglhq: $DOSBOX does not exist"
  else
    ctrl="$(scan "$DOSBOX" 'SDL:OPENGL:')"
    arbfp="$(scan "$DOSBOX" '!!ARBfp1\.0')"
    if [[ "${ctrl:-0}" -lt 1 ]]; then
      fail "cannot read strings out of $DOSBOX (control string absent too) -- the scan is broken, not necessarily the build"
    elif [[ "${arbfp:-0}" -ge 3 ]]; then
      # Universal binary: one copy per slice, so three programs is six matches.
      pass "openglhq shaders linked in ($arbfp ARBfp1.0 programs across all slices)"
    else
      fail "openglhq shaders missing from the binary (found ${arbfp:-0}, expected >=3)
openglhq.cpp was not compiled in.  Most likely a stale source tree: the edits
are applied in place, so daum_patch_sources() skips a tree it has already
stamped.  Force a re-extract:
    rm -rf build/sources/daum-* && ./build-dosbox-daum.sh"
    fi
  fi

  hqconf="$PORT_DIR/hq.conf"
  # aspect is pinned false rather than left at whatever the default is, so the
  # `config -set render aspect=true` in the failure-recovery run below is a
  # guaranteed change and therefore a guaranteed second GFX_SetSize.  Left to
  # the default it would be a no-op the day that default moves, and the check
  # would silently go back to "no opportunity to recover".
  cat > "$hqconf" <<'EOF'
[sdl]
output=openglhq
windowresolution=640x480
[render]
aspect=false
[cpu]
core=dynamic
cycles=10000
EOF
  # This probe reads a FILE, not stdout, and that is the whole point.
  #
  # Three earlier versions grepped DOSBox's stdout for the LOG_MSG at the end of
  # OpenGLHQ_Init, and none of them could observe anything.  LOG_MSG is stdio,
  # so a run that has to be killed loses the buffer; and the only way to force a
  # flush was to end with `-c exit`, which races the thing being measured --
  # GFX_SetSize runs from a PIC event, so quitting early means the mode set
  # never happens.  Every outcome arrived as "saw nothing", which cannot tell
  # "openglhq did not start" from "openglhq started and the output was thrown
  # away", so the check could only warn, every run, regardless of the truth.
  #
  # SDL_OPENGLHQ_PROBE names a file that openglhq.cpp and sdlmain.cpp append to,
  # closing it each time.  Nothing is buffered, so killing the run is now the
  # normal ending, and the run no longer has to exit early.
  #
  # The lines form a ladder, one per step that can silently not happen:
  #
  #   conf output=openglhq accepted   the parser took the openglhq arm
  #   gfx-setsize ... want=N          a mode set happened, and for which type
  #   gl-arm entered ... hq=1         GFX_SetSize reached the OpenGL case
  #   gl-context ready ...            SDL_SetVideoMode gave us a GL drawable
  #   init enter ...                  OpenGLHQ_Init was called
  #   fail ... / init ok ...          and what it decided
  #   render first frame              GFX_EndUpdate really dispatches here
  #
  # Read top-down, the LAST rung present names the step that did not happen.
  #
  # gfx-setsize is the odd one out: every other rung sits inside
  # `case SCREEN_OPENGL:`, so without it "no mode set ever happened" and "the
  # output type was downgraded before the mode set" both present as silence
  # after the parser line, and they want completely different answers.
  hqprobe="$PORT_DIR/openglhq.probe"
  rm -f "$hqprobe"

  # SDL_VIDEODRIVER=dummy is exported at the top of this block so the earlier
  # checks -- which only care about the CPU core, the shell and the FPU -- do
  # not spray windows across the screen.  It must not apply here.  The dummy
  # driver has no OpenGL at all, so with it set this probe measures the
  # verifier's own environment and can only ever report failure.
  #
  # It did exactly that, through four rounds of diagnosis.  "No GL surface in
  # this context", "logged nothing about video", "no video mode was ever set",
  # "the output type was downgraded" -- every one of those verdicts was true,
  # and every one of them traced back to this single export rather than to
  # anything in the bundle.  The ladder was reporting faithfully on a run that
  # had been sabotaged before it started.
  #
  # Written out at both call sites rather than held in a variable: this block is
  # NOT inside a function, so `local` here is a runtime error that `bash -n`
  # does not catch -- and it would take the whole verifier down after every
  # check had already passed.
  #
  # No -c exit: let it sit at the DOS prompt drawing frames, which is what makes
  # the render rung reachable at all, and stop as soon as the answer lands.
  hqout="$(SDL_OPENGLHQ_PROBE="$hqprobe" \
           run_until 30 "$hqprobe" '^(render first frame|fail )' \
                    env -u SDL_VIDEODRIVER "$BIN" -conf "$hqconf" -c "mount c $dyndir")" || true

  # Guard the guard.  If the dummy driver ever leaks back in, the ladder will
  # blame the bundle in a way that reads entirely plausibly -- so name it
  # instead, as a failure of this script.
  if grep -q 'video driver (dummy)' "$hqprobe" 2>/dev/null; then
    fail "the openglhq probe ran under SDL_VIDEODRIVER=dummy, which has no OpenGL.
This is a defect in verify-bundle.sh, not in the bundle: the probe must run with
a real video driver (see the 'env -u SDL_VIDEODRIVER' above)."
  fi
  hqsaw() { [[ -f "$hqprobe" ]] && grep -qE "$1" "$hqprobe"; }
  hqline() { grep -E "$1" "$hqprobe" 2>/dev/null | head -1; }
  # DOSBox sets the mode more than once -- text at boot, then whatever the guest
  # asks for -- so the file holds one group of rungs per mode set, and a failure
  # can follow a success.  Report the mode the FAILING attempt was for, not the
  # first one in the file: pairing a failure with an unrelated resolution sends
  # the reader after the wrong mode.
  hqfailctx() {
    awk '/^fail /{print (ctx ? ctx : prev); exit}
         /^gl-context ready|^init enter/{ctx=$0}
         {prev=$0}' "$hqprobe" 2>/dev/null
  }

  if hqsaw '^fail '; then
    # A real defect, and now reported as one.  The old check called this a
    # warning because it could not tell it apart from an unobservable run.
    fail "openglhq initialisation failed: $(hqline '^fail ')"
    printf '        %s\n' "during: $(hqfailctx)"
    if hqsaw '^init ok'; then
      printf '        %s\n' \
        "An earlier mode DID initialise ($(hqline '^init ok' | sed 's/^init ok //'))," \
        "so this is mode-specific, not a broken build."
    fi
  elif hqsaw '^render first frame'; then
    pass "openglhq running: $(hqline '^init ok' | sed 's/^init ok //')"
    pass "openglhq renders the frame (GFX_EndUpdate dispatches to the shaders)"
  elif hqsaw '^init ok'; then
    pass "openglhq initialised: $(hqline '^init ok' | sed 's/^init ok //')"
    warn "no frame reached the shaders within 30s -- init is proved, dispatch is not"
  elif hqsaw '^gl-arm entered .*hq=0'; then
    fail "GFX_SetSize ran with sdl.opengl.hq clear -- output=openglhq was parsed
but the flag was lost before the mode set, so this is plain opengl:
        $(hqline '^gl-arm entered')"
  elif hqsaw '^gl-context ready'; then
    fail "the GL context came up and OpenGLHQ_Init was never called:
        $(hqline '^gl-context ready')"
  elif hqsaw '^gl-arm entered'; then
    # SDL_SetVideoMode failed between the two rungs.  Environmental (no window
    # server, no GL) rather than a bundle defect.
    warn "no GL drawable in this environment, so openglhq was never reached:"
    printf '        %s\n' "$(grep -i "SDL:OPENGL\|Can't open drawing surface" <<<"$hqout" | head -2)"
  elif hqsaw '^gfx-setsize'; then
    # A mode set DID happen, and did not take the OpenGL case.  The line carries
    # the enum values from sdlmain.cpp itself, so compare against those rather
    # than against a number written down here, which could drift.
    hqwant="$(hqline '^gfx-setsize' | sed -n 's/.*want=\([0-9]*\).*/\1/p')"
    hqgl="$(hqline '^gfx-setsize' | sed -n 's/.*opengl=\([0-9]*\).*/\1/p')"
    if [[ -n "$hqwant" && "$hqwant" == "$hqgl" ]]; then
      fail "GFX_SetSize ran with want_type=SCREEN_OPENGL and did not enter the OpenGL case:
        $(hqline '^gfx-setsize')
That should be impossible -- the switch has nowhere else to go -- so suspect the
gl-arm probe rather than the renderer."
    elif hqsaw '^gl-startup-probe failed'; then
      # GUI_StartUp's SDL_SetVideoMode(640,400,0,SDL_OPENGL) returned NULL, so
      # want_type was downgraded before anything else could happen.  That one
      # call decides whether output=opengl means anything for the whole run, so
      # the reason SDL gave is the entire finding -- print it and nothing else.
      warn "OpenGL is unavailable to this process, so openglhq never ran:"
      printf '        %s\n' "$(hqline '^gl-startup-probe failed' | sed 's/^gl-startup-probe failed: //')"
      printf '        %s\n' "SDL could open a plain window here -- the surface path works -- so this" \
                            "is about the GL context specifically, not about the display."
    else
      warn "the output type was downgraded before any mode set, so openglhq never ran:"
      printf '        %s\n' "$(hqline '^gfx-setsize')"
      grep -i "SDL:\|OPENGL\|surface" <<<"$hqout" | head -3 | cut -c1-110 | sed 's/^/        /'
    fi
  elif hqsaw '^conf output=openglhq accepted'; then
    warn "output=openglhq was accepted but no video mode was ever set in 30s"
    # The HEAD, not the tail.  DOSBox's last lines here are always its shutdown
    # chatter -- the memory-chain dump and "TIMER: leftover handlers" it prints
    # when the probe kills it -- which crowds out whatever went wrong at start-up.
    # Exactly the mistake the truncation capture already had to fix once.
    head -12 <<<"$hqout" | cut -c1-110 | sed 's/^/        /'
  elif grep -q 'DRC: code cache' <<<"$hqout"; then
    # DOSBox demonstrably started -- it got as far as allocating the dynrec
    # cache -- and still wrote no probe line at all.  That is not an
    # inconclusive environment, that is a probe that is not wired in.
    fail "DOSBox ran but wrote nothing to the probe file.
The shader check above proves openglhq is linked, so the parser arm is not
calling OpenGLHQ_ProbeLog -- most likely a stale source tree:
    rm -rf build/sources/daum-* && ./build-dosbox-daum.sh"
  else
    warn "DOSBox did not start under the openglhq probe:"
    printf '        %s\n' "$(tail -5 <<<"$hqout")"
    printf '        %s\n' "Reproduce with:" \
                          "    SDL_OPENGLHQ_PROBE=/tmp/ohq.txt $BIN -conf $hqconf"
  fi

  # ------------------------------------------- the mode-set failure path
  # openglhq releases its GL objects on the way INTO SDL_SetVideoMode_Wrap.  If
  # the mode set then fails, i_width/i_height still describe the last SUCCESSFUL
  # mode -- so the question is whether a later identical GFX_SetSize takes the
  # SETMODE_SAVES early return, skips SDL_SetVideoMode, and leaves openglhq
  # released and never re-initialised.
  #
  # It does not, because the same failure sets sdl.surface to NULL and that is
  # the first term of the early-return guard.  lib/daum.sh asserts the three
  # things that keep that true; this runs it.
  #
  # Worth running rather than only asserting: it is an invariant spread across
  # 15 call sites and two functions, the argument for it is four steps long, and
  # nothing else in this project executes ANY error path.  A static argument is
  # what every finding in this codebase has eventually turned out to need
  # replacing.
  failprobe="$PORT_DIR/openglhq-fail.probe"
  rm -f "$failprobe"
  # n counts OpenGL mode sets issued from GFX_SetSize, so 1 is the first one on
  # the guest-driven path -- the arm the release/re-init cycle lives on.
  #
  # It took two goes to get that selector right, and neither wrong version
  # announced itself as a targeting problem:
  #
  #   counting all mode sets   -> n=2 hit GUI_StartUp's initial 640x400 window
  #   counting all GL modesets -> n=2 hit the SECOND start-up GL probe (there
  #                               are two, opengl_init and GUI_StartUp)
  #
  # Both left DOSBox unable to start, and the check reported "openglhq did not
  # come back" and pointed at the SETMODE_SAVES invariant.  True of the run,
  # entirely about the harness, aimed at the wrong file.  The hook now selects by
  # provenance rather than by ordinal, and the two discriminators below catch it
  # anyway if that ever stops being enough.
  failat="${DAUM_VERIFY_FAIL_MODESET:-1}"
  # The run has to CONTAIN a second mode set, or the check can only ever report
  # "no opportunity to recover" -- which it did, correctly and uselessly, until
  # this was added.  Sitting at the DOS prompt produces exactly one GFX_SetSize:
  # the boot text mode.  Nothing else ever changes video mode, so killing the
  # first one leaves nothing to recover into.
  #
  # `config -set render aspect=true` is the scriptable way to force another.
  # render.cpp:775 re-inits when aspect / scaler / forced change, via
  # RENDER_CallBack(GFX_CallBackReset) -> RENDER_Reset() -> GFX_SetSize.  hq.conf
  # pins aspect=false above, so this is always a real change.
  #
  # Ordering matters and is what makes it a recovery test: the injected failure
  # lands on the boot mode set, DOSBox falls back to surface, and only then does
  # the shell run this -- want_type is still SCREEN_OPENGL, so GFX_SetSize takes
  # the GL arm again and openglhq gets its second chance.
  failout="$(SDL_OPENGLHQ_PROBE="$failprobe" DOSBOX_FAIL_SETVIDEOMODE="$failat" \
             run_until 30 "$failprobe" '^(render first frame|fail )' \
                      env -u SDL_VIDEODRIVER "$BIN" -conf "$hqconf" -c "mount c $dyndir" \
                      -c "config -set render aspect=true")" || true

  if ! grep -q 'INJECTED-NULL' "$failprobe" 2>/dev/null; then
    # The hook never fired, so nothing was tested.  That is a statement about
    # this run, not about the bundle -- say which, or it reads as a pass.
    warn "mode-set failure path not exercised: the run made fewer than $failat GL mode sets.
Nothing was proved either way here.  Raise or lower DAUM_VERIFY_FAIL_MODESET."
    printf '        %s\n' "probe had $(grep -c . "$failprobe" 2>/dev/null || echo 0) line(s)"
  elif ! sed -n "1,$(grep -n 'INJECTED-NULL' "$failprobe" | head -1 | cut -d: -f1)p" "$failprobe" \
       | grep -q '^gfx-setsize'; then
    # No gfx-setsize before the injection means we sacrificed a mode set from
    # start-up, not from the guest-driven path -- DOSBox has no window yet and
    # cannot recover, so a failure here says nothing about the release/re-init
    # cycle.  Report it as a targeting problem in THIS SCRIPT, by name, because
    # the alternative reads as a bundle defect and points at the wrong file.
    warn "the injection landed on a start-up mode set, not one from GFX_SetSize.
DOSBox cannot recover from that -- it has no window yet -- so the recovery path
was not tested.  This is a targeting problem in verify-bundle.sh, not a defect
in the bundle.  Adjust DAUM_VERIFY_FAIL_MODESET (currently $failat)."
    printf '        %s\n' "$(grep -m1 'INJECTED-NULL' "$failprobe")"
  elif ! sed -n "$(( $(grep -n 'INJECTED-NULL' "$failprobe" | head -1 | cut -d: -f1) + 1 )),\$p" "$failprobe" \
       | grep -q '^gfx-setsize'; then
    # The injection landed correctly, but no further mode set ever happened, so
    # DOSBox was never given the opportunity to re-initialise.  "Had no chance"
    # and "had the chance and did not take it" are different findings and only
    # the second is a defect -- collapsing them is how a harness limit gets
    # reported as a bug in the thing being measured.
    warn "no mode set followed the injected failure, so recovery could not occur.
The guest never changed video mode again within the run; nothing is proved
either way.  Give the run something that re-triggers GFX_SetSize, or pick a
lower DAUM_VERIFY_FAIL_MODESET (currently $failat)."
    printf '        %s\n' "$(grep -m1 'INJECTED-NULL' "$failprobe")"
  elif grep -qE '^(render first frame|init ok)' <<<"$(sed -n "$(( $(grep -n 'INJECTED-NULL' "$failprobe" | head -1 | cut -d: -f1) + 1 )),\$p" "$failprobe")"; then
    pass "recovers from a failed mode set (openglhq re-initialised afterwards)"
  else
    fail "openglhq did not come back after a failed mode set.
It was released on the way into SDL_SetVideoMode_Wrap, the mode set returned
NULL, and a LATER GFX_SetSize ran without re-initialising it -- so openglhq is
off for the rest of the session with no diagnostic.  The two innocent
explanations are already excluded above: the injection landed on a GFX_SetSize
call, and another mode set did follow it.  Suspect the SETMODE_SAVES early
return firing on a stale i_width/i_height; lib/daum.sh's INVARIANT block
explains why that is supposed to be impossible."
    printf '        %s\n' "probe tail:"
    tail -6 "$failprobe" 2>/dev/null | sed 's/^/          /'
  fi

  # And the hook must not fire when nobody asked.  It ships in the release
  # binary, so "inert unless set" is a property to check, not to claim -- same
  # bargain as SDL_OPENGLHQ_PROBE above.  $hqprobe is the ordinary run from
  # earlier in this block, made with DOSBOX_FAIL_SETVIDEOMODE unset.
  if grep -q 'INJECTED-NULL' "$hqprobe" 2>/dev/null; then
    fail "the mode-set fault-injection hook fired with DOSBOX_FAIL_SETVIDEOMODE unset"
  else
    pass "mode-set fault injection inert unless DOSBOX_FAIL_SETVIDEOMODE is set"
  fi

  # The probe must be inert in a normal run.  Worth a check rather than a claim:
  # this is instrumentation shipped in the release binary, and the failure mode
  # -- a hardcoded default path -- would be silent and would write to the user's
  # filesystem on every launch.  Same file, same invocation, variable removed;
  # anything appended now was not conditional on the environment.
  if [[ -f "$hqprobe" ]]; then
    hqbefore="$(wc -c <"$hqprobe" | tr -d ' ')"
    # Watching /dev/null for a pattern that cannot occur = "run the full 8s".
    # Long enough: in the run above every line landed in the first second or two.
    # Same environment as the run above, or this compares two different things.
    run_until 8 /dev/null 'never-matches' \
              env -u SDL_VIDEODRIVER "$BIN" -conf "$hqconf" -c "mount c $dyndir" >/dev/null 2>&1 || true
    hqafter="$(wc -c <"$hqprobe" | tr -d ' ')"
    if [[ "$hqbefore" == "$hqafter" ]]; then
      pass "probe inert with SDL_OPENGLHQ_PROBE unset (${hqbefore} bytes, unchanged)"
    else
      fail "the openglhq probe wrote $((hqafter - hqbefore)) bytes with SDL_OPENGLHQ_PROBE unset"
    fi
  fi
  if grep -qi 'SDL_VIDEODRIVER\|Unsupported output device openglhq' <<<"$hqout"; then
    fail "output=openglhq still takes the SDL video-driver path"
  fi

  # ---------------------------------------------------- FPU precision
  # The one test that proves the Windows 3.1 fix, run inside the emulator
  # rather than against a host-side model of it.  fputest.com does the FILD /
  # FBSTP sequence OLE2DISP.DLL uses and writes the digits to a file on a
  # mounted drive -- the guest's screen cannot be read from here.
  # Run fputest.com once and leave its answers where the caller can read them.
  # Factored out because the same run has to happen three times now -- once per
  # core and once per slice -- and three hand-copied blocks would drift.
  #
  # FPU_RESULT is set by assignment, not echoed: fpu_run is called plainly, not
  # inside $( ), so a variable survives.  (Anything called as out="$(...)" would
  # lose it -- the lesson RUN_TIMEOUT_FLAG already had to learn.)
  FPU_RESULT=""
  FPU_COVERAGE=""
  fpu_run() {                       # $1=tag  $2=core  $3.. = command to run
    local tag="$1" core="$2"; shift 2
    local dir="$PORT_DIR/fpu-$tag" cfg="$PORT_DIR/fpu-$tag.conf"
    mkdir -p "$dir"; cp "$FPUTEST" "$dir/FPUTEST.COM"
    printf '[cpu]\ncore=%s\ncycles=10000\n' "$core" > "$cfg"
    # 120s, not 60: under Rosetta the first run also has to translate the
    # bundle, which is what blew the old budget in the openglhq probe.
    # Collect the FPU coverage histogram from the same run -- it costs nothing
    # and turns "the answers were right" into "the answers were right AND here
    # is which instructions produced them".
    FPU_COVERAGE="$dir/coverage.txt"; rm -f "$FPU_COVERAGE"
    DOSBOX_FPU_PROFILE="$FPU_COVERAGE" \
    run_limited 120 "$@" -conf "$cfg" -c "mount c $dir" -c "c:" -c FPUTEST -c exit \
      >/dev/null 2>&1 || true
    FPU_RESULT="$dir/RESULT.TXT"
  }
  fpu_line() { sed -n "${1}p" "$FPU_RESULT" 2>/dev/null | tr -d '\r\n' || true; }
  fpu_sig()  { sed -n '1,3p' "$FPU_RESULT" 2>/dev/null | tr -d '\r' || true; }

  FPUTEST="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/build/fputest.com"
  FPU_NATIVE_SIG=""
  if [[ ! -f "$FPUTEST" ]]; then
    # Not `info`: info prints nothing without --verbose, so three checks used to
    # vanish from the run with no trace but a smaller number in the summary.
    # This happens for real whenever the script is pointed at a bundle that has
    # been moved away from the build tree, which the header advertises as
    # supported.
    warn "no build/fputest.com -- 5 FPU checks skipped, not passed.
Build it with:  ./build-dosbox-daum.sh   (or run verify-bundle.sh from the
build tree, where build/fputest.com lives)"
  else
    fpu_run native-normal normal "$BIN"
    # Two lines now, so read them separately rather than flattening the file.
    got="$(fpu_line 1)"
    rem="$(fpu_line 2)"
    ovf="$(fpu_line 3)"
    FPU_NATIVE_SIG="$(fpu_sig)"
    if [[ "$got" == "00999517642299539456" ]]; then
      pass "FPU: FILD/FBSTP exact -- $got (Windows 3.1 OLE check passes)"
    elif [[ -z "$got" ]]; then
      warn "FPU precision test produced no output (did FPUTEST.COM run?)"
    else
      fail "FPU: FILD/FBSTP lost precision
     got      $got
     expected 00999517642299539456
A mismatch in the low digits is what OLE2DISP.DLL detects, and it aborts
emulation when it finds it -- Windows 3.1 OLE applications will not run."
    fi

    # FPREM vs FPREM1.  5 rem 3 is the smallest case that separates them:
    # truncating the quotient gives 2, rounding it to nearest gives -1.  A core
    # that aliases the two returns the same value twice, and C's fmod() -- which
    # Watcom and Borland implement as a FPREM loop -- returns the wrong sign.
    case "$rem" in
      "2 -1")
        pass "FPU: FPREM 5,3 = 2 and FPREM1 5,3 = -1 (fmod semantics correct)" ;;
      "")
        warn "no FPREM line in RESULT.TXT (an older fputest.com?)" ;;
      "-1 -1")
        fail "FPU: FPREM aliases FPREM1 -- both returned -1 for 5 rem 3.
FPREM must truncate the quotient toward zero; C's fmod(5,3) is 2, not -1." ;;
      *)
        fail "FPU: unexpected FPREM/FPREM1 result
     got      '$rem'
     expected '2 -1'  (FPREM then FPREM1, for 5 rem 3)" ;;
    esac

    # A masked overflow must give infinity.  SoftFloat consults the control
    # word's mask bits while rounding: unmasked, it takes the x87 wrap branch
    # and returns a finite number with the exponent biased down by 24576.  DOS
    # boots with everything masked, so "F" here means every overflow in every
    # program silently produced the wrong number.
    case "$ovf" in
      "I0") pass "FPU: masked overflow -> INF with ES clear (exception masks honoured)" ;;
      "")   warn "no overflow line in RESULT.TXT (an older fputest.com?)" ;;
      "F0") fail "FPU: masked overflow produced a FINITE result.
The control word's mask bits are not reaching SoftFloat, so it took the
unmasked wrap branch (exp -= 0x6000).  Every overflow is silently wrong." ;;
      *)    fail "FPU: unexpected overflow result
     got      '$ovf'
     expected 'I0'  (I = infinity, 0 = ES clear because the exception is masked)" ;;
    esac

    # ------------------------------------------- FPU coverage histogram
    # The three assertions above prove the ANSWERS are right.  They cannot say
    # which instructions produced them, and "the fix works" is not the same
    # claim as "the fix was reached".  DOSBOX_FPU_PROFILE counts both.
    #
    # fputest.com is a known workload, so this check knows what it must contain:
    # it does FILD/FBSTP, both FPREMs, and an overflow.  If those read zero, the
    # counters are not wired to the operations they name -- which matters
    # because an unwired counter prints 0, and 0 is indistinguishable from "this
    # workload does not use it".  lib/daum.sh asserts every named op has a hook
    # at build time; this asserts the hooks fire at run time.
    if [[ ! -s "$FPU_COVERAGE" ]]; then
      fail "no FPU coverage histogram was written under DOSBOX_FPU_PROFILE.
The counters are compiled in (lib/daum.sh asserts the hooks exist), so either
the env var is not reaching the process or dbfpu.h was not installed."
    else
      fpu_cov() { awk -v k="$1" '$1==k {print $2}' "$FPU_COVERAGE"; }
      cov_missing=""
      for op in FILD64 FBST FPREM FPREM1; do
        [[ "$(fpu_cov "$op")" -gt 0 ]] 2>/dev/null || cov_missing="$cov_missing $op"
      done
      if [[ -z "$cov_missing" ]]; then
        pass "FPU coverage histogram records the instructions fputest.com executes"
        info "$(grep -E '^\[fpu\] (ops|anomalies)' "$FPU_COVERAGE" | tr '\n' ' ')"
      else
        fail "the FPU histogram reports 0 for operations fputest.com definitely runs:$cov_missing
A counter that reads 0 for an instruction that executed is worse than no
counter: it reads exactly like 'this workload never used it'."
      fi
      # The anomaly counters are one hook in SF_flags, shared by every op.
      # fputest deliberately raises a masked overflow, so OE must be non-zero --
      # if it is not, the exception plumbing is not being observed at all.
      if [[ "$(awk '/^\[fpu\] anomalies:/{for(i=1;i<=NF;i++) if($i ~ /^OE=/){sub("OE=","",$i); print $i}}' "$FPU_COVERAGE")" -gt 0 ]] 2>/dev/null; then
        pass "FPU anomaly counters observe the masked overflow fputest.com raises"
      else
        fail "the FPU anomaly counters saw no overflow, but fputest.com raises one.
SF_flags() is where every operation's exception status funnels through; if it
records nothing, IE/SF/ES are not being observed either."
      fi
    fi

    # ...and it must be silent when nobody asked.  It ships in the release
    # binary, same bargain as SDL_OPENGLHQ_PROBE and the mode-set hook.
    #
    # Written out rather than routed through fpu_run(), because fpu_run ALWAYS
    # sets DOSBOX_FPU_PROFILE -- calling it here would set the variable and then
    # assert the variable had no effect, which is a check that cannot fail.  The
    # first draft of this did exactly that.
    #
    # Same shape as the openglhq inertness test: same binary, same invocation,
    # variable removed, and the existing file must not grow.  A hardcoded
    # default path is the failure this is looking for.
    if [[ -s "$FPU_COVERAGE" ]]; then
      fpu_before="$(wc -c <"$FPU_COVERAGE" | tr -d ' ')"
      fpu_idir="$PORT_DIR/fpu-inert"; mkdir -p "$fpu_idir"; cp "$FPUTEST" "$fpu_idir/FPUTEST.COM"
      printf '[cpu]\ncore=normal\ncycles=10000\n' > "$PORT_DIR/fpu-inert.conf"
      run_limited 120 env -u DOSBOX_FPU_PROFILE "$BIN" -conf "$PORT_DIR/fpu-inert.conf" \
        -c "mount c $fpu_idir" -c "c:" -c FPUTEST -c exit >/dev/null 2>&1 || true
      fpu_after="$(wc -c <"$FPU_COVERAGE" | tr -d ' ')"
      if [[ "$fpu_before" == "$fpu_after" ]]; then
        pass "FPU histogram inert with DOSBOX_FPU_PROFILE unset (${fpu_before} bytes, unchanged)"
      else
        fail "the FPU histogram wrote $((fpu_after - fpu_before)) bytes with DOSBOX_FPU_PROFILE unset"
      fi
    fi

    # Everything above ran under core=normal, which reaches fpu.cpp's ESC
    # handlers directly.  core=dynamic reaches them through
    # core_dynrec/dyn_fpu.h, which decodes the ESC opcodes itself and calls the
    # same entry points with its own operand handling.  That is a second,
    # entirely separate dispatch path, and nothing exercised it.
    #
    # Compare against the normal core rather than against literals: the point is
    # that the two dispatches agree, and pinning literals here would mean two
    # places to update whenever fputest.com grows a line.
    fpu_run native-dynamic dynamic "$BIN"
    fpudyn="$(fpu_sig)"
    if [[ -z "$fpudyn" ]]; then
      fail "FPU: no RESULT.TXT under core=dynamic -- the test did not run on the
dynamic core's FPU dispatch (core_dynrec/dyn_fpu.h)."
    elif [[ "$fpudyn" == "$FPU_NATIVE_SIG" ]]; then
      pass "FPU: core=dynamic agrees with core=normal (dyn_fpu.h dispatch correct)"
    else
      fail "FPU: the dynamic core disagrees with the interpreter.
Both call the same fpu.cpp entry points, so this is dyn_fpu.h's operand
handling, not the arithmetic.
     core=normal   $(tr '\n' '|' <<<"$FPU_NATIVE_SIG")
     core=dynamic  $(tr '\n' '|' <<<"$fpudyn")"
    fi
  fi

  # ------------------------------------------------- the other architecture
  # Everything above ran the NATIVE slice, which on a universal binary leaves
  # half the product untested -- and the halves are not equivalent code.  The
  # dynamic recompiler backends are entirely separate files (risc_armv8le.h vs
  # risc_x64.h) and the W^X handling only exists on one of them.  A bug in the
  # slice you are not sitting on is invisible otherwise.
  #
  # The FPU is the opposite case and matters just as much.  This comment used to
  # say the two slices ran different FPU cores -- "configure.ac defines C_FPU_X86
  # for x86/x86_64 only, so the Intel slice runs real x87 while the arm64 slice
  # runs the portable double-based core".  That was true, and the patch to
  # fpu.cpp is what stopped it being true: both slices now include
  # fpu_instructions_softfloat.h unconditionally and C_FPU_X86 is ignored.
  # daum_audit_features() already knows this and deliberately reads fpu.cpp
  # rather than config.h; this comment was simply never updated with it.
  #
  # So the asymmetry is gone -- and *that is a claim, not a fact*, until someone
  # runs the same test on both slices and compares.  The cross-slice FPU check
  # below is that test.  It is the whole reason the softfloat core exists and it
  # had never been run.
  #
  # Rosetta 2 runs the x86_64 slice on Apple Silicon.  The reverse is not
  # possible, so an Intel host can only ever check itself.
  #
  # Run the REAL binary, not the launcher: exec'ing a universal binary re-picks
  # the preferred (native) architecture, so `arch -x86_64 launcher` would hand
  # back an arm64 dosbox and silently test nothing.
  case "$(uname -m)" in
    arm64)  OTHER_ARCH="x86_64" ;;
    *)      OTHER_ARCH="" ;;
  esac

  if [[ -z "$OTHER_ARCH" ]]; then
    info "host is $(uname -m); the other slice cannot be executed here"
  elif ! arch -"$OTHER_ARCH" /usr/bin/true >/dev/null 2>&1; then
    warn "cannot run the $OTHER_ARCH slice (Rosetta 2 not installed?) -- half the bundle is unverified"
    info "install with: softwareupdate --install-rosetta"
  else
    sect "Cross-architecture: the $OTHER_ARCH slice under Rosetta 2"

    xbin="$RUN_APP/Contents/Resources/daum/bin/dosbox"
    xarch="$(lipo -archs "$xbin" 2>/dev/null || true)"
    if [[ "$xarch" == *"$OTHER_ARCH"* ]]; then
      pass "$OTHER_ARCH slice present in the shipped binary ($xarch)"
    else
      fail "no $OTHER_ARCH slice to test (got: ${xarch:-none})"
    fi

    xdyn="$PORT_DIR/dyn-$OTHER_ARCH"; mkdir -p "$xdyn"
    xout="$(run_limited 180 arch -"$OTHER_ARCH" "$xbin" -conf "$conf" \
            -c "mount c $xdyn" -c 'echo XARCHTEST > c:\x.txt' -c exit)" || true

    if [[ -f "$xdyn/x.txt" ]] && grep -q 'XARCHTEST' "$xdyn/x.txt" 2>/dev/null; then
      pass "core=dynamic runs DOS commands on the $OTHER_ARCH slice"
    else
      fail "the $OTHER_ARCH slice did not execute DOS commands"
      printf '        %s\n' "$(tail -12 <<<"$xout")"
    fi

    # The x86_64 dynrec is a different backend from the one exercised above,
    # and it is the one nobody on this machine has ever run.  Same reasoning as
    # the native check: this is the only thing here that can fail when the
    # recompiler is not what runs, so it fails rather than warns.
    if grep -q 'DRC: code cache' <<<"$xout"; then
      pass "$OTHER_ARCH: $(grep -o 'DRC: code cache[^\"]*' <<<"$xout" | head -1)"
    else
      fail "$OTHER_ARCH: no 'DRC: code cache' line -- risc_x64.h's cache was never
allocated, so this slice ran the interpreter.  The DOS commands above pass
either way and cannot tell you which."
    fi
    # See the native check: the two patterns this used to also look for do not
    # occur anywhere in Daum, and the third matched a GL message.
    if grep -qi 'Unknown core type\|switching back to normal' <<<"$xout"; then
      fail "$OTHER_ARCH slice fell back to the interpreter:"
      printf '        %s\n' "$(grep -i 'Unknown core type\|switching back to normal' <<<"$xout" | head -5)"
    else
      pass "$OTHER_ARCH: no fallback to the interpreter"
    fi

    # ---------------------------------------------- cross-slice FPU agreement
    # The claim the whole SoftFloat core was written to make true: both slices
    # compute bit-for-bit alike, so a save state moves between them and a
    # program cannot tell which one it is running on.  Until now it was only a
    # claim -- the FPU test ran on the native slice and stopped there.
    #
    # Compare the two RESULT.TXT files rather than re-checking literals.  A
    # literal comparison would pass if BOTH slices were wrong in the same way,
    # which is exactly the failure the softfloat change was meant to rule out;
    # the native run above is what pins the values, and this pins the agreement.
    if [[ -z "$FPU_NATIVE_SIG" ]]; then
      info "$OTHER_ARCH: no native FPU result to compare against; skipping"
    else
      fpu_run "$OTHER_ARCH-normal" normal arch -"$OTHER_ARCH" "$xbin"
      xfpu="$(fpu_sig)"
      if [[ -z "$xfpu" ]]; then
        fail "$OTHER_ARCH: FPUTEST.COM produced no RESULT.TXT, so the two slices'
arithmetic is still unverified -- which is the one thing the SoftFloat core
was written to guarantee."
      elif [[ "$xfpu" == "$FPU_NATIVE_SIG" ]]; then
        pass "$OTHER_ARCH: FPU results identical to $(uname -m) (slices agree bit-for-bit)"
      else
        fail "$OTHER_ARCH: the two slices do not compute the same answers.
Both are supposed to include fpu_instructions_softfloat.h; check that neither
one picked up fpu_instructions.h or fpu_instructions_x86.h instead.
     $(uname -m)  $(tr '\n' '|' <<<"$FPU_NATIVE_SIG")
     $OTHER_ARCH  $(tr '\n' '|' <<<"$xfpu")"
      fi
    fi

    # Opt-in, because it costs minutes and cannot answer the question it looks
    # like it answers.  Rosetta translates CPU instructions faithfully -- which
    # is why the dynrec checks above are meaningful -- but GL under translation
    # is not representative of GL on a real Intel Mac, so neither a pass nor a
    # failure here says much about the hardware it stands in for.  It also
    # reliably produces ~2.8 GB of log and a 180s timeout.
    #
    # Set DAUM_VERIFY_XARCH_GL=1 to run it anyway; the head+tail capture will
    # show what is looping.
    # 180s, not 60: the FIRST run of the non-native slice has to AOT-translate
    # the whole bundle -- dosbox plus SDL2, FluidSynth, FFmpeg, munt -- and cache
    # it.  That alone blew the old budget and reported a hang where there was
    # only a cold cache.  Subsequent runs are quick.
    if [[ "${DAUM_VERIFY_XARCH_GL:-0}" != "1" ]]; then
      info "$OTHER_ARCH: openglhq probe skipped (DAUM_VERIFY_XARCH_GL=1 to run it)"
      xhq=""
    else
    xhqprobe="$PORT_DIR/openglhq-$OTHER_ARCH.probe"
    rm -f "$xhqprobe"
    xhq="$(SDL_OPENGLHQ_PROBE="$xhqprobe" \
           run_until 180 "$xhqprobe" '^(render first frame|fail )' \
                    env -u SDL_VIDEODRIVER arch -"$OTHER_ARCH" "$xbin" \
                    -conf "$hqconf" -c "mount c $xdyn")" || true
    xhq_timeout=0; run_unanswered && xhq_timeout=1
    if run_truncated; then
      warn "$OTHER_ARCH: the openglhq probe emitted $(run_trunc_bytes) bytes of log"
      printf '        %s\n' "truncated to $RUN_MAX_BYTES; that much output means something is looping."
      # Normalise before counting.  DOSBox prefixes debug lines with a cycle
      # count and embeds addresses, so every line is textually unique and
      # uniq -c can never aggregate them -- the histogram just re-reports the
      # head's startup text no matter what is looping.  Fold digits and hex to
      # placeholders so repeated line SHAPES group together.
      printf '        %s\n' "most frequent log shapes (numbers folded):"
      sed -E 's/^[[:space:]]*[0-9]+:[[:space:]]*//; s/0x[0-9A-Fa-f]+/0xN/g; s/[0-9]+/N/g' \
          <<<"$xhq" | sort | uniq -c | sort -rn | head -3 | sed 's/^/          /'
      # Folding numbers groups the shapes but destroys the values, and the value
      # is often the whole point -- here it is which interrupt.  Show raw lines
      # from where the elision starts, i.e. inside the looping region.
      printf '        %s\n' "raw sample from the looping region:"
      grep -A3 'bytes elided' <<<"$xhq" | tail -3 | cut -c1-100 | sed 's/^/          /'
      printf '        %s\n' "last lines before it was killed:"
      tail -n 4 <<<"$xhq" | cut -c1-100 | sed 's/^/          /' 
    fi
    # Same ladder as the native probe, read from the other slice's own file.
    if grep -q '^fail ' "$xhqprobe" 2>/dev/null; then
      fail "$OTHER_ARCH: openglhq initialisation failed: $(grep -m1 '^fail ' "$xhqprobe")"
    elif grep -q '^render first frame' "$xhqprobe" 2>/dev/null; then
      pass "$OTHER_ARCH: openglhq running and rendering: $(grep -m1 '^init ok' "$xhqprobe" | sed 's/^init ok //')"
    elif grep -q '^init ok' "$xhqprobe" 2>/dev/null; then
      pass "$OTHER_ARCH: openglhq initialised: $(grep -m1 '^init ok' "$xhqprobe" | sed 's/^init ok //')"
      warn "$OTHER_ARCH: no frame reached the shaders (dispatch unproved on this slice)"
    elif [[ "$xhq_timeout" == "1" ]]; then
      # Which rung it stopped at is the useful part; name it rather than
      # reporting the timeout alone.
      warn "$OTHER_ARCH: openglhq got no further than: $(tail -1 "$xhqprobe" 2>/dev/null || echo 'nothing at all')"
      info "a GL context under Rosetta can be very slow or never come up; try by hand:"
      info "    SDL_OPENGLHQ_PROBE=/tmp/ohq.txt arch -$OTHER_ARCH $xbin -conf $hqconf"
    else
      warn "$OTHER_ARCH: openglhq initialisation not observed (same caveats as above)"
    fi
    fi
  fi

  rm -rf "$PORT_DIR"
fi

# =========================================================================
printf '\n%s\n' "${B}Summary${Z}"
printf '  checks run : %d\n' "$CHECKS"
printf '  warnings   : %d\n' "$WARNINGS"
if [[ $FAILURES -eq 0 ]]; then
  printf '  %sfailures   : 0 -- bundle meets every requirement%s\n\n' "$G" "$Z"; exit 0
else
  printf '  %sfailures   : %d%s\n\n' "$R" "$FAILURES" "$Z"; exit 1
fi
