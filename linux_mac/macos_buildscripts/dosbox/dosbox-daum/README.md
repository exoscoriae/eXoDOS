# Portable DOSBox Daum for macOS 11+

Builds `dosbox-daum.app` — a self-contained, relocatable universal bundle of
DOSBox SVN Daum 20150125, running **natively** on both Intel and Apple Silicon
with the dynamic recompiler working on each. No Rosetta, no Homebrew, no
MacPorts.

```
./build-dosbox-daum.sh
./verify-bundle.sh dist/dosbox-daum.app
```

Output: `dist/dosbox-daum.app`, executable `Contents/MacOS/dosbox-daum`.

---

## The actual problem

Daum was last released in January 2015 and was never ported to macOS. Three
things stand between it and a native Apple Silicon binary.

**1. There is no AArch64 code generator.** Daum's `core_dynrec` has backends for
x86, x86_64, 32-bit ARM and MIPS. Nothing emits AArch64, so `core=dynamic`
cannot work natively on Apple Silicon — it would silently fall back to the
interpreter, which is the entire problem we are trying to escape.

The fix is not to write one. DOSBox-X carries `risc_armv8le.h`, a complete
1,250-line AArch64 backend implementing exactly the `gen_*`/`DRC_*` interface
Daum's dynrec expects, GPLv2 like Daum, and exercised daily on Apple Silicon and
Raspberry Pi. The build grafts it in and wires up `core_dynrec.cpp`,
`configure.ac` and `Makefile.am` around it.

**2. W^X.** Apple Silicon refuses to map memory writable and executable at once
unless the process is entitled for it. The bundle is signed with
`allow-jit` and `allow-unsigned-executable-memory`, and the patched cache
allocator asks for plain RWX first, falling back to `MAP_JIT` with
`pthread_jit_write_protect_np()` toggling if that is refused.

**3. 16 KB pages.** Daum aligns its code cache to a hardcoded 4096, which is not
a valid `mprotect` granularity on Apple Silicon. The patch raises
`PAGESIZE_TEMP` to 16384 — a valid granularity on both 4 KB and 16 KB systems,
costing at most 16 KB of address space on Intel.

I-cache invalidation, the other classic AArch64 JIT hazard, is already handled:
DOSBox-X's backend calls `__builtin___clear_cache()` in `cache_block_closing()`,
which clang lowers to `sys_icache_invalidate()`.

## SDL

Daum is an SDL 1.2 program, and SDL 1.2.15 predates ARM64 and leans on macOS
APIs Apple removed years ago. Rather than resurrect it, the build stacks
**sdl12-compat** on **SDL2**: the SDL 1.2 API is provided unchanged, so Daum's
source needs no edits, while windowing, input and audio go through a modern
Metal-capable backend. `SDL_net` is the classic 1.2 series, which builds against
sdl12-compat unmodified.

DOSBox's `configure` locates SDL through `sdl-config`, which sdl12-compat does
not always install; the build synthesises one rather than letting configure
decide SDL is missing and fail much later with a misleading message.

## Preserving Daum's features

Daum carries hardware emulation no other fork reproduces, so nothing here is
allowed to regress it. Two properties make that hold.

**Every change is additive.** The AArch64 backend is a new file plus an
`#elif C_TARGETCPU == ARMV8LE` branch that is unreachable on any other target.
The `configure.ac` edits add a CPU case and widen one `if`. No Daum code is
removed or rewritten. On x86_64 the result is upstream Daum with a single
difference — `PAGESIZE` 4096 → 16384, which only over-aligns the code cache.

**The distinctive units are compiled unconditionally.** Reading
`src/hardware/Makefile.am`: `voodoo.cpp`, `voodoo_emu.cpp`,
`voodoo_interface.cpp`, `voodoo_opengl.cpp`, `voodoo_vogl.cpp`, `glide.cpp`,
`ide.cpp`, `ne2000.cpp`, `pci_bus.cpp`, `hardopl.cpp`, `innova.cpp`,
`dongle.cpp` and `ps1_sound.cpp` are all in `SOURCES`, not behind a configure
switch. They cannot be lost to a failed library probe.

The real hazard is elsewhere: Daum's `configure.ac` never *fails* on a missing
optional library — it prints `AC_MSG_WARN` and continues. A build can therefore
complete, look healthy, and have silently dropped a feature. Three were doing
exactly that in an earlier version of this script:

* **`C_PRINTER`** needs `freetype-config`, which FreeType removed in 2.9.1. The
  build now synthesises a shim, the same way it does for `sdl-config`.
* **`C_SDL_SOUND`** (compressed CD-DA — ogg/mp3 track images) needs SDL_sound.
* **`C_HAVE_PHYSFS`** needs PhysFS.

So the build now audits the generated `config.h` and **hard-fails** if any
required feature came out disabled, naming it and pointing at the `WARNING`
lines in the log. `verify-bundle.sh` then independently confirms the shipped
binary contains the `voodoo`, `voodoomem`, `glide`, `ne2000`, `innova` and
`dongle` config properties, and that it links `OpenGL.framework` — Voodoo is the
one distinctive feature that *is* conditional, compiled only when `C_OPENGL` is
defined, which `configure.ac` does unconditionally for darwin.

### output=openglhq

Available, and it is the GPU implementation — not a software scaler standing in
for one. Getting there needed a different approach from upstream's, though.

**Upstream openglhq is not a DOSBox renderer.** Daum selects it with

```c
putenv("SDL_VIDEODRIVER=openglhq");
```

because `openglhq.patch` patches **SDL 1.2**, not DOSBox: it adds a video driver
to SDL's `SDL_VideoDevice` bootstrap that transparently intercepts any 2D SDL
program, then hooks each platform's *parent* driver (quartz on macOS, windib/dx5,
x11). About 2,900 lines of it — `SDL_ohqthread.h` 1127, `SDL_ohqvideo.c` 581,
plus the shaders and tables.

None of that can work here. sdl12-compat reimplements the SDL 1.2 *API* over
SDL2 and has no video-driver layer to plug into, and replacing it with a patched
real SDL 1.2 is not a way out either — 1.2.15 dates from 2012, has no ARM64
support, and its quartz driver uses macOS APIs Apple has removed. Porting *that*
is larger than this whole project, which is why sdl12-compat exists.

