# Session prompt — extensive audit of the Daum build

Copy everything below the line into a new session.

---

I want the DOSBox Daum build in `~/Claude/Projects/wine/dosbox-daum` audited
extensively for hidden defects. Build output and patched sources live at
`~/Downloads/dosbox-daum/` (you may need to request access to that folder).

## What this is

A build system that produces a fully self-contained universal (arm64 + x86_64)
macOS app bundle of DOSBox SVN Daum 20150125, targeting macOS 11.0+, with no
Homebrew or MacPorts involvement. `build-dosbox-daum.sh` builds a toolchain,
nine runtime libraries, and DOSBox itself; `verify-bundle.sh` runs 47 checks
against the result. It currently reports **47 checks, 0 warnings, 0 failures**.

Daum's sources are patched *in place* by an embedded Python program inside
`lib/daum.sh` (between the `PYEOF` markers) — roughly 30 files, each edit a
regex substitution that aborts loudly if it does not match exactly once.

## Why I'm asking

The last stretch of work found roughly a dozen defects, and **every one of them
had been sitting behind a check that reported success or said nothing at all.**
A representative sample:

- A profiler that was `static inline`, so every translation unit got a private
  copy of the state and the report always read zero.
- A `strings` scan aimed at the launcher stub instead of the DOSBox binary —
  "found 0" read identically to "feature absent".
- `verify-bundle.sh` exporting `SDL_VIDEODRIVER=dummy`, which has no OpenGL, and
  then reporting for four rounds that OpenGL wasn't working. Every verdict was
  true; all of them were about the harness.
- `softfloat_exceptionMasks` hardcoded to 0, so SoftFloat took the x87 wrap
  branch on every overflow and returned a wrapped finite number where DOS
  expects `+INF`. Silently wrong arithmetic, no diagnostic anywhere.
- `FPREM` aliased to `FPREM1` in a rewrite, breaking C's `fmod()` — a
  **regression against the stock code**, which had it right.
- `OpenGLHQ_Shutdown()` on every `GFX_SetSize`, resting on a premise
  (`SDL_SetVideoMode` always replaces the context) that `SETMODE_SAVES` makes
  false 13 times out of 18.

The pattern is not "bugs exist". It is that **the thing meant to detect the bug
was itself broken, or was measuring something adjacent to the question.** Assume
more of these are present.

## What I want

1. **Survey and triage first.** Do not start fixing. Work through the codebase
   and report ranked findings: what is wrong, how confident you are, and how you
   would prove it. I will pick what to pursue.
2. **A finding must be demonstrable.** Prefer a test that fails now and passes
   after the fix. Where you cannot demonstrate something, say so explicitly and
   label the confidence — do not present reasoning as if it were evidence.
3. **Audit the checks as hard as the code.** For every existing check in
   `verify-bundle.sh` and every post-patch assertion in `lib/daum.sh`, ask: can
   this fail? Can it distinguish the case it claims to test from its neighbours?
   Is it looking at the artifact it thinks it is? Several of the bugs above were
   found only by breaking the code deliberately and noticing the test stayed
   green.

## Questions that found things before

Apply these to each of the ~30 patch sites and each check:

- **What premise does this rest on, and is it still true?** Several patches were
  written against an assumption that a later change invalidated.
- **Does this hardcode something that should come from the guest?**
  `softfloat_exceptionMasks = 0` and `FPU_SET_C2(0)` were both of this shape.
- **Did the rewrite lose behaviour the stock code had?** Compare against Daum's
  original in the vendored archive, not against intent.
- **Is the diagnostic being discarded?** Upstream logged
  `"Could not initialize OpenGL"` and threw away `SDL_GetError()`; printing it
  ended a four-round investigation instantly.
- **Does the harness change the thing being measured?**

## Methods that work here

- **Read the real source.** The pristine tree is vendored as
  `vendor/dosbox-svn-daum-20150125.7z`. In the sandbox:
  `pip install py7zr --break-system-packages`, then extract and grep. Do not
  reason about DOSBox internals from memory.
- **Dry-run the patcher end to end.** Extract the 7z to a temp dir, copy
  `vendor/openglhq/*` into `src/gui/`, slice the Python program out of
  `lib/daum.sh` between `PYEOF` markers, and run it against the extraction. It
  applies ~30 files in a second and fails loudly on any anchor that has drifted.
  This is far stronger than eyeballing regexes.
- **Host harnesses over copies.** `vendor/bochs-fpu/test/` compiles the real FPU
  header with stubbed guest memory. `tools/ohq-table-check/cache-test.sh` slices
  the real function out of `openglhq.cpp` at build time rather than keeping a
  copy that can drift. Extend these rather than writing parallel versions.
- **Mutation testing.** Break the code deliberately and confirm the test
  notices. This caught a test of mine that changed two variables at once and so
  passed even with one of them removed from the condition.
- `~/Downloads/dosbox-daum/build/sources/daum-20150125/` holds the patched tree.
  Glob reaches it; Grep and Read need folder access granted.
- Incremental rebuild is ~2 minutes. Full re-extract:
  `rm -rf build/sources/daum-* && ./build-dosbox-daum.sh`.

## Areas most worth suspicion

Ordered by how little verification they have relative to their importance:

1. **`risc_armv8le.h`** — the AArch64 dynamic-recompiler backend, vendored from
   DOSBox-X. The single most important input to the build and the least tested.
   Nothing verifies its code generation beyond "DOS commands run".
2. **The ~25 patched files nobody has revisited** — `dbopl.cpp`, `dma.cpp`,
   `ide.cpp`, `memory.cpp`, `opl.cpp`, `pic.cpp`, `nullmodem.cpp`,
   `voodoo_data.h`, `voodoo_opengl.cpp`, `cdrom_image.cpp`, `drive_physfs.cpp`,
   `debug*.cpp`, `midi_synth.h`, `mmath.h`, `cpu.cpp`, `core_dynrec.cpp`,
   `cache.h`. Each was written for a reason that may no longer hold.
3. **Save states.** `registerPOD(fpu)` is *claimed* to be portable between
   slices now that both use the same 80-bit layout. Never empirically tested.
4. **The FPU entry points without tests.** 69 total; roughly a dozen are
   covered. `FSCALE`, `FXTRACT`, `FBLD`, the compares and the transcendentals'
   edge cases are untested.
5. **The x86_64 slice**, which has only ever run under Rosetta. There is an
   unexplained `INT 3` storm with `core=dynamic` under repeated small programs,
   believed to be a Rosetta stale-translation artifact but never confirmed.
6. **Daum-specific hardware** — voodoo, ne2000, innova, dongle, IDE. Verified
   only as "the config property exists in the binary".

## Style

Be direct and concise. Tell me what is broken without softening it, including
where the breakage is something you or a previous session introduced. I would
much rather hear "this is wrong and here is the proof" than a hedge.
