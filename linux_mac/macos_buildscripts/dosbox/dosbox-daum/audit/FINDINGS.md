# DOSBox Daum build — audit findings and repairs

21 findings from the audit pass, plus two found afterwards: F22 while fixing the
rest, and **F23 — the most serious defect in the whole exercise — caught by one
of the new checks on its first real run.** 22 fixed, 2 investigated and closed
as non-defects (F19, F21-remainder), none left open.
Confidence labels are used strictly:

- **PROVEN** — a test that fails before the fix and passes after.
- **DEMONSTRATED** — mechanism reproduced in isolation; live impact not measured.
- **REASONED** — read from the source, no experiment.

Standing tests added by this work, all currently green:

| harness | what it pins |
|---|---|
| `vendor/bochs-fpu/test/test.cc` | 39 FPU assertions, incl. 13 new ones |
| `vendor/bochs-fpu/test/tu2.cc` | the header is safe in two TUs; 24 dynrec entry points resolve |
| `tools/armv8-encoding-check/run.sh` | 80 AArch64 encodings vs a real assembler |
| `tools/check-predicates.sh` | 27 decisions vs synthetic input + 6 anti-drift tripwires |
| `verify-bundle.sh` (F19) | DOSBox recovers from a failed mode set; the hook is inert unset |
| `verify-bundle.sh` (F10) | `core=normal` and `core=dynamic` compute the same answers |
| `verify-bundle.sh` (F9) | the arm64 and x86_64 slices compute the same answers |
| `vendor/dbfpu.h` | which FPU paths a workload actually executes, and its anomalies |

**Build status.** Seven full macOS builds. Current: **51 checks, 0 warnings,
0 failures.**

| run | result | cause |
|---|---|---|
| 1 | 49 / 0 / 3 | F23 (real, severe) + two regressions of mine (F24) |
| 2 | 49 / 0 / 0 | — |
| 3 | 51 / 0 / 1 | new F19 check mistargeted its injection (counted all mode sets) |
| 4 | 50 / 1 / 0 | mistargeted again (counted all GL mode sets); warned, correctly |
| 5 | — | `Permission denied`: my edits dropped verify-bundle.sh's +x (F25) |
| 6 | 50 / 1 / 0 | targeting right, but the run contained no second mode set |
| 7 | 51 / 0 / 0 | green |

Runs 3–6 were all the harness, never the bundle; the bundle has been clean since
run 2. Each of those four failures is now a regression case in
`tools/check-predicates.sh` or a structural fix, not a fixed instance.

---

## Fixed

### F23. `core=dynamic` was running the old 53-bit `double` FPU — PROVEN

**The default core of every build shipped so far had none of the FPU work in it.**

Patching `src/fpu/fpu.cpp` to use SoftFloat fixed the interpreter and nothing
else. `src/cpu/core_dynrec/dyn_fpu.h`, reached from `core_dynrec.cpp` via
`decoder.h`, carried its own copy of the same selection:

```c
#if C_FPU_X86
#include "../../fpu/fpu_instructions_x86.h"
#else
#include "../../fpu/fpu_instructions.h"
#endif
```

The entry points in both headers are `static`, so each translation unit gets its
own set, and `dyn_fpu.h` emits calls to *its* copy via
`gen_call_function_R((void*)&FPU_FADD_EA, ...)`. `C_FPU_X86` is defined on
neither slice, so both took the `#else`: Daum's 53-bit double core, on arm64 and
x86_64 alike.

So under `core=dynamic` — the default, and the entire reason the AArch64 backend
exists — the Windows 3.1 OLE fix did not apply, the exception masks were not
read, and none of F1 or F2 was reachable either.

Caught by the F10 check, about an hour old, on its first run against a real
build:

```
core=normal   00999517642299539456 | 2 -1 | I0
core=dynamic  00999517642299539600 | 2 -1 | F0
```

`...9600` is the double core's answer, recorded verbatim in
`vendor/bochs-fpu/test/README.md`. `F0` is a masked overflow returning a finite
number, which happens only where nothing reads the control word. Two independent
signatures of one cause.

**Nothing else could have found it.** `daum_audit_features()` printed
`FPU core = SoftFloat-3e (80-bit, identical on every slice)` on every build —
true about `fpu.cpp`, false about the binary. The host harness compiles the
header directly, so it was always testing the interpreter's core. The
cross-slice check (F9) passed too, because it runs `core=normal` and both slices
agreed there. Three green signals over one broken thing.

Fixed by pointing `dyn_fpu.h` at the same header, adding
`-I$(top_srcdir)/src/softfloat` to `src/cpu/Makefile.am`, and guarding it three
ways:

- a post-patch assertion on `dyn_fpu.h`, plus a negative one that it can no
  longer reach a non-softfloat core;
- a **sweep** for any third FPU selector in the tree, rather than naming the two
  we know about (`core_dyn_x86` is exempt and says why: `C_DYNAMIC_X86` is never
  defined here);
