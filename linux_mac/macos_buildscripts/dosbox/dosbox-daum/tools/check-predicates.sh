#!/usr/bin/env bash
#
# Test verify-bundle.sh's decision logic against synthetic input.
#
# The point is not the predicates -- it is that they can FAIL.  Three of the
# checks in verify-bundle.sh could not:
#
#   * "runs from a relocated copy" was `grep -qi dosbox` on output captured with
#     2>&1, and every dyld error names the binary path, which contains "dosbox".
#     A bundle with no libraries at all passed.
#   * "no fallback to the interpreter" looked for 'dynamic core not supported'
#     and 'CPU:Forcing normal core', neither of which occurs anywhere in Daum,
#     plus 'falling back', which occurs only in a vsync message and in
#     'SDL:OPENGL:No support for texturesize of %d, falling back to surface'.
#     So it always passed, and its one live pattern was a GL message that would
#     have been reported as a CPU-core failure.
#   * the package-manager scan checked /usr/local/Cellar but not
#     /usr/local/opt, which is Intel Homebrew's actual linkage path -- and this
#     bundle ships an x86_64 slice.
#
# Each case below is fed the text that used to be classified wrongly, so this
# file is a regression test for the specific mistakes, not a restatement of the
# greps.  Run it after touching any of them; it needs no bundle and no build.
set -uo pipefail
p=0; f=0
t(){ local name="$1" want="$2" got="$3"
     if [[ "$want" == "$got" ]]; then printf '  ok    %-52s -> %s\n' "$name" "$got"; p=$((p+1))
     else printf '  FAIL  %-52s -> %s (wanted %s)\n' "$name" "$got" "$want"; f=$((f+1)); fi; }

# --------------------------------------------------------------- -version
# Mirrors the predicate in verify-bundle.sh; keep the two in step.
#
# This file drifted from it once already, and the drift was invisible: the
# regex here stayed `^DOSBox version [0-9]` after verify-bundle.sh moved to
# `[^ ]+`, and the fixture below used a numeric version, so the suite passed
# while the shipped check was failing every build.  Daum's VERSION is the string
# "SVN-Daum", so the numeric anchor never matched a real banner at all.  The
# real banner is now the primary fixture, for exactly that reason.
ver(){ if   grep -qE '^DOSBox version [^ ]+, copyright' <<<"$1"; then echo PASS
       elif grep -qE 'dyld|Library not loaded|image not found|code signature' <<<"$1"; then echo FAIL-dyld
       else echo FAIL-other; fi; }
daum=$'\nDOSBox version SVN-Daum, copyright 2002-2015 DOSBox Team.\n\nDOSBox is written by the DOSBox Team (See AUTHORS file))'
good=$'\nDOSBox version 0.74, copyright 2002-2015 DOSBox Team.\n\nDOSBox is written by...'
dyld=$'dyld[54321]: Library not loaded: @rpath/libSDL2-2.0.0.dylib\n  Referenced from: /tmp/x.app/Contents/Resources/daum/bin/dosbox\n  Reason: tried:'
sig=$'dyld[9]: code signature in (/tmp/x/dosbox) not valid for use in process'
t "-version: the real Daum banner (non-numeric)"  PASS       "$(ver "$daum")"
t "-version: a numeric version still matches"     PASS       "$(ver "$good")"
t "-version: dyld failure naming 'dosbox'"        FAIL-dyld  "$(ver "$dyld")"
t "-version: bad code signature"                  FAIL-dyld  "$(ver "$sig")"
t "-version: empty output"                        FAIL-other "$(ver "")"
t "-version: unrelated text containing 'dosbox'"  FAIL-other "$(ver 'launching dosbox now')"
t "-version: banner without the copyright tail"   FAIL-other "$(ver 'DOSBox version SVN-Daum')"

