# DOSBox ECE macOS Build Scripts

Build fully portable, universal `.app` bundles of **DOSBox ECE r4301, r4358
and r4482** directly on a current version of macOS — no VM, no Homebrew, no
MacPorts.

The produced app bundles are:

* **Universal** (arm64 + x86_64) — one app runs natively on Apple Silicon and
  Intel Macs.
* **Compatible with macOS 11.0 (Big Sur) and newer.** Every binary and every
  bundled dylib is compiled with `-mmacosx-version-min=11.0`, and the
  packager audits every Mach-O in the bundle to prove nothing requires a
  newer OS.
* **Self-contained.** Every non-system dylib (SDL2, sdl12-compat, SDL_net,
  libpng, zlib, libogg, libvorbis, libsamplerate, mt32emu, glib, pcre2,
  libffi, fluidsynth) is built from source and bundled into
  `Contents/Frameworks/` with `@rpath` install names. Works out of the box on
  a fresh macOS install.
* **Working dynamic core on Apple Silicon** (see below).
* Branded with the **DOSBox ECE icon** (extracted from the ECE source tree),
  not the stock DOSBox icon.

Output naming:

| Source     | App bundle             | Executable inside      | DMG                    |
|------------|------------------------|------------------------|------------------------|
| ece-r4301  | `dosbox-ece-r4301.app` | `dosbox-ece-r4301`     | `dosbox-ece-r4301.dmg` |
| ece-r4358  | `dosbox-ece-r4358.app` | `dosbox-ece-r4358`     | `dosbox-ece-r4358.dmg` |
| ece-r4482  | `dosbox-ece-r4482.app` | `dosbox-ece-r4482`     | `dosbox-ece-r4482.dmg` |

---

## Prerequisites

Exactly one thing:

```bash
xcode-select --install
```

That's it. Everything else — including the build tools themselves — is
compiled from official source tarballs into local prefixes next to the
scripts. Nothing is installed system-wide, and `/usr/local`, `/opt/local`
and `/opt/homebrew` are kept off the PATH during every build so no package
manager can contaminate the result.

## Quick start

```bash
./build_all_ece.sh              # bootstraps tools + deps, builds all three ECE versions
./package_macos.sh ece-r4301    # -> dosbox-ece-r4301.app + dosbox-ece-r4301.dmg
./package_macos.sh ece-r4358
./package_macos.sh ece-r4482
```

`build_all_ece.sh` chains everything automatically:

1. `bootstrap_tools.sh` (if `tools-prefix/` is missing) — builds m4,
   autoconf, automake, libtool, pkgconf, cmake, ninja and meson from source
   using only the Xcode CLT. First run: 20–40 minutes (cmake dominates).
2. `build_deps.sh` (if `deps-prefix/` is missing) — builds every runtime
   library as universal, macOS-11-targeting dylibs. 15–30 minutes.
3. Downloads the three `ece-*-source.tar.gz` bundles (from the
   `jonesaaronj/exo_flatpaks` `source_bundles` release) if not already
   present, plus the codec sources the ECE decoder needs (~134 MB, cached).
4. Clean-extracts, patches (`fix_macos_build.py`), configures and builds
   each version, then **verifies** the result (universal + dynamic core
   present in both slices).

All stages resume from caches/stamps, so re-runs are fast.

---

## The Apple Silicon dynamic core fix

The old scripts produced binaries whose dynamic core did not work on Apple
Silicon. Three separate problems were fixed, all applied by
`fix_macos_build.py`:

**1. Host detection.** macOS reports the CPU as `arm64`, but stock DOSBox
`configure.ac` only recognizes `aarch64`. The fall-through set
`C_TARGETCPU=UNKNOWN`, which silently disabled every dynamic core — this was
the primary bug. `configure.ac` is patched to accept `arm64`, and — because a
universal build shares one `config.h` between two architectures that need
*different* cores — a per-architecture override block is appended to
`config.h` after configure:

* x86_64 slice → classic dynamic core (`core_dyn_x86`) + x86 assembly FPU
* arm64 slice → portable recompiler (`core_dynrec`) with the ARMv8 backend

**2. W^X enforcement.** Apple Silicon never allows memory that is writable
and executable at the same time. `core_dynrec` is patched to:

* allocate its code cache with `mmap(... MAP_JIT ...)` instead of `malloc`
  (malloc'd memory can never be made executable on Apple Silicon),
* toggle the cache between writable and executable with
  `pthread_jit_write_protect_np()` around code generation (cache init and
  block translation),
* invalidate the instruction cache (`sys_icache_invalidate` /
  `__builtin___clear_cache`) after writing code, before executing it.

**3. Page size.** Apple Silicon uses 16 KiB kernel pages; the code assumed
4096 (`PAGESIZE_TEMP`), which made `mprotect` fail with EINVAL.
`PAGESIZE_TEMP` is now 16384 on Apple Silicon.

`build_all_ece.sh` refuses to build if any of these patches failed to apply,
and after linking it checks with `nm` that the arm64 slice contains
`CPU_Core_Dynrec_Run` and the x86_64 slice contains `CPU_Core_Dyn_X86_Run`.

To confirm at runtime: set `core=dynamic` in the DOSBox configuration (or
leave `core=auto`, which uses it for protected-mode games) and check the
console/log — there should be no "dynamic core not supported" fallback, and
CPU-heavy games (Quake, etc.) should run dramatically faster.

---

## The ECE icon

The old bundles showed the stock DOSBox icon because they used
`src/platform/macosx/dosbox.icns` from the source tree — upstream never
updated that file. Yesterplay's actual ECE icon lives in **`src/dosbox.ico`**
(the Windows resource icon compiled into the official ECE `dosbox.exe`).

`package_macos.sh` extracts the largest image from that `.ico` with
`ico_to_png.py` (pure-Python, no third-party modules), renders the full
icon set with `sips`, and compiles `dosbox-ece.icns` with `iconutil` — all
stock macOS tools.

Fallback order: `src/dosbox.ico` (ECE icon) → a pre-made `dosbox-ece.icns`
placed next to the scripts → `src/platform/macosx/dosbox.icns` (stock icon,
with a loud warning).

---

## Script reference

| Script | Purpose |
|---|---|
| `bootstrap_tools.sh` | Builds all build-time tools from source into `tools-prefix/`. Host-only; nothing ships in the app. |
| `build_deps.sh` | Builds every runtime library from source into `deps-prefix/` as universal, macOS-11 dylibs (per-arch configure + `lipo` merge). `--all` adds the gridc/DOSBox-X extras. |
| `fix_macos_build.py` | Patches one ECE source tree for macOS (incl. all Apple Silicon dynamic-core fixes) and runs `autogen.sh` + `configure`. |
| `build_all_ece.sh` | Full pipeline: tools → deps → download/extract/patch/build/verify each ECE tarball. |
| `bundle_dylibs.py` | Walks the binary's dylib graph, copies deps into `Frameworks/`, rewrites install names to `@rpath`. |
| `ico_to_png.py` | Extracts the largest image from a Windows `.ico` as PNG (stdlib only). |
| `package_macos.sh` | Builds `dosbox-ece-rXXXX.app` + `.dmg`: icon, Info.plist, dylib bundling, macOS-11 audit, signing, optional notarization. |

### Signing options (package_macos.sh)

```bash
# Ad-hoc (default; other Macs need right-click -> Open once, or:
#   xattr -dr com.apple.quarantine "/Applications/dosbox-ece-r4482.app")
./package_macos.sh ece-r4482

# Developer ID
./package_macos.sh ece-r4482 --sign "Developer ID Application: Your Name (TEAMID)"

# Developer ID + notarization (stored keychain profile recommended)
xcrun notarytool store-credentials "dosbox-notary" --apple-id you@example.com --team-id YOURTEAMID
./package_macos.sh ece-r4482 --sign "Developer ID Application: Your Name (TEAMID)" \
    --keychain-profile "dosbox-notary"
```

For Developer ID signing the packager applies hardened-runtime entitlements
(`allow-jit`, `allow-unsigned-executable-memory`,
`disable-library-validation`) so both dynamic cores keep working. Ad-hoc
builds don't need entitlements — `MAP_JIT` works without them outside the
hardened runtime.

---

## Verifying the result

```bash
APP="dosbox-ece-r4482.app"

# Universal?
lipo -archs "$APP/Contents/MacOS/dosbox-ece-r4482"
# -> x86_64 arm64

# Dynamic cores present per slice?
nm -arch arm64  "$APP/Contents/MacOS/dosbox-ece-r4482" | grep CPU_Core_Dynrec_Run
nm -arch x86_64 "$APP/Contents/MacOS/dosbox-ece-r4482" | grep CPU_Core_Dyn_X86_Run

# No external library references?
otool -L "$APP/Contents/MacOS/dosbox-ece-r4482" | \
    grep -vE '^(/|\s+(@rpath|/System/|/usr/lib/))'
# -> empty

# Minimum macOS of every slice?
otool -l "$APP/Contents/MacOS/dosbox-ece-r4482" | grep -A2 LC_BUILD_VERSION | grep minos
# -> minos 11.0 (twice: once per slice)
```

(The packager performs the external-reference and minimum-OS checks
automatically and fails the build if they don't hold.)

---

## Directory layout after a full run

```
dosbox-ece-macos-scripts/
  bootstrap_tools.sh  build_deps.sh  build_all_ece.sh  package_macos.sh
  fix_macos_build.py  bundle_dylibs.py  ico_to_png.py
  tools-prefix/       # host build tools (autoconf, cmake, meson, ...)
  tools-cache/        # tool source tarballs
  deps-prefix/        # universal runtime dylibs
  deps-cache/         # library source tarballs
  codec-cache/        # ogg/opus/speexdsp sources + Opus DNN model
  ece-r4301-source.tar.gz  ece-r4358-source.tar.gz  ece-r4482-source.tar.gz
  ece-r4301/  ece-r4358/  ece-r4482/     # build trees
  dosbox-ece-r4301.app  dosbox-ece-r4301.dmg   # (and r4358 / r4482)
```

## Troubleshooting

**`autogen.sh: aclocal: command not found`** — `tools-prefix` missing or not
on PATH. Run `./bootstrap_tools.sh`, then rebuild via `./build_all_ece.sh`
(it sets PATH itself; don't run `make` from a bare shell without it).

**`configure: error: SDL not found`** — verify
`deps-prefix/bin/sdl-config` exists; re-run `./build_deps.sh sdl12-compat`.

**Dynamic-core verification fails after `make`** — the per-arch `config.h`
override was lost (e.g. `configure` was re-run manually). Re-run
`./build_all_ece.sh`; it re-applies patches on every clean extract.

**Icon is the stock DOSBox logo** — the packager warns when it falls back;
check that `ece-rXXXX/src/dosbox.ico` exists in the extracted source.

**"App can't be opened because it is from an unidentified developer"** —
ad-hoc signed build on another Mac:
`xattr -dr com.apple.quarantine "/Applications/dosbox-ece-rXXXX.app"`.

## DOSBox-X builds

The same toolchain also builds DOSBox-X v2024.07.01, v2024.10.01,
v2025.02.01, and v2025.05.03 as portable universal apps:

```sh
./build_all_dosboxx.sh          # downloads sources, builds all four
./package_dosbox_x_macos.sh dosbox-x-v2024.07.01   # -> dosbox-x-20240701.app + .dmg
./package_dosbox_x_macos.sh dosbox-x-v2024.10.01   # -> dosbox-x-20241001.app + .dmg
./package_dosbox_x_macos.sh dosbox-x-v2025.02.01   # -> dosbox-x-20250201.app + .dmg
./package_dosbox_x_macos.sh dosbox-x-v2025.05.03   # -> dosbox-x-20250503.app + .dmg
```

Dependencies come from the shared `deps-prefix` via `build_deps.sh --all`,
which adds the DOSBox-X extras (SDL2_net, libslirp for NE2000 NAT
networking, freetype for TTF output, ffmpeg for video capture) on top of
the ECE set. Everything is bundled into the .app; macOS 11.0 minimum is
audited the same way as for ECE.

**Apple Silicon dynamic core (DOSBox-X):** unlike ECE, all four DOSBox-X
versions already ship a W^X-safe dyncore allocator that dual-maps the code
cache on Darwin via `mach_vm_remap` (RW view for the recompiler, RX view
for execution) — no cache patching needed. What broke universal builds was
the single shared `config.h`: `fix_dosbox_x_build.py` injects a per-arch
override into `include/dosbox.h` so each slice compiles `core_dynrec` with
the right backend (`risc_x64` on x86_64, `risc_armv8le` on arm64) and the
Darwin dual-mapping feature macros are always on. `build_all_dosboxx.sh`
verifies `CPU_Core_Dynrec_Run` is present in BOTH slices of every binary.

The app icon comes from `contrib/macos/dosbox.icns` inside the DOSBox-X
source tree, and the reference `.conf` files are copied into
`Contents/Resources/`.

## GridC + Gunstick builds

```sh
./build_all_gridc_gunstick.sh                     # both forks
./package_fork_macos.sh dosbox-gridc-4-3-1        # -> dosbox-gridc-4-3-1.app + .dmg
./package_fork_macos.sh dosbox-gunstick           # -> dosbox-gunstick.app + .dmg
```

Sources auto-download from the exo_flatpaks `source_bundles` release
(`dosbox-gridc-GC-v4.3.1.tar.gz`, `dosbox-gunstick.tar.gz`).

**GridC** (SVN r4300, hiddenasbestos) gets the identical Apple Silicon
treatment as ECE: arm64 host detection, W^X/MAP_JIT/16 KiB-page cache
patches, per-arch override in `include/dosbox.h` (x86_64 → core_dyn_x86 +
x86 asm FPU, arm64 → core_dynrec/ARMv8). GameLink + OpenGL enabled.

**Gunstick** (DOSBox 0.74-3 + lightgun) predates the ARMv8 dynrec backend
entirely — `risc_armv8le.h` is grafted in from the GridC/ECE sources (the
backend interface is identical; verified against risc_x64.h signatures),
registered in core_dynrec.cpp, then the same W^X treatment is applied.
Its x86_64 slice keeps core_dyn_x86 but uses the portable C FPU (the
0.74-3 asm FPU predates x86_64).

**Gunstick fullscreen lightgun fix:** the fork sampled the gun position
from raw SDL mouse coordinates, ignoring the fullscreen letterbox offsets
(`sdl.clip.x/y`) — so fullscreen clicks sampled the wrong pixel and the
gun missed (windowed mode has zero offsets, which is why it worked).
`fix_gunstick_build.py` passes image-relative coordinates and treats
shots into the black bars as dark pixels (a miss).

The shared `dynrec_apple_silicon.py` module carries the patch machinery
(extracted verbatim from the verified ECE fix script) and is copied into
each source tree alongside the fork's fix script.