- `daum_audit_features()` now reads *both* files and `die`s if they disagree,
  instead of reporting on one and calling it "the FPU core".

Safety of sharing the header across two TUs is pinned by
`vendor/bochs-fpu/test/tu2.cc`, which links a second TU and takes the address of
all 24 entry points the recompiler calls through. Two mutations verified: an
entry point losing `static` fails at link, and one renamed away fails to compile.

The generalisable lesson, written into the test README: **a host harness over a
header tests the header, not the build.** It cannot see a second consumer.

### F1. FPATAN computed `atan(ST0/ST1)` — PROVEN

`vendor/fpu_instructions_softfloat.h`. Bochs takes the denominator first
(`fpu_trans.cc:164` calls `fpatan(ST0, ST1)`, and `fpatan.cc` confirms it: with
`b` infinite and `a` finite it returns ±π/2). The header passed them reversed,
so every FPATAN returned the complementary angle. `FYL2X` two lines below
already used the correct order — the asymmetry was the tell.

Before: `atan(2)` and `atan(1/2)` came back exactly exchanged. After: both
correct, with `FYL2X` kept as an operand-order control so a future "let's make
these consistent" edit fails loudly.

### F2. FCOM never raised #IA on a QNaN — PROVEN

`FPU_FUCOM` was `{ FPU_FCOM(st_,other); }` and both used
`extF80_compare_quiet` — the same alias shape as the FPREM/FPREM1 bug. The two
instructions differ in exactly one thing and it is not the result: FCOM signals
on any NaN, FUCOM only on an SNaN. So the pair was backwards, with FUCOM correct
and FCOM silently exempt from the exception machinery that is the whole reason
this file exists.

Now a shared kernel with a `quiet` flag. The empty-operand path also sets IE+SF
(stack fault), which it should have all along.

### F3. `mmath.h` `#endif` closed the wrong conditional — PROVEN

`#endif /* FMATH_USE_SSE */` was inserted between `#ifndef __CYGWIN__` and its
body, so it closed the CYGWIN guard and the file's own `#endif` closed the SSE
block. It balanced, so it compiled, and `fmath::log2` simply did not exist on
arm64 while it did on x86_64.

Anchor moved to the `#ifndef __CYGWIN__` line. Proof, with a real cross-compiler:

```
old tree, aarch64-linux-gnu-g++:  error: 'log2' is not a member of 'fmath'
new tree, aarch64-linux-gnu-g++:  fmath::log2 / exp / log all present
new tree, g++ (x86_64):           fmath::log2 / exp / log all present
```

All 8 mt32emu translation units still compile for arm64.

### F4. `LDP64_IMM` / `STP64_IMM` mis-encoded negative offsets — PROVEN

`vendor/risc_armv8le.h`. Differential against `aarch64-linux-gnu-as`: 62 of 64
macros were already bit-exact; these two were not.

```
ldp x1, x2, [x3, #-64]   header=a93c0861   as=a97c0861
stp x1, x2, [x3, #-64]   header=a8fc0861   as=a93c0861
```

`(imm) << 12` sign-extends past bit 21 and the macro adds rather than ORs, so
the overflow lands in the opcode: **LDP with a negative offset assembled as an
STP** — a load turned into a store — and STP became a post-indexed STP that
writes back to the base register. Latent (both call sites pass +16 and +32), but
in the file nothing else covers.

Both now mask to `0x003f8000`. `BGT_FWD`, `B_FWD`, `CBZ_FWD` and `CBNZ_FWD` got
the same treatment, matching what `gen_fill_branch()` already did. 80 of 80
encodings now match, and 7 deliberate mutations are all caught.

Because the vendored copy is no longer byte-identical to DOSBox-X's,
`ARMV8LE_SHA256` in `versions.sh` was re-pinned with the upstream hash recorded
alongside it.

### F5. "no fallback to the interpreter" was vacuous — PROVEN

`dynamic core not supported`: 0 occurrences in Daum. `CPU:Forcing normal core`:
0. `falling back`: 2, both unrelated — a vsync message, and
`SDL:OPENGL:No support for texturesize of %d, falling back to surface`, which
would have blamed the CPU core for a GL problem.

What DOSBox actually prints is `CPU:Unknown core type %s, switching back to
normal.` (`cpu.cpp:2724`), reached because the `core == "dynamic"` arm only
exists inside `#if C_DYNAMIC_X86 / #elif C_DYNREC`. Both the native and
cross-arch copies now match that.

### F6. Nothing could fail if the dynrec was not used — PROVEN

Three checks looked like they covered it: DYNTEST passes on the interpreter, the
`DRC: code cache` check was `warn`-only, and F5. The DRC check is now a `fail`
on both slices, with the reasoning written down: the LOG_MSG is reachable only
from `CPU_Core_Dynrec_Cache_Init(core == "dynamic")` under `#elif (C_DYNREC)`,
so it proves compiled-in + accepted + allocated. It is a proxy for dispatch, and
says so.