# ----------------------------------------------------------------- dynrec
drc(){ grep -q 'DRC: code cache' <<<"$1" && echo PASS || echo FAIL; }
fbk(){ grep -qi 'Unknown core type\|switching back to normal' <<<"$1" && echo FAIL || echo PASS; }
run_ok=$'DRC: code cache mapped RWX, 16384-byte host pages\nMIDI:Opened device'
run_jit=$'DRC: code cache MAP_JIT (W^X toggled at block entry), 16384-byte host pages'
run_interp=$'CPU:Unknown core type dynamic, switching back to normal.\nMIDI:Opened device'
run_gl=$'SDL:OPENGL:No support for texturesize of 4096, falling back to surface\nDRC: code cache mapped RWX, 16384-byte host pages'
t "DRC: present (RWX mapping)"                   PASS "$(drc "$run_ok")"
t "DRC: present (MAP_JIT mapping)"               PASS "$(drc "$run_jit")"
t "DRC: absent -- interpreter ran"               FAIL "$(drc "$run_interp")"
t "fallback: healthy run"                        PASS "$(fbk "$run_ok")"
t "fallback: real interpreter fallback"          FAIL "$(fbk "$run_interp")"
t "fallback: GL texturesize msg must not trip it" PASS "$(fbk "$run_gl")"

# ------------------------------------------------------- package managers
pm(){ grep -l -e '/opt/homebrew' -e '/opt/local/' \
              -e '/usr/local/Cellar' -e '/usr/local/opt/' <<<"$1" >/dev/null 2>&1 \
      && echo FAIL || echo PASS; }
t "pm: bundle-relative path"                     PASS "$(pm '@rpath/libSDL2.dylib')"
t "pm: /usr/local/opt (Intel Homebrew)"          FAIL "$(pm '/usr/local/opt/sdl2/lib/libSDL2.dylib')"
t "pm: /usr/local/Cellar"                        FAIL "$(pm '/usr/local/Cellar/libpng/1.6/lib/x.dylib')"
t "pm: /opt/homebrew (Apple Silicon)"            FAIL "$(pm '/opt/homebrew/lib/libpng.dylib')"
t "pm: /opt/local/include (MacPorts headers)"    FAIL "$(pm '/opt/local/include/png.h')"
t "pm: /usr/lib is a system path, not a manager" PASS "$(pm '/usr/lib/libSystem.B.dylib')"

# -------------------------------------------- mode-set failure recovery
# The check this mirrors runs the real binary with DOSBOX_FAIL_SETVIDEOMODE set
# and reads the probe ladder.  What is easy to get wrong is the ORDERING: a
# successful init that happened BEFORE the injected failure must not be read as
# recovery from it, and "the hook never fired" must not be read as a pass.
#
# The third case is the one that actually bit: with the hook counting ALL mode
# sets, n=2 landed on GUI_StartUp's initial 640x400 SDL_RESIZABLE window. DOSBox
# never finished starting, and the check reported "openglhq did not come back"
# and pointed at the SETMODE_SAVES invariant — true about the run, entirely
# about the harness. A `gfx-setsize` line before the injection is what
# distinguishes "we killed a guest-driven mode set" from "we killed start-up".
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
recov(){ printf '%s\n' "$1" > "$tmp"
  local n
  if ! grep -q 'INJECTED-NULL' "$tmp"; then echo WARN-not-exercised; return; fi
  n="$(grep -n 'INJECTED-NULL' "$tmp" | head -1 | cut -d: -f1)"
  if ! sed -n "1,${n}p" "$tmp" | grep -q '^gfx-setsize'; then echo WARN-mistargeted; return; fi
  if ! sed -n "$(( n + 1 )),\$p" "$tmp" | grep -q '^gfx-setsize'; then echo WARN-no-retry; return; fi
  if grep -qE '^(render first frame|init ok)' <<<"$(sed -n "$(( n + 1 )),\$p" "$tmp")"; then echo PASS
  else echo FAIL; fi; }
t "modeset: re-inits after the injected failure"  PASS \
  "$(recov $'gfx-setsize 640x480\nmode-set INJECTED-NULL at GFX_SetSize GL call 2 (640x480 flags=0x12)\nmode-set returned NULL 640x480 bpp=0 flags=0x12: \ngfx-setsize 640x480\ninit ok 640x480 -> 1280x960, ctx new\nrender first frame')"
# "no mode set followed" is a missed OPPORTUNITY, not a defect; "a mode set
# followed and openglhq stayed dead" is the defect.  Two cases, two verdicts.
t "modeset: no retry after failure = not proved"   WARN-no-retry \
  "$(recov $'gfx-setsize 640x480\nmode-set INJECTED-NULL at GFX_SetSize GL call 2 (640x480 flags=0x12)\nmode-set returned NULL 640x480 bpp=0 flags=0x12: ')"