**What survives the change of host is the part that does the work.** The
scaler itself is three `!!ARBfp1.0` fragment programs and a 4096-entry
edge-classification table, and neither cares how the window was created.
`src/gui/openglhq.cpp` drives them straight from DOSBox's own OpenGL output
path:

```
texture[0]  emulator framebuffer, GL_NEAREST
     |  pass 1  ->  FBO 0        edge classification
texture[1]
     |  pass 2  ->  FBO 1        interpolation selection
texture[2]
     |  pass 3  ->  screen       samples texture[0], texture[2]
                                 and the 256x16x256 3D factor table
```

So `output=openglhq` is a normal `SCREEN_OPENGL` window with a different
`GFX_EndUpdate`. Everything downstream — fullscreen, save states, the aspect
clip rect — keeps seeing `SCREEN_OPENGL`, which is what keeps the change small:
none of Daum's `SCREEN_OPENGLHQ` special cases become reachable, and they are
all Windows-shaped (menu teardown, `DestroyWindow`, `SDL_VIDEODRIVER`). The
build asserts that nothing selects that type any more.

Requirements are `GL_ARB_fragment_program`, `GL_EXT_framebuffer_object`,
`GL_ARB_multitexture` and 3D textures — all present in the OpenGL 2.1
compatibility profile macOS still ships. If any of them is missing, or a program
fails to compile, or an FBO comes back incomplete, `OpenGLHQ_Init` cleans up and
returns false, `OpenGLHQ_Active()` stays false, and every dispatch point falls
through to the stock display-list path. You get plain `output=opengl` and a log
line, not a crash.

Two knobs carried over from upstream, both read from the environment:
`SDL_OPENGLHQ_STATIC` (default 10) and `SDL_OPENGLHQ_DYNAMIC` (default 33).

#### The parts that had to be copied rather than written

**The interpolation table.** The 4096-entry table classifies edge patterns; the
geometry that turns each entry into per-corner weights is subtle enough that an
earlier attempt to reimplement it from its call sites produced a table differing
from upstream in **58% of its bytes** — an error that shows up as "the scaler
looks a bit off", not as a failure. It is now copied verbatim from
`SDL_ohqthread.h` and checked byte-for-byte by `tools/ohq-table-check`, which
builds both versions off-device and `cmp`s 4 MB of output.

**The coordinate conventions.** These are the two things most likely to be wrong
in a renderer that has been written but never run, and both are silent:

* Passes 1 and 2 render at **`srcw` x `srch`**, not `texsize` x `texsize`. The
  quad spans texcoords `0..tex_w` and the next pass reads back over that same
  range, so the rasterised area must be exactly the `tex_w` fraction of the FBO:
  `x = (u/tex_w) * viewport_w` has to equal `u * texsize`, giving
  `viewport_w = srcw`. A `texsize` viewport stretches the source across the whole
  FBO and pass 2 then samples only its top-left corner.
* Pass 3 **flips V**; passes 1 and 2 do not. Passes 1 and 2 are texture→texture
  and must be an identity in texture space or the next pass reads the wrong
  neighbourhood. Pass 3 is texture→screen and has to match DOSBox's own display
  list, which puts `v=0` at the top because the emulated framebuffer's row 0 is
  the top of the DOS screen. Reusing the pass-1 quad mirrors the picture.

Pass 3 also restores DOSBox's clip rectangle rather than the full drawable, so
plain `opengl` and `openglhq` put the picture in the same place, letterbox bars
included.

#### The render scaler: deliberately left alone

openglhq is a *magnifying* scaler — it reconstructs edges from the original
pixels — so in principle it wants the guest framebuffer rather than something
`RENDER` has already enlarged. Daum agrees, and sets `scaler=hardware2x`
whenever openglhq is active.

This build does **not** do that. An implementation was written, debugged through
several rounds, and then removed for want of any measurable benefit. The
reasoning is recorded here because it is not obvious and the temptation to
re-add it is real.

**Daum's own two call sites are dead.** They use `SetVal()`, which opens

```c
if (dos_kernel_disabled)
	return;
```

and the DOS kernel is down both during config parsing and during a pre-boot
output switch. Copying the mechanism faithfully reproduces its deadness.

**`hardware2x` is size 4, and that collides.** `RENDER_Reset` only honours a
hardware scaler when `GFX_GetBestMode` reported `GFX_SCALING`. Otherwise it logs
*"Output does not support hardware scaling, switching to normal scalers"*,
clears `render.scale.hardware` — and keeps the size. Walking the branch order
for a `dblh && dblw` mode with the flag cleared:

| scaler | size | becomes |
|---|---|---|
| `hardware_none` | 1 | `ScaleNormal1x` |
| **`hardware2x`** | **4** | **`ScaleNormal4x`** |
| `hardware3x` | 6 | `ScaleNormal1x` |
| `hardware4x` | 8 | `ScaleNormal1x` |
| `hardware5x` | 10 | `ScaleNormal1x` |

Size 4 is also `normal4x`'s size, so Daum's choice can quadruple the frame in
software — the opposite of handing openglhq the raw image. It is the only value
that collides, and it is also Daum's **default**, reachable with no `[render]`
section at all.

**A guard on the runtime flag self-retriggers.** `SetVal` runs `ExecuteInit` →
`RENDER_Init` → `RENDER_Reset`, which clears `render.scale.hardware` again — so

```c
if (sdl.opengl.hq && !render.scale.hardware)   /* WRONG */
    SetVal("render","scaler","hardware_none");
```

is made true by the call it guards. The pair loops, one log line per iteration:
2.8 GB in 180 seconds, measured.

**And none of it demonstrably helped.** `scaler=normal2x` only engages on
`dblw && dblh` modes, and `doublescan=true` expands exactly those into the full
VGA raster *before* any scaler runs — so on every game tested there was nothing
left to override. Commander Keen 4, natively 320×200, reached openglhq as
`640x480` with `dblw`/`dblh` already resolved. Descent to Undermountain is
natively 640×480 and never scaled either way. Making the override matter
requires `doublescan=false`, which breaks aspect correction on those same
200-line modes.