### F7. "runs from a relocated copy" passed on a dyld failure — DEMONSTRATED

`grep -qi dosbox` on output captured with `2>&1`; every dyld error names the
binary path, which contains `dosbox`. Now anchors on
`^DOSBox version [0-9]` and reports loader errors as loader errors.

### F8. The W^X premise was stated twice, contradictorily

`cache.h` said plain RWX is the working path; `verify-bundle.sh` said MAP_JIT is
mandatory. Neither was checked. `cache.h` also still claimed "cache_init below
refuses to continue if the fallback is ever taken" — it does not, and that
sentence described a design the next paragraph had already replaced. Both
rewritten to say what is true: **both paths work, and which one you get is a
property of the signature, not the hardware.** The check requires the line
without prescribing which mapping it names.

### F9. The x86_64 FPU was never tested — and the comment excusing it was false

`verify-bundle.sh` justified skipping it with "configure.ac defines C_FPU_X86 for
x86/x86_64 only, so the Intel slice runs real x87". The `fpu.cpp` patch deleted
that branch; `daum_audit_features()` already knew and reads `fpu.cpp` rather than
`config.h`. The comment was never updated with it.

Added: the same `fputest.com` run under `arch -x86_64`, with the two `RESULT.TXT`
files compared to each other rather than to literals — a literal comparison would
pass if both slices were wrong the same way, which is the exact failure the
softfloat core exists to rule out.

### F10. The FPU was only tested under `core=normal`

`core_dynrec/dyn_fpu.h` decodes the ESC opcodes itself — a second, separate
dispatch path with its own operand handling, exercised by nothing. Added a
`core=dynamic` run compared against the `core=normal` one.

### F11. FPU checks vanished silently without `build/fputest.com`

`info` prints nothing without `--verbose`, so pointing the script at a moved
bundle dropped the checks with no trace but a smaller number in the summary.
Now a `warn` that says how many checks were skipped and how to get them back.

### F12. `/usr/local/opt` was not in the package-manager scan

Intel Homebrew's canonical linkage path, and this bundle ships an x86_64 slice.
`/opt/local/lib` also narrowed to `/opt/local/`, which catches MacPorts include
and bin paths too.

### F13. `run_timed_out()` was defined and never called

"Hung for 60s" and "died in the first second" arrived as the same sentence. They
want different answers — a hang is usually a window or GL context that never
came up, a fast death is a link or entitlement problem. Now distinguished.

### F24. Two regressions I introduced, caught by the build

Recorded rather than quietly patched, because both are the audit's own failure
mode reappearing in the repairs.

**The `-version` check.** I replaced `grep -qi dosbox` with
`^DOSBox version [0-9]` — and Daum's `VERSION` is the string `SVN-Daum`, so the
banner reads `DOSBox version SVN-Daum, copyright ...`. The check failed on a
perfectly good bundle. I had made it too strict in exactly the way the original
was too loose, and only running it found out. Now
`^DOSBox version [^ ]+, copyright`, which matches the banner's shape and still
cannot be produced by a loader error.

**The ne2000 marker.** I picked `"NE2000 ethernet NIC"` by grepping the source
for string literals — and it is inside a *commented-out* line. It was never in
any binary. That is "found 0 reads the same as absent" in a new costume, and it
reported a working unit as missing.

Fixing it properly meant changing the evidence, not the string: see F14.

### F25. My edits dropped verify-bundle.sh's exec bit and broke the build

Run 5 died at `Permission denied` after a full 15-minute build — not on any
check, but on the mode bit of the script that runs them. Editing the file
rewrote it and `-rwx------` became `-rw-------`.

Restoring the bit is the fix that comes undone again. `build-dosbox-daum.sh` now
invokes `bash "$SCRIPT_DIR/verify-bundle.sh"`, so the build does not depend on a
mode surviving whatever touched the file last. Verified both ways: with `+x`
removed the `bash` form runs and direct execution fails.

`lib/daum.sh` already carried `daum_restore_exec_bits()` for exactly this failure
in the *Daum source tree*. The lesson existed in the repo; it had never been
pointed at the repo's own scripts.

### F17. `getLength()` decoded the whole track with a 2352-byte buffer — FIXED

`src/dos/cdrom_image.cpp`. The rewrite itself was necessary and correct —
SDL_sound 1.0.3 genuinely has no duration API (confirmed: no `Sound_GetDuration`,
no `total_time` field, nothing in `Sound_Sample`), and the format premise holds
because the ctor really does request `{AUDIO_S16, 2, 44100}`. Two things were
wrong around it.

**`Sound_Rewind`'s return was ignored.** SDL_sound.h is explicit: *"If this
function fails, the state of the sample is undefined"*, and it fails when the
underlying RWops is not seekable. Every later `read()` would then serve undefined
data with no diagnostic. Now checked, logged, and reported as `-1` like every
other failure in the function.