t "modeset: retried but stayed dead = stranded"    FAIL \
  "$(recov $'gfx-setsize 640x480\nmode-set INJECTED-NULL at GFX_SetSize GL call 2 (640x480 flags=0x12)\nmode-set returned NULL 640x480 bpp=0 flags=0x12: \ngfx-setsize 640x480\ngl-arm entered 640x480 hq=1 scale 1.000x1.000 flags=0x188')"
t "modeset: a reuse cannot follow a release"       FAIL \
  "$(recov $'gfx-setsize 640x480\nmode-set INJECTED-NULL at GFX_SetSize GL call 2 (640x480 flags=0x12)\ngfx-setsize 640x480\ninit reuse 640x480 -> 1280x960, ctx SURVIVED')"
t "modeset: hook never fired is not a pass"        WARN-not-exercised \
  "$(recov $'gfx-setsize 640x480\ninit ok 640x480 -> 1280x960, ctx new\nrender first frame')"
# Ordering: an `init ok` BEFORE the injection must never be read as recovery
# from it.  Two variants, because the two later arms reach that question by
# different routes and both have to get it right.
t "modeset: earlier success, no retry -> not proved" WARN-no-retry \
  "$(recov $'gfx-setsize 640x480\ninit ok 640x480 -> 1280x960, ctx new\nrender first frame\nmode-set INJECTED-NULL at GFX_SetSize GL call 5 (640x480 flags=0x12)')"
t "modeset: earlier success, retried, stayed dead"   FAIL \
  "$(recov $'gfx-setsize 640x480\ninit ok 640x480 -> 1280x960, ctx new\nrender first frame\nmode-set INJECTED-NULL at GFX_SetSize GL call 5 (640x480 flags=0x12)\ngfx-setsize 640x480\ngl-arm entered 640x480 hq=1 scale 1.000x1.000 flags=0x188')"
# The regression this whole discriminator exists for: the real 51-check run,
# verbatim.  No gfx-setsize precedes the injection, so it must read as
# mistargeted, NOT as "openglhq did not come back".
t "modeset: start-up call = harness fault, not a defect" WARN-mistargeted \
  "$(recov $'conf output=openglhq accepted\nmode-set INJECTED-NULL at call 2 (640x400 flags=0x10)\nmode-set returned NULL 640x400 bpp=0 flags=0x10: Surface doesn\'t have a colorkey')"

# ------------------------------------------------- the mirrors still match
# Every predicate above is a COPY of one in verify-bundle.sh, and a copy that
# drifts is worse than no test: it goes green while the real check is broken.
# That already happened once here (see the -version note).  So rather than
# asking readers to keep them in step, check it.
#
# Greps the literal patterns out of verify-bundle.sh and asserts this file uses
# the same ones.  Not a proof of equivalence -- it is a tripwire on the specific
# strings that carry the logic, which is what actually drifted.
vb="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/verify-bundle.sh"
if [[ ! -f "$vb" ]]; then
  printf '  FAIL  %-52s -> cannot find verify-bundle.sh\n' "mirrors: source available"; f=$((f+1))
else
  self="${BASH_SOURCE[0]}"
  mirror(){ local what="$1" pat="$2"
    if grep -qF -- "$pat" "$vb" && grep -qF -- "$pat" "$self"; then
      printf '  ok    %-52s -> in step\n' "mirrors: $what"; p=$((p+1))
    else
      printf '  FAIL  %-52s -> DRIFTED (in verify-bundle.sh: %s, here: %s)\n' \
        "mirrors: $what" \
        "$(grep -qF -- "$pat" "$vb" && echo yes || echo no)" \
        "$(grep -qF -- "$pat" "$self" && echo yes || echo no)"; f=$((f+1))
    fi; }
  mirror "-version banner regex"      '^DOSBox version [^ ]+, copyright'
  mirror "-version loader-error set"  'dyld|Library not loaded|image not found|code signature'
  mirror "dynrec cache line"          'DRC: code cache'
  mirror "interpreter-fallback set"   'Unknown core type\|switching back to normal'
  mirror "package-manager prefixes"   "-e '/usr/local/opt/'"
  mirror "recovery marker set"        '^(render first frame|init ok)'
fi

printf '\n%d ok, %d failed\n' "$p" "$f"
exit $(( f ? 1 : 0 ))