If a case ever appears where openglhq is visibly working on pre-scaled pixels,
revisit it with `hardware_none` (size 1, degrades to `ScaleNormal1x`) and a
guard on the **configured property**, never on the runtime flag.

#### `doublescan` decides what openglhq actually receives

Daum adds a `[render] doublescan` option that vanilla DOSBox has no equivalent
for, and **defaults it to `false`**:

> If set, doublescanned output emits two scanlines for each source line, in the
> same manner as the actual VGA output (320x200 is rendered as 640x400). If
> clear, doublescanned output is rendered at the native source resolution.

With `false`, a 200-line mode reaches the renderer with its height halved but
its width untouched, and `aspect=true` then computes a ratio against a raster
that no longer exists. Commander Keen 4 came out at a clip of `267x960` — a tall
slot roughly a fifth of the width it should be. `doublescan=true` restores the
real VGA raster and the geometry is correct again. This only affects 200-line
modes; 640×480 games never see it.

The catch is that it also decides what openglhq is handed:

| `doublescan` | 320×200 game reaches openglhq as | geometry |
|---|---|---|
| `true` | `640x480` — the VGA raster, already line-doubled | correct |
| `false` | `320x200` — the original art | wrong on 200-line modes |

So on Daum you cannot currently have both. `doublescan=true` is the right
setting, and the cost is that the edge detector runs over pixels VGA already
duplicated rather than over the original pixel art, which noticeably reduces how
much the scaler can reconstruct. Games that are natively 640×480 or 320×240 are
unaffected — they have no doublescanned raster to expand.

#### Interactions worth knowing

`openglhq` uploads from main memory, so it is incompatible with the PBO path,
which hands out a mapped GL buffer instead of `sdl.opengl.framebuf`. The build
forces PBO off when `openglhq` is selected. In practice this changes nothing:
DOSBox leaves PBO off unless `-disable_vga_comp` is given.

Window resizes and fullscreen toggles go through `GFX_SetSize`, which tears the
scaler down against the old GL context and rebuilds it against the new one. The
interpolation table is a function of the source:output *ratio*, so it is rebuilt
too — about 10 ms, which is why that belongs on resize and never per frame.

The software scalers remain available and unchanged: `output=opengl` with
`scaler=hq3x` or `scaler=xbrz` still works if you prefer the CPU versions.

### Glide passthrough

`glide.cpp` already has a macOS path — it `dlopen`s `libglide2x.dylib`. So
passthrough to a real Glide wrapper works if you supply one; building OpenGlide
as `libglide2x.dylib` is out of scope here. For a 3Dfx game like Descent to
Undermountain, Daum's *built-in* Voodoo emulation (`voodoo=opengl`) is the path
that needs no external library, and it is enabled.

## What's bundled

| | |
|---|---|
| DOSBox | SVN Daum 20150125, `core=dynrec` on both architectures |
| Video/input | SDL2 + sdl12-compat |
| Audio | CoreAudio, munt (MT-32/CM-32L), FluidSynth (SoundFont MIDI) |
| Network | SDL_net — IPX tunnelling, null-modem, dial-up emulation |
| Capture | FFmpeg (LGPL configuration only) |
| Graphics | 3dfx Voodoo emulation over OpenGL; OpenGL-HQ shader scaler (`output=openglhq`) |

Everything not provided by macOS is compiled from source at
`MACOSX_DEPLOYMENT_TARGET=11.0` and bundled.

## The vendored source

`vendor/dosbox-svn-daum-20150125.7z` is a verified copy of the complete Daum
tree (473 files), used by default. It is checksum-pinned in `versions.sh` and
verified before extraction.

This is not belt-and-braces — upstream genuinely cannot be relied on:

* The GitHub **tag** `20150125` points at a commit containing only `LICENSE`.
  `.../archive/refs/tags/20150125.tar.gz` downloads and extracts perfectly and
  gives you a 7 KB directory with no source in it.
* The branch head has the real tree but is a moving reference.
* ykhwong's own site, which hosted the releases and patches, has been offline
  for years.

So the build works with no access to GitHub at all, and preflight skips the
Daum URL when the vendored copy is in use. To override:

```bash
DAUM_LOCAL_ARCHIVE=              ./build-dosbox-daum.sh   # force the download
DAUM_LOCAL_ARCHIVE=/path/to.7z   ./build-dosbox-daum.sh   # use another copy
DAUM_LOCAL_SHA256=               ./build-dosbox-daum.sh   # skip the checksum
```

The checksum matters more than it looks: it is the archive `lib/daum.sh`'s six
source edits were written and tested against. A mismatch means those patches
are no longer known to apply, so the build stops and says so.

## Requirements

* Xcode Command Line Tools (`xcode-select --install`). Full Xcode is *not*
  needed — unlike the Wine build, nothing here uses `xcodebuild`.
* ~20 GB free and 1–2 hours. CMake alone is 10–15 minutes: sdl12-compat, munt
  and fluidsynth are CMake-only and macOS ships no cmake, so it gets
  bootstrapped from source.
* Rosetta 2 on Apple Silicon — at **build** time only, because autoconf runs the
  x86_64 test programs it compiles. The finished bundle never needs it.

## Build options

```
--archs "arm64 x86_64"    architectures (both by default)
--output DIR              where the .app lands       (default ./dist)
--build-dir DIR           scratch space              (default ./build)
--deployment-target 11.0  minimum macOS
--strict-sha              refuse any download without a verifiable checksum
--clean                   wipe the scratch directory
--clean-daum              rebuild DOSBox and the bundle, keep dependencies
--no-avail-guard          drop -Werror=unguarded-availability-new
```

The build is resumable — completed stages leave stamps in `build/stamps/`, and
per-package logs are in `build/logs/` (previous attempt kept as `.log.prev`).

The Daum source tree is a special case. Its edits are applied **in place** and
are not all idempotent, so `daum_patch_sources()` skips a tree it has already
stamped. That makes a stale tree dangerous rather than merely wasteful: the
build succeeds and silently ships the previous patch set. So the stamp records
a **fingerprint** of the patch set — `lib/daum.sh`, `vendor/dbprof.h`,
`vendor/openglhq/*` and `DAUM_PROFILE` — and the tree is re-extracted whenever
it changes. Editing any of those is enough; `--clean-daum` is a convenience,
not the thing correctness depends on.