**The scan ran at 2352 bytes a call** — ~300 000 `Sound_Decode` calls for a full
disc. It now scans at 256 KB and restores the sector-sized buffer afterwards,
for identical output at ~1/100th the call count.

`lastCount` is restored with it, and that is the part worth care: `read()` only
calls `Sound_SetBufferSize` when `lastCount != count`, so leaving `lastCount` at
2352 while the buffer was really 256 KB would make the next `read()` skip the
resize, decode a quarter-megabyte, and copy 2352 bytes of it — advancing the
stream ~100 sectors per read. Silent audio corruption, and precisely the kind of
bookkeeping mismatch that surfaces only when someone plays a CD track.

**The wall-clock cost on real media is still unmeasured** — it cannot be measured
from the audit sandbox. So the scan now times itself and says so above 750 ms,
at `LOG_WARN`, which post-F15 prints regardless of the `[log]` group defaults. It
reports its own cost rather than leaving the question open.

### F18. `SDL_GetDesktopMode` returned the largest mode, not the desktop — FIXED

The shim now asks `SDL_GetVideoInfo()` first, whose `current_w`/`current_h`
sdl12-compat fills straight from `SDL20_GetDesktopDisplayMode()`
(`SDL12_compat.c:2487`) — the actual desktop mode. `SDL_ListModes` remains only
as a fallback, with a comment saying it answers a different question.

Auditing the callers also downgraded the severity and turned up a separate bug.
`GUI_StartUp` already fills `sdl.desktop.full.*` from `SDL_GetVideoInfo()` a few
lines above the first call site, so the shim only decided anything when that
returned NULL. But the line immediately after it reads:

```c
if (!sdl.desktop.full.height) sdl.desktop.full.height = width;   /* <- width */
```

Upstream — it is at line 2299 of the pristine 20150125 tree, and the other call
site in `res_init()` has it right. Reachable when `fullresolution` is `0x0` *and*
`SDL_GetVideoInfo()` returned nothing, which is the same condition that makes the
shim matter at all: you get a square fullscreen resolution. Fixed.

### F14. The Daum-hardware check was substring matching

`voodoo` is a substring of `voodoomem`; `glide` matches `GLIDE2X.OVL` and half
the menu labels; and all of them appear in the built-in `dosbox.conf` template
whether or not the unit compiled.

My first replacement — a log message unique to each unit — was also wrong, twice
over (F24). `ne2000.h` does `#define BX_INFO` and `#define BX_DEBUG` to nothing,
so every message in `ne2000.cpp` is compiled out; and the NE2000 help text that
*is* in the binary lives in `dosbox.cpp`, so it would have proved nothing either.

The check now looks for each unit's `<UNIT>_Init(Section*)` symbol —
`VOODOO_Init`, `GLIDE_Init`, `NE2K_Init`, `INNOVA_Init`, `IDE_Init`,
`DONGLE_Init`. Each exists in exactly one translation unit, the config system
takes its address so it cannot be optimised away, and its presence means that
file was compiled and linked. Every one was validated against the actual shipped
binary rather than guessed from source, and two bogus symbols confirm the check
can still fail. If the binary is ever stripped this fails loudly and says so,
rather than degrading to a guess.

### F15. LOG_WARN was silenced by default — and my own finding was half wrong

I reported that the `debug_gui.cpp` patch silenced every `LOG()` call. It does
not. `debug_gui.cpp:78` reads

```c
if ((d_severity!=LOG_ERROR) && (!loggrp[d_type].enabled)) return;
```

so the 231 `LOG_ERROR` sites always print and the original comment's claim held.
What it did not cover is `LOG_WARN`:

| severity | sites | was |
|---|---|---|
| `LOG_NORMAL` | 251 | gated — correct, this is the noise |
| `LOG_WARN` | 142 | gated — lost |
| `LOG_ERROR` | 231 | always printed |

142 warnings went silent, and warnings are what you want when a game misbehaves
and nothing crashed. Reverting the group default would bring back the 251 that
made the emulator look hung, so the gate is now on severity instead:
`d_severity==LOG_NORMAL`. Both goals from one edit.

### F16. `DEBUG_ShowMsg` truncation clamp was off by one

`vsnprintf(buf, sizeof(buf)-2, ...)` writes at most `sizeof(buf)-3` characters,
so clamping to `-2` made `buf[len-1]` read the terminator: the newline was
appended *after* the NUL and never printed. Clamp corrected to `sizeof(buf)-3`.

### F20. `risc_armv8le.h`'s one diagnostic was format-broken

`LOG_MSG("Big jump %d", len)` with `len` of type `Bits` (64-bit) — the only
diagnostic in 51 KB, reading the wrong half of its own argument. Now `%ld` with
an explicit cast, and it says what the consequence is.

