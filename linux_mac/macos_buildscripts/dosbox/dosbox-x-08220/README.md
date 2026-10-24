# DOSBox-X 0.82.20 — portable universal macOS 11+ build kit

Builds **`dosbox-x-08220.app`** (executable **`dosbox-x-08220`**): a fully
self-contained, universal (Apple Silicon + Intel) app bundle of DOSBox-X
0.82.20 using **SDL 1.2**, runnable out of the box on any fresh install of
macOS 11.0 or later. No Homebrew. No MacPorts. Everything bundleable is
statically linked; the only dynamic dependencies are libraries Apple ships
on every macOS install.

## Why this is a build *kit* and not just `./build-macosx`

DOSBox-X 0.82.20 was released **2019‑07‑31** — sixteen months before Apple
Silicon or macOS 11 existed. Building it correctly for this target required
research into the actual 0.82.20 tree; the kit encodes all of it:

1. **Apple Silicon dynamic core (the page-size problem you mentioned).**
   The 0.82.20 dynrec cache (`src/cpu/core_dynrec/cache.h`) allocates its JIT
   code cache with `malloc()` + `mprotect(PROT_EXEC)` and a hardcoded
   4096‑byte page. On arm64 macOS this fails three separate ways: the kernel
   page size is **16 KiB** (so 4 KiB-aligned `mprotect` returns `EINVAL`),
   writable+executable pages require **`mmap(MAP_JIT)`**, and `PROT_EXEC` on
   heap memory is refused outright. The kit patches the allocation to
   `mmap(RWX, MAP_JIT)` with a 16 KiB-safe `PAGESIZE_TEMP`, calls
   `pthread_jit_write_protect_np(0)` (no-op without the hardened runtime, but
   correct with it), and adds a `sys_icache_invalidate()` for the startup
   link stubs, which are written outside the normal block-close path. Normal
   blocks were already flushed — 0.82.20's `dyn_closeblock()` calls
   `cache_block_closing()` → `__builtin___clear_cache()`, and the ARM64
   backend (`risc_armv8le.h`) *does* exist in this release, so with the
   allocation fixed the **dynamic core works on Apple Silicon**. The Intel
   slice keeps the classic (faster) `dynamic_x86` core untouched.

2. **`aarch64` vs `arm64`.** Apple's toolchain reports `arm64-apple-darwin`,
   but 0.82.20's `configure.ac` only recognizes `aarch64` — misdetect and the
   dynamic core silently vanishes (`C_TARGETCPU UNKNOWN`). The kit passes
   explicit `--host=aarch64-apple-darwin20` / `x86_64-apple-darwin20`
   triplets and **asserts `C_TARGETCPU` in the generated `config.h`** after
   configure, failing loudly instead of shipping a slow build.

3. **MT‑32 on Apple Silicon.** 0.82.20's configure only enables munt MT‑32
   emulation on x86 — a 2019 assumption about weak ARM boards. Patched on for
   `aarch64|arm64` (munt is portable C++), so both slices have MT‑32.

4. **SDL 1.2.** DOSBox-X carries its own patched SDL 1.x fork in-tree. Per
   your choice the kit swaps in the same fork from `dosbox-x-v2025.01.01`
   (still the SDL 1.2 API this codebase was written against, plus years of
   Big Sur/arm64 fixes) while the **emulator source stays pure 0.82.20**.
   Built static, along with in-tree SDL_net (modem + IPX), zlib and libpng.

5. **No Homebrew even as a build dependency.** 0.82.20 doesn't commit
   `./configure`, so autotools are required — the kit bootstraps its own
   autoconf/automake/libtool/pkgconf/nasm from GNU/upstream sources into a
   private prefix (host tools only, never shipped). The build runs with a
   sanitized `PATH`, and the Darwin `-I/usr/local/include` that 0.82.20
   hardcodes (a classic Homebrew leakage vector) is patched out.
   `verify-bundle.sh` re-checks for leakage after the fact.

6. **FluidSynth without glib.** Modern FluidSynth drags in glib→pcre→gettext…
   The kit builds **FluidSynth 1.1.6** — the last pre-glib release, exactly
   the v1 API 0.82.20's `midi_synth.h` targets — static, with all OS drivers
   disabled (DOSBox-X drives the synth itself).

7. **FFmpeg capture that matches the 2019 API.** 0.82.20's capture code
   encodes **H.264 + AAC into MPEG‑TS** (verified in `hardware.cpp`), so the
   kit builds a minimal static **FFmpeg 4.4** (last major with the old
   avcodec API; FFmpeg 5 removed it) + **x264**, with everything else
   disabled — no VideoToolbox/SecureTransport/etc. that could drag in
   version-sensitive symbols.

## Requirements (build machine)

- Apple Silicon Mac (builds arm64 natively, cross-compiles x86_64)
- Xcode Command Line Tools: `xcode-select --install`
- Network access, ~4 GB free disk, roughly 1–2 hours (FFmpeg dominates)