This is worth spelling out because it already went wrong once. `--clean-daum`
removed `$SOURCES/dosbox-svn-daum-*/.daum-patched`, which never matched the
directory the build actually extracts into (`$SOURCES/daum-$DAUM_VERSION`), so
the flag was a no-op against the stamp. The first openglhq build came out with
the sources copied into `src/gui` but absent from `Makefile.am` and unwired in
`sdlmain.cpp` — and every other check passed, because everything else had been
patched by the run before.

### When an upstream host goes down

Building everything from source means depending on twenty publishers, and one of
them will always be having a bad day. nasm.us refused connections outright —
curl reporting `000`, a connection failure rather than a 404 — while its own
front page served normally, and preflight stopped the build over it.

`SOURCE_MIRRORS` in `versions.sh` maps the name a file is saved under to one or
more fallback URLs:

```bash
SOURCE_MIRRORS=(
  "nasm-${NASM_VERSION}.tar.xz  http://deb.debian.org/debian/pool/main/n/nasm/nasm_${NASM_VERSION}.orig.tar.xz"
)
```

The key is what `fetch()` saves it as, so a mirror may serve the file under a
different name — Debian calls it `nasm_2.16.03.orig.tar.xz` — and the local copy
still gets the canonical one. Mirrors are tried only after the primary fails,
and preflight sweeps them too: a preflight stricter than the build it precedes
is worse than none, because it stops builds that would have worked.

**A mirror is only as safe as its pin.** A mirror is an untrusted host serving a
file you did not publish; what makes it acceptable is that `fetch()` rejects
anything whose sha256 does not match `KNOWN_SHA256`, so the worst a bad mirror
can do is fail loudly. That rule is enforced rather than documented:

- Preflight refuses to run if a `SOURCE_MIRRORS` entry has no pin, or if its key
  matches no source's basename — a mistyped key means the mirror is silently
  never consulted, which looks like protection and isn't.
- If a mirror serves a file that has neither a pin nor a sidecar, `fetch()`
  quarantines it as `<name>.unverified` and stops. Downloading unverified from
  the publisher's own host is the pre-existing status quo; doing it from a third
  party is not.
- The sidecar is only ever looked for beside the **primary** URL. A checksum
  fetched from the same host that served the file proves nothing, since that
  host can serve both.
- A file failing its checksum moves to `<name>.bad`. Otherwise the next run
  finds a non-empty file, skips the download, and fails on the same bad bytes
  forever — with an error that says "mismatch" and never "delete this file".

Getting a trustworthy pin is the actual work. Where it can come from, in
descending order of preference:

| source | why | example |
|---|---|---|
| Upstream `.sha256sum` sidecar | no pin needed; `fetch()` finds it | most GNU projects |
| Debian's PGP-signed `.dsc` | signed, and a `3.0 (quilt)` `.orig` with no `+dfsg` suffix is the pristine tarball | nasm |
| Two independent distro hash files agreeing | separately maintained, so a single compromise doesn't move both | freetype |

FreeType needed the third route: Savannah publishes only a GPG `.sig`, and
Debian's freetype is `+dfsg`-repacked so its `.orig` is *not* the upstream file.
The pin is corroborated by FreeBSD ports `2024Q4` and Buildroot `2025.02`.

### Pin the backend

By default `risc_armv8le.h` is fetched from DOSBox-X's `master`. That is a
moving target, and it is the single most important input to this build. Once you
have a bundle you trust:

```
DOSBOXX_COMMIT=<40-char-sha> ./build-dosbox-daum.sh
```

and record its sha256 in `versions.sh`'s `KNOWN_SHA256`. Preflight warns while
it remains unpinned.

## Verification

`verify-bundle.sh` is standalone and works on a moved or re-zipped bundle. It
checks naming and `Info.plist`, that the launcher, the dosbox binary and *every*
bundled dylib are universal, that every Mach-O slice targets macOS 11.0 or
older, that nothing links outside the bundle, that all `LC_RPATH` entries are
`@loader_path`-relative, that no Homebrew/MacPorts path is embedded, that every
Mach-O is signed and the executable-memory entitlement is present, and that each
expected library is bundled.

Then it clones the bundle to `/tmp`, runs it from there, and — the check that
matters — starts DOSBox with `core=dynamic` and confirms it executes DOS
commands **without falling back to the interpreter**. A build that quietly drops
to `core=normal` on Apple Silicon would pass every static check while missing
the entire point.

### The FPU: 80-bit in software, on both slices

Daum ships two FPU cores and picks between them on `C_FPU_X86`, which
`configure.ac` sets for x86/x86_64 only. A universal build therefore got real
x87 with 80-bit intermediates on the Intel slice and portable C computing in
64-bit `double` on Apple Silicon.

That is not a rounding curiosity. x87 has a 64-bit significand; a `double` has
53. `OLE2DISP.DLL` 2.3.3027.1 — the OLE layer of Windows 3.1x — detects the
difference deliberately: `FILD` a 64-bit integer, `FBSTP` to packed BCD, compare
the low digits. When they come back wrong it pops an extra stack entry, and
DOSBox, which does not deliver FPU exceptions to the guest, aborts emulation.
**Windows 3.1 OLE applications ran on Intel and died on Apple Silicon.**

`long double` is not a way out. DOSBox-X solves this with
`fpu_instructions_longdouble.h`, but that reinterprets an 80-bit memory image
through a `long double` union — correct only where `long double` *is* the x87
format. On Apple Silicon it is a synonym for `double`, so that file would not
merely lose precision there, it would read garbage.

So the precision is emulated. `src/fpu/fpu_instructions_softfloat.h` implements
all 69 entry points on **Berkeley SoftFloat-3e**, with the x87 transcendentals
(`f2xm1`, `fyl2x`, `fpatan`, `fsincos`, `fprem`) taken from Bochs, which
computes them through 128-bit intermediates. `C_FPU_X86` is bypassed entirely
and the build asserts the x87 core is unreachable.

Three things follow:

* **Both slices compute bit-for-bit alike.** No architecture-dependent results.
* **Save states transfer between architectures.** Values live in `fpu.p_regs[]`,
  which was already the packed x87 layout the MSVC core wrote with
  `fstp TBYTE PTR ...m1` — a direct lossless mapping onto SoftFloat's
  `extFloat80_t`. The serialised struct is unchanged, so files stay compatible
  with what the Intel slice produced before.
* **Precision control is honoured**, which neither stock core did. `FPU_SetCW`
  extracts only the rounding field, so a program requesting 24- or 53-bit
  precision silently got full precision; SoftFloat takes it directly.

`FBSTP` is worth one note. The stock core extracts BCD digits by repeated
`double` division by ten, and the intermediate quotients need 57 bits where a
`double` has 53 — which is precisely why the OLE check failed. Eighteen digits
fit `int64` exactly, so the replacement does it in integer arithmetic and the
question disappears.

Vendored under `vendor/bochs-fpu/`: SoftFloat-3e is BSD-3-Clause, the Bochs x87
files are LGPL, both GPLv2-compatible. Bochs' build dependency turned out to be
three macros (`BX_CPP_INLINE`, `BX_LITTLE_ENDIAN`, `BX_CONST64`) plus
`SOFTFLOAT_FAST_DIV64TO32`, covered by a small shim — deliberately two shims,
since the one reachable from `fpu.cpp` must not typedef `Bit64u` where Daum
already has.

#### The acceptance test runs inside the emulator

`vendor/fputest.asm` is a DOS `.COM` performing the exact `FILD`/`FBSTP`
sequence and writing its digits to a file on a mounted drive — the guest's
screen cannot be read from the host. The build assembles it with the nasm it
already provides, and `verify-bundle.sh` runs it:

```
PASS  FPU: FILD/FBSTP exact -- 00999517642299539456 (Windows 3.1 OLE check passes)
```

It compares against that exact string, so the `...9600` a reduced-precision core
produces fails by construction. A host-side unit test would not have proved the
emulator does this; this does.

So on Apple Silicon the runtime checks are run a second time against the x86_64
slice under Rosetta 2 — dynrec, the code-cache mapping, interpreter fallback and
openglhq init. An Intel host can only ever check itself, and says so.

One detail that makes this work at all: it runs
`Contents/Resources/daum/bin/dosbox` directly rather than the launcher.
`exec`ing a universal binary re-picks the preferred architecture, so
`arch -x86_64 <launcher>` would hand back an arm64 dosbox and silently verify
nothing.

### What Rosetta cannot tell you about the dynrec

Running the x86_64 slice under Rosetta with `core=dynamic` and a sequence of
small DOS programs (`cls`, `dir`, `mem`) produces an endless

```
CPU:DOS rerouted Interrupt Called 3
```

— `INT 3`, opcode `0xCC`, i.e. the guest executing a field of breakpoint bytes.
It is deterministic to the cycle, x86_64-only, independent of `output=`, and it
generates gigabytes of log. It is almost certainly **not** a bug in the
recompiler.

The two backends differ in exactly the relevant way:

```c
/* risc_x64.h    */ static void cache_block_closing(...) { }                  /* empty  */
/* risc_armv8le.h*/ static void cache_block_closing(...) { __builtin___clear_cache(...); }
```

The x86 version is empty *because it is correct* — x86 guarantees the
instruction cache is coherent with writes, so self-modifying code needs no
notification. AArch64 makes no such guarantee, hence the explicit flush.

Under Rosetta that guarantee is emulated rather than architectural. The code
cache is plain RWX (the checks above report exactly that), DOSBox signals
nothing when it rewrites a block, and Rosetta must therefore notice unaided.
Running several small programs in succession loads code to the *same* guest
addresses repeatedly, forcing block invalidation and regeneration — the
sharpest self-modifying-code case there is. A single program run once, which is
what the `core=dynamic` check above does, never provokes it.

So the cross-architecture section validates that the x86_64 dynrec **runs and
does not fall back to the interpreter**. It does not, and cannot, validate that
it is correct on real Intel hardware, where the coherency it relies on is a
property of the CPU rather than of a translator. Only an Intel Mac settles that.

Checks that search the binary carry a **control string**. `Contents/MacOS/
dosbox-daum` is a launcher trampoline containing none of DOSBox's code, so
scanning it finds nothing no matter what was built — and "found 0 matches" reads
identically whether the feature is absent or the scan looked in the wrong file.
The openglhq check therefore also looks for `SDL:OPENGL:`, which every build
emits: if the control is missing too, the report says the scan is broken rather
than blaming the feature.

### `SDL_OPENGLHQ_PROBE` — asking the renderer instead of guessing

Finding the shaders in the binary proves they were compiled in. Whether they
*run* is a separate question, and three attempts to answer it by grepping
DOSBox's stdout all failed the same way.

`LOG_MSG` is stdio, so a probe run that has to be killed loses the buffer
entirely. The only way to force a flush was to end the run with `-c exit` — and
that races the thing being measured, because `GFX_SetSize` runs from a PIC event
scheduled by `VGA_StartResize`, so quitting early means the mode set never
happens. Redirecting to a file instead of a pipe does not help; the unflushed
buffer is lost either way. Every outcome arrived as *saw nothing*, which cannot
distinguish "openglhq did not start" from "openglhq started and the output was
thrown away". The check could only warn, on every run, regardless of the truth.

So the renderer now reports directly. Setting `SDL_OPENGLHQ_PROBE` to a path
makes `openglhq.cpp` and `sdlmain.cpp` append one line per decision point,
closing the file each time — nothing is ever left in a buffer, which makes
`SIGKILL` a legitimate way to end the probe and removes the reason it had to
exit early at all.

```
conf output=openglhq accepted     the parser took the openglhq arm
gfx-setsize 640x400 want=4 …      a mode set happened, and for which output type
gl-arm entered 640x400 hq=1       GFX_SetSize reached the OpenGL case
gl-context ready 640x400 clip …   SDL_SetVideoMode returned a GL drawable
init enter 640x400 -> 640x480 …   OpenGLHQ_Init was called
init ok … / fail fbo 0 incomplete and what it decided
render first frame                GFX_EndUpdate really dispatches to the shaders
```