### F21. `physfsFile::Write` fell off the end of a `bool` function

`drive_physfs.cpp`, the truncate-to-zero path — what DOS does when a program
opens an existing file for writing with O_TRUNC on a PhysFS-mounted archive. The
caller read whatever was in the return register. clang had been saying so on
every build (`drive_physfs.cpp:589: non-void function does not return a value in
all control paths`), one line among 1372 warnings, in the same file this script
was already editing eleven lines further up.

### F22. The stale-tree guard did not cover the files I had just changed — found while fixing the rest

`daum_patch_fingerprint()` hashed `lib/daum.sh`, `dbprof.h` and `vendor/openglhq/*`
— **not** `vendor/risc_armv8le.h` and **not** `vendor/fpu_instructions_softfloat.h`.
And `daum_prepare()` installed the AArch64 backend only `if [[ ! -f "$backend" ]]`.

So on a tree that already existed, an edited `vendor/risc_armv8le.h` was never
copied in *and* nothing forced a re-extract: the build would have succeeded while
shipping the old code generator. That is the same failure the stamp exists to
prevent, one directory over — and it would have silently discarded the F4 fix.

Both halves fixed: the fingerprint now covers `$ARMV8LE_LOCAL`,
`fpu_instructions_softfloat.h` and every `.h`/`.cc` under `vendor/bochs-fpu/`
(found rather than listed, because a named list is what missed `fpu_constant.h`
once already); and the backend is re-copied whenever it differs from the vendored
source. Verified by touching each of the four inputs in turn and confirming the
fingerprint moves.

---

## Investigated and closed

### F21 (remainder). Three upstream warnings — INVESTIGATED, none are defects

Analysed rather than patched, because in all three cases the code is correct and
changing it would be churn on a guess.

**`sdlmain.cpp:759` — `!sdl.desktop.want_type==SCREEN_OPENGLHQ`.** Parses as
`(!want_type) == SCREEN_OPENGLHQ`, which looks like a precedence bug. It is not:
`SCREEN_OPENGLHQ` is the *first* member of `enum SCREEN_TYPES`, so it is `0`, and
`(!w) == 0` is `w != 0` is `w != SCREEN_OPENGLHQ` — exactly the intent.
Demonstrated over all six enum values: the two expressions differ in 0 of 6
cases. Accidentally correct, and in this build `want_type` is never
`SCREEN_OPENGLHQ` anyway since `output=openglhq` resolves to `SCREEN_OPENGL`.

**`dos_programs.cpp:2343` — `str_size=="2048,1,60000,0";`.** A comparison whose
result is discarded, where an assignment was plainly meant. Harmless: the
following line is `cmd->FindString("-size",str_size,true)`, and for `type=="iso"`
the parsed `sizes[]` are ignored by `drive_iso.cpp` — which is what the adjacent
comment already says. Making it an assignment would set values nothing reads;
deleting it would cement the typo. Left as-is.

**`dos_programs.cpp:69` — `switch` on a `bool`.** Well-defined C++: `bool`
promotes to `int`, and `case 0:` / `case 1:` cover both values exhaustively. A
style warning, not a defect.

(One real upstream hazard noticed while reading: the `-size` parser writes into
`char number[20]` with no bound check, so a long `IMGMOUNT -size` argument
overflows a stack buffer. Local, self-inflicted, and out of scope for this pass
— noted so it is not lost.)

### F19. openglhq torn down when the mode set then fails — DEMONSTRATED not reachable

`OpenGLHQ_ReleaseForContextChange()` runs unconditionally before
`SDL_SetVideoMode` and always bumps `ohq_context_gen`. If the mode set returns
NULL, `SETMODE_SAVES` leaves `i_width`/`i_height` at the last *successful* mode,
so a later identical `GFX_SetSize` takes the early return, `OpenGLHQ_Init` is
never called again, and openglhq is off with no probe line.

It did need a failing mode set to reproduce rather than a guess. That is now
buildable on demand — see below.

**Investigated and closed: the scenario above is not reachable, and my write-up
of it was wrong.** I had spotted that `i_width`/`i_height` survive a failed mode
set — `if (s == NULL) return s;` runs before they are assigned — and concluded a
later identical `GFX_SetSize` would take the early return and strand openglhq.
What I missed is the *first* term of the same guard:

```c
if (sdl.surface != NULL && height == i_height && width == i_width && ...)
```

All 17 `SDL_SetVideoMode_Wrap` occurrences account for — 15 assign the result to
`sdl.surface`, 1 is the definition, 1 the WIN32 recursive return — so a failure
always lands `sdl.surface = NULL`. `i_*` and `sdl.surface` are written together
on success and neither on failure, so the early return can only fire when `i_*`
genuinely describes the surface being handed back. openglhq cannot be left
released-but-never-reinitialised.

Nothing to fix, so the work went into making sure it stays that way:

