# OpenGL-HQ interpolation-table equivalence check

The interpolation table is the one part of OpenGL-HQ that is pure geometry with
no OpenGL in it, so it can be verified off-device.

`table_dump.c` runs the routines exactly as extracted from upstream's
`SDL_ohqthread.h`; `mine.c` runs the copies that live in
`vendor/openglhq/openglhq.cpp`. Both dump the full 4 MB table and the two are
compared byte for byte.

This exists because a first attempt *reimplemented* `intersect_any()` and
`setinterp()` from their call sites rather than copying them. It compiled, ran,
and produced a plausible-looking table that differed from upstream in **58% of
its bytes** — the sort of error that shows up as "the scaler looks a bit off"
rather than as a failure. The geometry has to be copied verbatim.

    gcc -O2 -o table_dump table_dump.c -lm && ./table_dump
    gcc -O2 -o mine mine.c -lm && ./mine
    cmp upstream.bin mine.bin && echo identical

Verified identical at 640x400->1920x1200, 320x200->1280x800,
640x480->2560x1440 and 800x600->800x600 (1:1).

## `cache-test.sh` — the table cache

`build_interp_texture()` caches built tables, because DOSBox calls
`GFX_SetSize` far more often than the geometry changes: one real 640x480
session produced 18 `OpenGLHQ_Init` calls alternating between 1067x960 and
1280x960, each rebuilding 4 MB of geometry. Measured cost of a rebuild, `-O2`:
**~9 ms**.

The saving is the easy part. The hazard is a slot handing back a table built
for a *different* geometry — which looks like "the scaler is a bit off", never
like a failure. That is the same failure mode that made this directory
necessary, so the cache gets the same treatment:

    ./cache-test.sh

It slices the real code out of `vendor/openglhq/openglhq.cpp` at build time
rather than keeping a copy — `mine.c` is a copy and has to be re-diffed by hand
whenever the original changes; a slice cannot drift. It checks every upload
byte-for-byte against a freshly built reference, across the cold case, the
observed 18-call A/B sequence, and eviction with a third geometry.

The region is delimited by `cache-test slice begin` / `... slice end` comments.
Explicit markers, because the first version keyed on the name of the first
function in the region and on the next horizontal-rule comment — either of
which moving would have sliced the wrong thing without saying so.

## Reading the init breakdown

`OpenGLHQ_Init` reports a per-phase timing on the probe line:

```
init ok 640x480 -> 1280x960, ..., table cached, ctx SURVIVED, submit us:
  entry=.. tex=.. prog=.. fbo=.. build=.. upload=.. total=..
```

Two fields carry the open question. `ctx SURVIVED` means no real
`SDL_SetVideoMode` happened since the previous init — `SDL_SetVideoMode_Wrap`
short-circuited, the GL context was never replaced, and everything the teardown
destroyed was still valid. A run of those is the case for skipping the teardown
entirely rather than merely making it cheaper.

`submit` vs `synced` says what the numbers mean. GL is asynchronous, so by
default these are CPU-side submission costs — which is the right default,
because submission is what blocks DOSBox's main loop. `SDL_OPENGLHQ_TIME_SYNC=1`
inserts a `glFinish` and gives the true cost, at the price of a stall the code
would not otherwise cause.

## The teardown plan

`ohq_plan()` decides what `OpenGLHQ_Init` does: reuse everything, delete then
rebuild, or rebuild without deleting. It is a pure function purely so this can
enumerate its cases rather than re-type the condition, because the two wrong
answers are wrong in opposite and silent directions:

- `REBUILD_FRESH` when the context actually survived → every GL object leaks.
- `REBUILD_AFTER_DELETE` when it did not → deletes names that by then belong to
  DOSBox's own texture and display list, in the *new* context.

Each case changes exactly one field. An earlier version of the table changed two
at once and let a mutation through — the condition had dropped a field and the
test still passed, because the other changed field carried it.

### What mutation testing says it can and cannot catch

Deliberately broken copies, to confirm the test is not passing vacuously:

| mutation | caught |
|---|---|
| cache key ignores the output width | yes — 5 failures |
| cache never stores (always a miss) | yes — 1 failure |
| plan ignores `ctx_survived` | yes — 2 failures |
| plan never deletes | yes — 5 failures |
| reuse ignores the `active` flag | yes — 1 failure |
| reuse drops any one of the four size fields | yes — 1 failure each |
| slot published as valid before the build finishes | **no** |

The last is honest rather than alarming: `build_interp_data()` cannot fail and
nothing re-enters the cache, so the two orderings are genuinely
indistinguishable from outside. The code still invalidates first, because the
alternative publishes a key over bytes that do not match it yet — and if that
ever did become reachable it would be silent.