Read top-down, **the last rung present names the step that did not happen** —
which is the property the stdout version never had. A missing GL drawable now
reads as a missing GL drawable rather than as a missing feature, and a shader
that fails to compile is reported as a failure instead of a shrug.

One rung is not a probe at all but a repaired message. Before any mode set,
`GUI_StartUp` does `SDL_SetVideoMode(640,400,0,SDL_OPENGL)` purely to find out
whether GL works and to query the extensions; if it returns NULL, `want_type` is
permanently downgraded to `SCREEN_SURFACE`. That one call decides whether
`output=opengl` and `output=openglhq` mean anything for the rest of the run —
and upstream logs `Could not initialize OpenGL, switching back to surface`,
identical text whether the driver is missing, the pixel format was rejected, or
the process cannot reach the window server. `SDL_GetError()` has just recorded
which, and the message drops it. It now prints it, to the log and to the probe.

`gfx-setsize` is the odd rung out. Every other one lives inside
`case SCREEN_OPENGL:`, so without it "no mode set ever happened" and "the output
type was downgraded before the mode set" both present as silence after the
parser line — and those want completely different answers. It carries the
`SCREEN_TYPES` values from `sdlmain.cpp` itself (`want=4 (opengl=4 surface=1
openglhq=0)`) rather than a name table written into the patch, which would go
quietly wrong if the enum were ever reordered.

`render first frame` is the rung worth having. A successful `init` only proves
the programs compiled; the dispatch in `GFX_EndUpdate` could be wired wrong with
no visible symptom, because the stock display-list path draws a perfectly good
unscaled picture. That is why the run no longer ends at `-c exit`: it sits at
the DOS prompt until a frame is drawn.

The probe ships in the release binary, so `verify-bundle.sh` also runs it once
with the variable unset and confirms the file did not grow — the failure mode
being a hardcoded default path, which would silently write to the user's
filesystem on every launch.

```bash
SDL_OPENGLHQ_PROBE=/tmp/ohq.txt \
  dist/dosbox-daum.app/Contents/MacOS/dosbox-daum -conf hq.conf
```

## The main-loop profiler

`output=opengl` and `cycles=max` are each fine on their own; together the
emulation speed collapses. Ruled out so far: the PBO path, vsync, dynrec/W^X,
Voodoo GL, frame count, CPU saturation, and per-frame render cost. Since the
cheap hypotheses are gone, the build now carries instrumentation instead.

`vendor/dbprof.h` is header-only, compiled in unconditionally, and **completely
inert unless `DOSBOX_PROF` is set in the environment** — so the shipped bundle
is unchanged and a suspect run needs no rebuild. `verify-bundle.sh` checks both
halves of that claim. `DAUM_PROFILE=0 ./build-dosbox-daum.sh` omits it.

```bash
DOSBOX_PROF=1 DOSBOX_PROF_LOG=/tmp/prof.log \
  dist/dosbox-daum.app/Contents/MacOS/dosbox-daum -conf slow.conf
```

| | |
|---|---|
| `DOSBOX_PROF=1` | enable |
| `DOSBOX_PROF_LOG=PATH` | write there instead of stderr |
| `DOSBOX_PROF_STALL_MS=8` | report any single `Normal_Loop` pass this long |
| `DOSBOX_PROF_EVERY_MS=2000` | summary period |
| `DOSBOX_PROF_MAXLINES=200` | per-window line cap, so the profiler cannot itself become the stall |

### What it measures, and why those things

One pass of `Normal_Loop` is one interval: `DOSBOX_RunMachine` calls it in a
loop and it returns as soon as `ticksRemain` runs out, so the interval boundary
and the `cycles=max` decision point coincide. That is what makes a stall
*attributable* to a cycle cut rather than merely correlated with one.

**wall vs. thread CPU time** is the number that matters. Both are sampled per
pass, `CLOCK_UPTIME_RAW` against `CLOCK_THREAD_CPUTIME_ID`:

* `wall >> cpu` — the emulator thread was **blocked**. A swap waiting on the
  window server, a context lock, a sleep.
* `wall ≈ cpu` — the thread was **running the whole time and got less done**.
  E-core demotion or QoS, cache pressure, genuinely more work.

Those two need completely different fixes, and no amount of frame-time
measurement separates them. Everything already eliminated was eliminated by
measuring the second kind of cost while the first kind was never ruled out.

**Phases.** `hw`, `pic`, `cpu`, `ev`, `tick`, `delay` are top level and
mutually exclusive; they sum to the pass wall time less `unacct`. `map`,
`texup`, `draw`, `swap`, `title` are *nested* inside those — the VGA render
path runs from a PIC event, which runs inside the CPU phase — so they are
reported separately as "of which" rather than added in. Double counting them
would be the easiest available way to reach a confidently wrong conclusion.

**Every autoadjust decision**, including the ones the controller declines to
apply. A ratio under `cycles=max`'s 1%/12% cut-offs is itself a finding: it
means the controller saw the stall and *discarded* the measurement, which from
outside looks identical to not having stalled.

**The `/3` panic cut** gets its own line. `dosbox.cpp`'s auto-adjust has a
branch that fires when one pass exceeds 15 ms of wall clock while fewer than 5
emulated ticks were scheduled, and it divides the guest clock by three:

```c
} else if (ticksAdded > 15) {
        CPU_CycleMax /= 3;
```

A run of those *is* the collapse. Each one is caused by a single identifiable
stall, which the `STALL` line immediately above will already have attributed to
a phase.

### Reading the output

```
[prof] STALL wall 23.41ms  cpu 2.07ms  blocked 21.34ms  cyc 41208  cmax 60000
[prof]        hw 0.02 pic 21.15 cpu 1.83 ev 0.21 tick 0.03 delay 0.00 | unacct 0.17
[prof]       of which GL: map 0.00/0 texup 0.14/1 draw 0.02/1 swap 20.90/2 title 0.00/0
[prof] PANIC added 18 sched 3  cmax 60000 -> 20000  (/3)
```

Read that as: blocked, not slow; inside `pic`; inside `swap`; twice in one
frame. Then the controller cut the clock by two thirds.

That last detail is worth knowing about in advance. Daum's `GFX_EndUpdate`
swaps **twice per frame on the PBO path** — the PBO branch calls
`SDL_GL_SwapBuffers()` and then falls through to the unconditional one below
it. That is upstream Daum, not something this build introduced, and the swap
*count* in the per-window summary says plainly whether it is happening here.