- **A post-patch assertion** (`lib/daum.sh`, the `INVARIANT` block) pins the
  three things that make it hold: the guard still leads with
  `sdl.surface != NULL`, `i_*` are still written only after the NULL bail-out,
  and every `SDL_SetVideoMode_Wrap` use still assigns to `sdl.surface` — counted
  rather than named, so a *new* call site is what it catches. Four mutations
  verified, including reordering the guard so the short-circuit no longer
  protects the stale comparison.
- **Fault injection**, because the above is still a static argument about an
  invariant spread over 15 call sites and two functions, and nothing in this
  project had ever executed an error path. `DOSBOX_FAIL_SETVIDEOMODE=<n>`
  discards the n'th mode set's result so the caller sees the NULL a real failure
  produces. Ships inert, same bargain as `SDL_OPENGLHQ_PROBE`, and
  verify-bundle.sh checks the inertness rather than claiming it.
- **A verifier check** that injects a failure and requires openglhq to come back
  afterwards, with eight ordering cases pinned in `tools/check-predicates.sh`.

**It now runs, and it passes** (`recovers from a failed mode set (openglhq
re-initialised afterwards)`). That upgrades this from a static argument to a
demonstrated one: the mode set really is failed, openglhq really has been
released, and a later `GFX_SetSize` really does bring it back. It is also the
first error path this project has ever executed.

**The first run of that check failed, and it was the check.** `n=2` counted all
mode sets, so it landed on GUI_StartUp's initial 640x400 `SDL_RESIZABLE` window
— which DOSBox cannot recover from because it has not started yet. The check
duly reported *"openglhq did not come back after a failed mode set"* and pointed
at the SETMODE_SAVES invariant. True of the run, entirely about the harness, and
aimed at the wrong file. The `INJECTED-NULL` rung carrying dimensions and flags
is what made it a two-minute diagnosis instead of a hunt.

Three changes came out of it, and they are the reason this check is now worth
having:

- the hook counts only mode sets carrying `SDL_OPENGL`, so GL call 1 is the
  start-up capability probe and GL call 2 is the first from `GFX_SetSize`;
- a `gfx-setsize` line must *precede* the injection, or the check reports a
  targeting fault **in verify-bundle.sh, by name**, rather than a bundle defect;
- a `gfx-setsize` line must also *follow* it, because "DOSBox never got the
  chance to recover" and "DOSBox had the chance and did not take it" are
  different findings and only the second is a defect.

The verbatim probe output from the failing run is now a regression case in
`tools/check-predicates.sh`, asserting it reads as mistargeted rather than as a
defect. A stale expectation in that same suite was caught by the suite itself
when the third arm was added.

What the hook simulates is stated in the patch rather than left implicit: it
reproduces *"SDL_SetVideoMode returned NULL"*, which is the input the DOSBox
state machine has to survive — not *"the window could not be created"*. A
faithful failure means letting sdl12-compat run `EndVidModeCreate()` and destroy
the window, which cannot be done on demand without wedging the display. The
invariant under test is entirely DOSBox-side, so discarding the result exercises
exactly the right input and leaves the display recoverable.

**The related open question — is `ctx new` honest? — is also settled, and the
answer is yes.** A real-game probe (Descent to Undermountain, `output=openglhq`)
showed 18 mode sets, 5 full re-inits, 13 reuses, and `ctx new` on every one of
the 5. sdl12-compat 1.2.68 `SDL12_compat.c:6117`:

```c
#elif defined(__APPLE__)
    const SDL_bool destroy_gl_context = SDL_TRUE; /* macOS ("quartz" backend) unconditionally destroys the GL context */
```

Compile-time, unconditional, and no `SDL12COMPAT_*` hint gates it — sdl12-compat
is deliberately reproducing SDL 1.2's quartz backend. So on macOS **every**
`SDL_SetVideoMode` that reaches that branch destroys the GL context, and there is
no early-out for an identical mode either. Three consequences:

- `OpenGLHQ_ReleaseForContextChange()`'s premise is correct on this platform, and
  now has a citation rather than an assumption.
- The `ctx_survived` fast path can only fire when `SDL_SetVideoMode` is *not
  called at all*, i.e. DOSBox's own `SETMODE_SAVES` early return. 13 of 18 is
  that path working exactly as designed.
- The ~2.4–3.6 ms per genuine rebuild (`prog` + `upload`; `build` is already 0
  once the table cache warms) is **irreducible through the SDL 1.2 API on
  macOS**. Nothing to optimise here short of openglhq owning its own GL context,
  which would mean fighting SDL for the window.

A note on a mitigation I nearly recommended and which does not work: `aspect=false`
does *not* collapse the two geometries. The game alternates between a 640x400 and
a 640x480 mode, so with `scaley=1` the outputs are 1280x800 and 1280x960 — still
different, still a real mode set. The geometry changes because the guest changes
video mode, and no config setting hides that.

---

## Left open, deliberately