The **target** machines need nothing: macOS 11.0+ on either architecture.

## Usage

```sh
cd dosbox-x-08220-buildkit
chmod +x build.sh verify-bundle.sh
./build.sh                # or: ./build.sh --no-ffmpeg
```

Work happens in `~/dosbox-x-08220-work/`; the result is
`~/dosbox-x-08220-work/out/dosbox-x-08220.app`. After any failure, fix and
re-run with `./build.sh --resume` — every stage is idempotent and skips
completed work. Logs live in `~/dosbox-x-08220-work/logs/`.

### What ends up enabled

Dynamic CPU core on both architectures, SDL 1.2 video (incl. OpenGL output),
CoreMIDI/CoreAudio MIDI passthrough, MT‑32 (munt), FluidSynth soundfont
synth, screenshots + ZMBV AVI movie capture (libpng/zlib), FFmpeg H.264/TS
capture, modem + IPX over network (SDL_net), NE2000 passthrough (system
libpcap), internal debugger (`--enable-debug=heavy`, system ncurses), xBRZ
scaler, and the rest of the standard 0.82.20 feature set.

### Verification (done automatically; re-run any time)

```sh
./verify-bundle.sh ~/dosbox-x-08220-work/out/dosbox-x-08220.app
```

Mirrors the min-OS audits done for okular/gnumeric/mpv portable bundles:
every Mach-O must be universal; **every slice's `LC_BUILD_VERSION`/
`LC_VERSION_MIN_MACOSX` minos must be ≤ 11.0**; the dylib closure may
reference only `/usr/lib` and `/System/Library` (fresh-install guaranteed);
no `/usr/local`–`/opt/homebrew`–`/opt/local` references; valid ad-hoc
signature (mandatory on arm64); no accidental SDL2 linkage.

## Runtime notes

- First run on another Mac: `xattr -dr com.apple.quarantine dosbox-x-08220.app`
  (Gatekeeper quarantine; the app is ad-hoc signed, not notarized).
- The app is **not** hardened-runtime signed — deliberately, so `MAP_JIT`
  works without entitlements. If you ever notarize it, sign with
  `com.apple.security.cs.allow-jit` and keep the JIT patch as-is (it already
  calls `pthread_jit_write_protect_np`).
- To confirm the dynamic core on an M-series Mac: set `core=dynamic` in the
  config; the log should show dynrec activity and no `DynrecCore` /
  "Allocating dynamic cache failed" errors. `core=auto` also uses it in
  protected mode.
- NE2000 passthrough needs read access to `/dev/bpf*` at runtime (an OS
  permission, not a library issue).
- PC‑98 mode: `FREECG98.BMP` is copied into `Contents/Resources`; 0.82.20
  also looks in the working directory — copy it next to your conf if needed.

## Known risks / troubleshooting (honest list)

This exact configuration (2019 codebase, 2025 SDK, universal, static) is not
something CI ever built, and I could not compile macOS binaries while
preparing the kit, so treat the first run as a shakedown. Failure modes and
what to do:

- **`dosbox-make-<arch>.log` C++ errors in `sdlmain.cpp` / `menu_osx.mm`**:
  most likely a mismatch between 0.82.20 and a newer SDL-fork header. Try
  the strict 2019 SDL instead: delete the work dir, edit `build.sh`
  `SDL_FORK_TAG="dosbox-x-v0.82.20"` (the sparse clone then fetches
  `vs/sdl` — for that tag it's `vs2015/`, so also change the two `vs/` paths
  in stage 2/3 to `vs2015/`), and rebuild.
- **FFmpeg 4.4 fails to link with a very new Xcode**: known ld-prime
  friction; add `--extra-ldflags="-Wl,-ld_classic"` to the ffmpeg configure
  in `build.sh` (Xcode 15 only), or build with `--no-ffmpeg`.
- **A configure check "WARNING(...) not enabled"** printed by stage 5: the
  feature's library check failed — see the matching
  `logs/dosbox-configure-<arch>.log` and `config.log` in the build tree.
- **autoreconf failures**: make sure nothing from Homebrew is in your shell
  init that exports `ACLOCAL_PATH`/`M4`; the script sanitizes `PATH` but not
  every exotic variable.

## Kit contents

| file | purpose |
|---|---|
| `build.sh` | the whole pipeline: tools → sources → patches → per-arch deps → per-arch dosbox-x → lipo → bundle → sign → verify |
| `patches/apply_patches.py` | verified string-substitution patches (JIT/page-size, MT‑32 arm64, hermetic includes) — aborts loudly if the source doesn't match |
| `resources/Info.plist` | bundle metadata (`LSMinimumSystemVersion 11.0`, executable `dosbox-x-08220`) |
| `verify-bundle.sh` | the portability audit described above |