The periodic summary carries the aggregate, including `Mcyc/cpu-s` — emulated
cycles per second of thread CPU time. If that number falls while the on-cpu
percentage stays flat, the thread is being throttled rather than blocked, and
the investigation moves to QoS and core placement.

## First finding: the focus throttle latch

The first profiled run was a DOS/4GW game that sat on the extender banner for
about a minute and on a black screen for about another, then ran normally from
the intro video onward. It was not a performance problem:

```
[prof] --- 2.00s  wall 1995ms  cpu 399ms (20% on-cpu)  passes 3067  emulated 1.52 Mcyc
[prof]        hw 18.77 pic 168.59 cpu 58.90 ev 118.41 tick 5.41 delay 1608.16
[prof]       autoadjust: 0 applied, 0 held, 0 PANIC(/3)
```

Eighty percent of the wall clock is `SDL_Delay`. The host is *idle*, deliberately,
because the guest clock has been set to 750 cycles — and `cycles=max` has stopped
adjusting it. That holds for 48 consecutive windows, 96 seconds, `CPU_CycleMax`
750 then 375, auto-adjust never firing once. Then:

```
[prof] adj   sched 96593 done 19571 added 11 ratio 4542  cmax 375 -> 1019  APPLIED
[prof] adj   sched 250 done 38 added 1 ratio 6059  cmax 1019 -> 3524  APPLIED
...                                                cmax 176325 -> 249765  APPLIED
```

`ticksScheduled` 96593 is 96.6 seconds of emulated time that accumulated without
a single evaluation — `ticksScheduled += ticksAdded` runs outside the auto-adjust
guard while the reset runs inside it. So auto-adjust was not merely quiet, it was
**skipped**: `CPU_SkipCycleAutoAdjust` was latched on.

Two upstream assumptions produce that:

**`CPU_Enable_SkipAutoAdjust()` halves the guest clock on every call.** Safe only
if focus-lost and focus-gained arrive in pairs. Under sdl12-compat on macOS they
do not — each `SDL_SetVideoMode` recreates the SDL2 window, and a window created
while the app is not frontmost emits another unpaired `FOCUS_LOST`. 3000 → 1500
→ 750 → 375 is three of them, and 3000 is exactly `cycles=max`'s starting value.
That `/2` is the only halving in the tree and it is guarded on
`CPU_CycleAutoAdjust`, so those numbers cannot come from anywhere else.

**Only a focus-gained event clears the latch.** Miss it and the emulator stays
throttled for the session. What finally cleared it was the mode change that
starts the intro video, which is why the game appears to "warm up" at exactly
that moment.

Launching from a terminal is what exposes this: the shell keeps keyboard focus,
so DOSBox never legitimately has it. Double-clicking the bundle in Finder makes
the app frontmost and largely avoids it.

### The fix

Three changes, in `lib/daum.sh`. Unlike the profiler these are corrections to
real bugs, so they are **not** gated on `$DOSBOX_PROF` — only their logging is.

* `CPU_Enable_SkipAutoAdjust()` is idempotent. A second focus-lost with no
  intervening gain no longer halves the clock again.
* `CPU_Disable_SkipAutoAdjust()` calls Daum's own `CPU_Reset_AutoAdjust()`
  before releasing the latch. Handing 96 seconds of stale `ticksScheduled` /
  `ticksDone` to the first evaluation after focus returns is not a recovery,
  it is a coin flip — here it happened to produce ratio 4542 and a favourable
  jump, but nothing guarantees that.
* `GFX_Events()` consults `SDL_GetAppState()` while the latch is set. DOSBox
  otherwise tracks focus purely as a state machine driven by paired events;
  `SDL_GetAppState()` answers the same question directly and does not depend on
  any event having arrived, so a dropped one is no longer unrecoverable. The
  check costs one bool test in the healthy case.

With `DOSBOX_PROF=1` the profiler now also logs every `SDL_ACTIVEEVENT` with its
raw state mask, and every latch transition:

```
[prof] focus state 0x02 gain 0  INPUTFOCUS  cmax 1500
[prof] skip  enable  cmax 1500 -> 1500  sched 40000 done 9000  (repeat -- halving suppressed)
```

A `(repeat -- halving suppressed)` line is direct confirmation of unpaired
focus-lost events rather than an inference from the cycle numbers.

### What that leaves of the original question

With the latch fixed, `output=opengl` + `cycles=max` shows no collapse. Over a
64-second profiled run of the same game:

* `SDL_GL_SwapBuffers` costs **0.34–1.0 ms** once the game is running, and GL as
  a whole (map + texture upload + display list + swap) is **0.5–3% of wall
  time**. It is not blocking on anything.
* The emulator reaches **92–94% on-cpu at 320+ Mcyc/s** while presenting 47–57
  fps, with auto-adjust in equilibrium (ratio ≈ 1024) and **zero `/3` panics**.
* Of 95 long passes, 84 have `wall ≈ cpu` — the CPU decoder running a genuine
  multi-millisecond `CPU_Cycles` batch at `cmax` 300000, which is what
  `cycles=max` is supposed to do. Only 3% of the long-pass time is swap.

So the original conjunction was the latch all along, and the conjunction itself
is explained by the code: the halving lives behind `if (CPU_CycleAutoAdjust)`,
so it can only fire under `cycles=max`, and the unpaired `FOCUS_LOST` events
come from window creation, which is exactly what changes when the output type
changes. Either setting alone removes one of the two ingredients.

Even with the fix in place the underlying event stream is still wrong — a fresh
run shows `gain 1`, `gain 0`, `gain 0` with no gain in between:

```
[prof] focus state 0x02 gain 1  INPUTFOCUS  cmax 3000
[prof] focus state 0x02 gain 0  INPUTFOCUS  cmax 3000
[prof] skip  enable  cmax 3000 -> 1500  sched 0 done 0
[prof] focus state 0x02 gain 0  INPUTFOCUS  cmax 1500
[prof] skip  enable  cmax 1500 -> 1500  sched 0 done 0  (repeat -- halving suppressed)
[prof] skip  disable cmax 1500 -> 1500  sched 0 done 208
```