_None._ F17 and F18 are fixed (above); F21's remainder was
investigated and is not a defect (above).

---

## Things that checked out

Negative results, recorded so they are not re-audited:

- The patcher applies cleanly end to end against a pristine extraction: 28 files,
  no drifted anchors. The fixes changed exactly four files in the output
  (`cache.h`, `debug_gui.cpp`, `drive_physfs.cpp`, `mmath.h`) with no collateral.
- `registerPOD(fpu)` is structurally portable: `FPU_rec` is 272 bytes with
  identical layout on both LP64 slices, no `Bitu` members. Still untested
  end-to-end — the F9 check now at least proves the two slices *compute* alike.
- Nothing outside `src/fpu/` touches `fpu.regs` or `fpu.p_regs`, as the header
  claims.
- `gen_add_imm` and the immediate generators bound their ranges correctly.
- `x18` is defined in `risc_armv8le.h` but never used — no Apple-reserved-register
  violation. Allocated set is r0–r12, r16, r17, r19–r22, r29, r30.
- `dbprof()` is `inline` with a function-local static — one instance across TUs,
  and the banner-count check would catch a regression.
- The `AudioFile` ctor really does request 44100/S16/2.

---

## The OLE2DISP fix, validated on the real DLL

Everything in this document about `FILD`/`FBSTP` and Windows 3.1 OLE rested on
`fputest.com` — a *model* of the check OLE2DISP.DLL performs. On 2026-07-29 the
real thing was measured, running Word 6 under Windows 3.1 and embedding a
WordArt 2.0 OLE object:

```
[fpu] ops=3221897
[fpu] anomalies: IE=0 DE=0 ZE=0 OE=0 UE=0 PE=0 SF=0 ES=0
  FILD64                  1
  FBST                    1
  FBLD                    0   <-- not exercised
  FIST64                  0   <-- not exercised
  FLDCW             1610939
  FCLEX             1610939
```

`FILD` of a 64-bit integer, once. `FBSTP` to packed BCD, once. One direction,
one execution — exactly the sequence OLE2DISP.DLL 2.3.3027.1 runs at load to
detect a reduced-precision FPU. Word started, OLE enumerated its servers, and
WordArt embedded. **The check the entire SoftFloat core was written to pass has
now passed against the actual DLL rather than a reproduction of it.**

`SF=0` is load-bearing here for the first time. The documented failure mode is
"the DLL pops an extra stack entry", and until the stack-fault detection added
one build earlier, this core recorded nothing at all for that — `SF` could only
ever have come from `FPU_FCOM`. On the previous binary this zero would have been
vacuous.

**Attribution is inferred, not proved.** The histogram counts operations, not
call sites, so "that `FBST` was OLE2DISP's" is an inference — a strong one,
given the count is exactly 1 in an OLE-heavy session and matches the documented
sequence in both operations and direction, but the instrument cannot say so
itself. The cheap control is a Windows 3.1 session that reaches Program Manager
and exits without launching an OLE application; if `FBST` stays 0, Word is what
produces it.

**A separate surprise, worth recording.** 1,610,939 `FLDCW` and 1,610,939
`FCLEX` — *exactly* 1:1 — against **six** arithmetic operations in the whole
session. State management is **99.9998%** of all FPU activity, and the counts
reconcile exactly to the reported total. Windows 3.1 touches the FPU constantly
whether or not anything is computing, almost certainly WIN87EM.DLL's
save/restore. It means control-word handling — the precision-control bits this
core honours and the stock cores ignore — is on a path executed a million and a
half times per session, while actual arithmetic is rounding error.

## Asking what a workload actually exercised

`DOSBOX_FPU_PROFILE=<path>` writes a coverage histogram plus exception counters.
It exists because a clean run proves only that nothing was *unimplemented* — it
says nothing about whether the repaired paths were reached, and a fix no
workload touches is a fix no workload tests.

```bash
DOSBOX_FPU_PROFILE=/tmp/fpu.txt \
  dist/dosbox-daum.app/Contents/MacOS/dosbox-daum -conf yourgame.conf
cat /tmp/fpu.txt
```

Counters live at the entry points in `fpu_instructions_softfloat.h`, not in
`fpu.cpp`'s ESC dispatchers — under `core=dynamic` those are bypassed entirely
and would have reported zero for the default core. One hook in `SF_flags()`
covers every exception for every operation, on both cores, because both now
include that header (see F23).

**A zero is the dangerous reading**, and the reason this has a build-time
assertion. An op named in `enum DBFpuOp` with no hook prints `0`, which is
indistinguishable from "this workload never executed it". Demonstrated:
deleting the FPATAN hook leaves the whole FPU suite passing and prints
`FPATAN 0 <-- not exercised`. So `daum_patch_sources()` compares named ops
against hooked ops and fails the build on a mismatch, naming the unhooked one.
Three mutations verified: a hook deleted in the header, the cross-file `FLDCW`
hook deleted in `fpu.cpp`, and an op added to the enum with no hook.

`verify-bundle.sh` then checks the hooks actually fire — `fputest.com` is a
known workload, so `FILD64`, `FBST`, `FPREM`, `FPREM1` and a masked overflow
must all be non-zero — and that the whole thing is inert with the variable
unset.

**That check failed on its first run, and the instrument was wrong.**
`dbfpu_dump()` was called only every 2,000,000 operations; `fputest.com`
executes a few hundred, so no file was ever written. The histogram reported
nothing on exactly the workload the verifier uses.

The reason my host testing missed it is the part worth keeping: I had validated
the counters with `DOSBOX_FPU_PROFILE_EVERY=1`, which forces a dump per
operation. **The harness exercised a configuration the product never uses.**
Every number it produced was real, and none of it covered the default path.

Fixed with `atexit(dbfpu_dump)` for short runs, plus a period lowered to 200,000
ops and throttled to at most one dump per wall second so a game doing millions of
operations per second does not rewrite the file hundreds of times a second. Both
paths are now tested, and the short-run case is tested *at defaults*.

## What you need to run

Nothing below can be done from the audit sandbox — the build is macOS-only.

Edit in `~/Claude/Projects/wine/dosbox-daum`; that tree is copied to
`~/Downloads/dosbox-daum` before each build. `build/` and `dist/` exist only in
Downloads, so build logs and the shipped binary are read from there.

```bash
# after copying Projects -> Downloads
cd ~/Downloads/dosbox-daum

# lib/daum.sh, vendor/risc_armv8le.h and vendor/fpu_instructions_softfloat.h all
# changed, so the fingerprint has moved and daum_prepare() will re-extract on its
# own.  Forcing it is still cheaper than wondering.
rm -rf build/sources/daum-*
./build-dosbox-daum.sh

# `bash`, not `./` -- see F25.  An edit that rewrites the file drops its +x, and
# the build used to die on that after 15 minutes of work.
bash verify-bundle.sh --verbose
```

Current state: **51 / 0 / 0**. Every check that has ever failed on this bundle is
fixed and has a regression case; every check that has failed on the *harness* has
a discriminator that names the harness instead.

To watch the mode-set failure path by hand:

```bash
# n counts OpenGL mode sets issued from GFX_SetSize; 1 is the first one.
SDL_OPENGLHQ_PROBE=/tmp/fail.txt DOSBOX_FAIL_SETVIDEOMODE=1 \
  dist/dosbox-daum.app/Contents/MacOS/dosbox-daum -conf yourgame.conf
grep -nE 'INJECTED-NULL|returned NULL|^gfx-setsize|^init |^render' /tmp/fail.txt
```

The `INJECTED-NULL` line names which mode set was sacrificed; everything after it
is the recovery. `DAUM_VERIFY_FAIL_MODESET=<n>` changes which one the verifier
picks, if 2 turns out to be past the end of a short run.

Four things to look at specifically:

1. **`FPU: core=dynamic agrees with core=normal`** — this is F23. It failed last
   run and is the reason the FPU work was not actually shipping. If it still
   fails, the `dyn_fpu.h` patch did not take.
2. **`all Daum hardware units linked in`** and **`runs from a relocated copy`** —
   both were my regressions (F24) and both were verified against the real binary
   and the real banner text, so they should pass now.
3. **`drive_physfs.cpp:589`** should be gone from `build/logs/daum.arm64.log`:
   `grep -c 'drive_physfs.cpp.*Wreturn-type' build/logs/daum.arm64.log` → 0.
4. **`x86_64: FPU results identical to arm64`** passed last run under
   `core=normal`. Worth noting it passed *while F23 was live* — both slices were
   equally wrong under `core=dynamic`, and agreement is not correctness. The
   F10 check is what supplies the correctness half.

Two things this build will newly refuse to do, by design:

- `daum_audit_features()` now `die`s if `fpu.cpp` and `dyn_fpu.h` select
  different FPU cores, rather than reporting on one of them.
- `daum_patch_sources()` sweeps for any *third* file selecting an FPU core and
  fails naming it.

Host-side harnesses, runnable anywhere with the right toolchain:

```bash
# FPU: 39 assertions, needs only a C++ compiler
cd vendor/bochs-fpu && cp ../fpu_instructions_softfloat.h .
g++ -std=c++11 -O2 -w -I . -I test -I shim -I softfloat3e/include \
    -I softfloat3e/8086-SSE -I x87 \
    test/test.cc x87/*.cc softfloat3e/*.cc softfloat3e/8086-SSE/*.cc -o test && ./test

# AArch64 encodings: needs an AArch64 assembler, so run it in a Linux container
#   apt install binutils-aarch64-linux-gnu
bash tools/armv8-encoding-check/run.sh

# verify-bundle.sh's decision logic: needs nothing
bash tools/check-predicates.sh
```