sdl12-compat is still emitting an unpaired loss; the suppression absorbs it and
`SDL_GetAppState()` clears the latch. One halving still lands (3000 → 1500)
because the first loss is indistinguishable from a real one — auto-adjust
recovers from that within a second, which is why the slow start is gone.

Long passes are labelled `STALL` when the thread was blocked and `BUSY` when
`wall ≈ cpu`, because at `cmax` 300000 a page of 40 ms passes is normal
operation rather than a page of problems.

### A profiler bug worth remembering

That same run also appeared to show zero GL activity — `swap 0.00/0` for 148
seconds on a config with `output=opengl`. That was wrong, and the cause was the
profiler: `dbprof()` was declared `static inline`, giving it internal linkage,
so every translation unit got a private `DBProfState`. sdlmain.cpp accumulated
GL and title counts into a copy nobody ever printed, and dosbox.cpp reported its
own copy with those five counters permanently at zero.

The failure mode is what makes it worth a note. There was no crash and no
warning — just a plausible report whose zeros read as evidence. The `[cpu]`
findings above came from a single TU and survived intact; the GL conclusion did
not. `dbprof()` is now plain `inline`, and `verify-bundle.sh` asserts that a
profiled run prints exactly one `[prof] enabled` banner, because two banners is
precisely what a split state looks like from outside.

## What the patcher actually changes

Written against the real Daum tree, not inferred. Six edits, each asserting on
the exact text it expects and aborting if the tree has moved:

| File | Change | Why |
|---|---|---|
| `core_dynrec.cpp` | `PAGESIZE` 4096 → 16384 | `PAGESIZE_TEMP` resolves to this when `C_HAVE_MPROTECT` is set, which it is on macOS. The `4096`s in `CACHE_MAXSIZE` and `DYN_PAGE_HASH` are *guest* x86 page sizes and are deliberately left alone. |
| `core_dynrec.cpp` | add `ARMV8LE 0x06` | Upstream has no AArch64 constant. `POWERPC` collides with `ARMV4LE` at `0x04`, so `0x06` is the first free value. |
| `core_dynrec.cpp` | add `#elif C_TARGETCPU == ARMV8LE` | Dispatch to the new backend. |
| `cache.h` | code-cache `malloc` → `drc_alloc_cache` | RWX `mmap`, falling back to `MAP_JIT`. Only this one allocation — `cache_blocks` in the same function is ordinary data and must not become executable. |
| `configure.ac` | add `aarch64 \| arm64)` case | Upstream has **no ARM case at all**; without this, arm64 falls into `*)` → `C_TARGETCPU UNKNOWN`. |
| `configure.ac` | extend the `C_DYNREC` gate to `armv8le` | The one that actually matters. Upstream gates dynrec on x86/x86_64 only, so `--enable-dynrec` alone would still have produced an interpreter-only arm64 build. |
| `dosbox.cpp`, `sdlmain.cpp` | profiler probes | Runtime-gated on `$DOSBOX_PROF`; see above. Skip with `DAUM_PROFILE=0`. |
| `cpu.cpp` | idempotent `CPU_Enable_SkipAutoAdjust`, reset on disable | Unpaired focus-lost events took `cycles=max` from 3000 to 375 and latched auto-adjust off. Always applied. |
| `sdlmain.cpp` | `GFX_Events` consults `SDL_GetAppState()` | Recovers the latch when a focus-gained event is never delivered. Always applied. |
| `sdlmain.cpp` | `output=openglhq` → `SCREEN_OPENGL` + `sdl.opengl.hq` | The SDL video-driver route cannot exist under sdl12-compat; the shaders run from `GFX_EndUpdate` instead. The render scaler is left alone — see above. |
| `sdlmain.cpp` | three `OpenGLHQ_ProbeLog` calls | Runtime-gated on `$SDL_OPENGLHQ_PROBE`; see above. The patcher asserts the count is exactly 3 — the verifier reads them as a ladder, so a missing rung would blame the wrong step. |
| `sdlmain.cpp` | drop the duplicate swap on the PBO path | Upstream swaps twice per PBO frame — the branch swaps and then falls through to the unconditional swap below it. |
| `src/gui/Makefile.am` | add `openglhq.cpp` | Otherwise it is never compiled and `output=openglhq` links against nothing. |

Every row was tested against the real source excerpt it matches, verified
idempotent, and confirmed not to touch the guest-side page constants. Each one
also has a post-patch assertion in `daum_patch_sources()`: the patcher reporting
success is not the same as the edit having landed, and on this project those two
came apart more than once.

## Where this is likely to need iteration

I could not compile any of this, and one area carries real risk:

**Interface drift between DOSBox-X and Daum.** Both descend from DOSBox SVN and
the backend's function list matches what Daum's dynrec calls, but DOSBox-X has
had eleven years of divergence. If `risc_armv8le.h` references a helper Daum's
`decoder.h` does not provide, it will show up as a compile error in
`build/logs/daum.arm64.log`, naming the specific symbol.

`daum_verify_core()` guards the quiet-failure case directly: it reads the
generated `config.h` and fails the build if `C_DYNREC` is not set, or if the
arm64 build did not select `C_TARGETCPU ARMV8LE`.

## Licensing

DOSBox Daum is GPLv2. DOSBox-X's `risc_armv8le.h` is GPLv2. FFmpeg is
configured LGPL-only (no `--enable-gpl`, no `--enable-nonfree`). SDL2,
sdl12-compat and SDL_net are zlib-licensed; munt and FluidSynth are LGPL.
Redistribution of the resulting bundle is governed by the GPLv2 that DOSBox
itself carries.

## Known limitations

**Not notarized.** Distributing to another Mac needs `xattr -cr` once, or
right-click → Open.

**Daum's printer emulation is Windows-spooler based** and will not work on
macOS; the rest of Daum's feature set is platform-independent.

**Glide passthrough** (`glide2x.dll`) is a Windows DLL mechanism and does not
apply here. Daum's *built-in* 3dfx Voodoo emulation, which is what the `voodoo=`
config option controls, does work and is the relevant path for games with a
3Dfx renderer — including Descent to Undermountain.
