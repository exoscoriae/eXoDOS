# Portable universal mpv 0.41 — from-source build system

This repository builds a **fully self-contained, universal (Apple Silicon +
Intel) `mpv.app`** for mpv 0.41.0 that runs on a clean macOS 11 (Big Sur) or
newer install with **no Homebrew, no MacPorts, and no other system packages**.
Every non-Apple library mpv needs is compiled from upstream source against a
macOS 11 deployment target and bundled inside the app; the only external
dependencies at runtime are Apple's own system frameworks and `/usr/lib`.

The scripts are designed to run on **your Mac** — building a Mach-O universal
binary requires Apple's SDK and linker, which exist only on macOS. They were
authored and statically checked on another machine, so treat the first run as a
real build that may need a version bump here or there (see *Troubleshooting*).

---

## Requirements (build host)

- macOS 11 or newer on Apple Silicon or Intel.
- **Xcode Command Line Tools** only: `xcode-select --install`. This provides
  `clang`, `swiftc`, `git`, `python3`, `otool`, `install_name_tool`, `lipo`,
  `codesign`, and the macOS SDK. Nothing else is required. (mpv 0.41's macOS
  player is partly Swift, so `swiftc` must be present — verify with
  `xcrun -f swiftc`.)
- An internet connection for the first run (sources are downloaded once and
  cached under `work/downloads`).
- ~15 GB free disk and, realistically, **1–3 hours** for a cold full build
  (FFmpeg + x265 + aom dominate).

You do **not** need Homebrew or MacPorts, and if they happen to be installed the
build will not pick them up — see *Isolation from system libraries* below for
exactly how that is enforced.

---

## Quick start

```sh
cd mpv-portable-build
./build.sh                # tools → deps → mpv → bundle → verify
open dist/mpv.app         # the finished, portable app
```

The mpv 0.41.0 source tarball is expected at `../mpv-0.41.0.tar.gz` (i.e. the
project folder that contains this directory). Override with
`MPV_TARBALL=/path/to/mpv-0.41.0.tar.gz ./build.sh`.

### Sub-commands

| Command | What it does |
|---|---|
| `./build.sh`        | Full pipeline (default). |
| `./build.sh tools`  | Build only the host tools (pkgconf, nasm, cmake, meson, ninja). |
| `./build.sh deps`   | Build/refresh all bundled libraries into the universal prefix. |
| `./build.sh mpv`    | (Re)build mpv, bundle, and verify (dependencies must already exist). |
| `./build.sh bundle` | (Re)build mpv and re-create the `.app`. |
| `./build.sh ffmpeg-app` | Assemble `dist/ffmpeg.app` from the universal `ffmpeg`/`ffprobe`/`ffplay` binaries already in the prefix, then verify it. |
| `./build.sh verify` | Re-run the portability/min-OS/arch checks on `dist/mpv.app`. |
| `./build.sh clean`  | Remove `work/` (sources, staging, prefix). |
| `./build.sh distclean` | Remove `work/` and `dist/`. |

The build is incremental: each `(library, arch)` pair is stamped, so re-running
after a failure resumes rather than restarting.

---

## What gets built

The default configuration is the **maximal, GPL-clean, no-nonfree** set.
Bundled libraries include:

- **FFmpeg 8.1.2** with VideoToolbox/AudioToolbox, and codec libraries dav1d,
  SVT-AV1, aom, libvpx, x264, x265, libwebp, zimg, opus, vorbis, FLAC, theora,
  and LAME.
- **libplacebo** (OpenGL backend) for the `gpu`/`gpu-next` renderer, plus lcms2
  for colour management.
- **libass** with FreeType, HarfBuzz, FriBidi, fontconfig, and libunibreak.
- **Lua 5.2** (on-screen controller, user scripts) and **MuJS** (JavaScript
  scripts), **libarchive** (play media inside archives), **uchardet** (subtitle
  charset detection), **rubberband** (high-quality pitch/tempo).
- **Optical media**: libbluray, libdvdnav/libdvdread/libdvdcss, libcdio +
  paranoia, libxml2.
- **libjpeg-turbo** for the JPEG screenshot writer.

Audio output via CoreAudio and AVFoundation; windowed video via the native
macOS Cocoa backend (`--vo=gpu` / `--vo=gpu-next`); hardware decoding via
VideoToolbox; plus the Swift `macos-cocoa-cb` window, Touch Bar, and "now
playing"/remote-command-center integration.

### Two notes on the macOS backend

**Swift is required and enabled.** In mpv 0.41 the macOS player's application
and event-loop layer (`osdep/mac/*.swift`, `video/out/mac/*.swift`) is written
in Swift, and the build refuses to produce the `mpv` cplayer with Cocoa enabled
unless Swift is built too — there is no Swift-free Cocoa player path anymore.
The build therefore compiles the Swift backend with `swiftc`, pinned per
architecture and to the 11.0 deployment floor via
`-target <arch>-apple-macosx11.0`. The Swift runtime is ABI-stable and shipped
by macOS 11+ in `/usr/lib/swift`, so the result stays back-deployable; any
symbol newer than macOS 11 (e.g. `kIOMainPortDefault`) is weak-linked under the
`-target` floor, and `verify.sh` fails the build on any *strong* reference to
such a symbol. Building requires `swiftc` (ships with Xcode / recent Command
Line Tools); confirm with `xcrun -f swiftc`.

**Vulkan/MoltenVK off by default.** libplacebo is built with its OpenGL backend,
which is the working windowed path here (`gl-cocoa` carrying the full `gpu-next`
renderer). Enabling Vulkan would only add the fragile MoltenVK-from-source step
for no on-screen benefit on this OpenGL/Cocoa path. To pull it in anyway, set
`ENABLE_VULKAN=1` in `config.sh` (adds Vulkan-Headers, Vulkan-Loader, glslang,
and MoltenVK and flips mpv's `vulkan` feature on).

### FFmpeg tools bundle (`dist/ffmpeg.app`)

With `ENABLE_FFMPEG_TOOLS=1` (default), the same FFmpeg that backs mpv also
builds the `ffmpeg`, `ffprobe`, and `ffplay` programs (ffplay via a bundled
**SDL2 2.32.x**). They install into the universal prefix and are assembled into
a second portable bundle, `dist/ffmpeg.app`, by the exact same relocation pass
used for mpv — every non-system dylib is copied into `Contents/MacOS/lib` and
all references rewritten to `@executable_path/lib`. It is a plain CLI-tools
container (not a GUI app): run the tools by path, e.g.

```sh
dist/ffmpeg.app/Contents/MacOS/ffprobe -i movie.mkv
dist/ffmpeg.app/Contents/MacOS/ffmpeg  -i in.mov out.mp4
```

Because the three binaries share `Contents/MacOS/lib`, a script can locate any
tool by scanning `ffmpeg.app/Contents/MacOS`. The bundle is universal
(arm64 + x86_64) and macOS-11-floored, and passes the same `verify.sh` checks.
To skip building it, set `ENABLE_FFMPEG_TOOLS=0`.

---

## How portability and the macOS 11 floor are guaranteed

1. **Deployment target on everything.** `MACOSX_DEPLOYMENT_TARGET=11.0` plus
   `-mmacosx-version-min=11.0` is exported into `CFLAGS`/`CXXFLAGS`/`LDFLAGS`
   for every autotools build, written into the meson cross/native files, and
   passed as `-DCMAKE_OSX_DEPLOYMENT_TARGET=11.0` for cmake. Using a newer SDK
   is fine — the deployment target, not the SDK, sets the floor.

2. **Universal by lipo-merge.** Each dependency is built once per architecture
   with `--prefix=<final path>` but `DESTDIR=<per-arch stage>`, so its dylib
   install-names are already correct. The two staged trees are then merged with
   `lipo -create` into one universal prefix — no install-name fixups needed.
   mpv itself is pure C/Obj-C and is built in a single pass with both `-arch`
   flags. (Per-arch is required because nasm-assembled libraries — FFmpeg,
   x264, x265, dav1d, … — cannot emit a fat object in one compile.)

3. **Relocation into the app.** mpv's own `TOOLS/osxbundle.py` +
   `dylib_unhell.py` walk `otool -L` recursively, copy every non-system dylib
   into `mpv.app/Contents/MacOS/lib`, rewrite all ids and references to
   `@executable_path/lib/...`, strip developer-tool rpaths, and ad-hoc sign the
   result.

4. **Verification (`scripts/verify.sh`).** After bundling, every Mach-O object
   in the app is checked to be (a) universal arm64+x86_64, (b) reporting a
   minimum-OS load command no newer than 11, and (c) free of any reference to
   Homebrew, MacPorts, `/Library/Frameworks`, or the build-time prefix — only
   `@executable_path`/`@loader_path`/`@rpath`, `/usr/lib`, and
   `/System/Library/Frameworks` are permitted. It also scans for *strongly
   linked* symbols introduced after macOS 11 (e.g. `_kIOMainPortDefault`), which
   are the cause of `dyld: Symbol not found` aborts on Big Sur — a symbol like
   that is only safe when weakly linked, which the 11.0 deployment target
   guarantees. The build fails loudly on any violation.

---

## Isolation from system libraries

A central goal is that the build never links against, or even discovers, a
library that merely happens to be installed on the build machine (a Homebrew or
MacPorts package, a hand-built `/usr/local` library, a stray framework) — any of
which could be built for a newer macOS and silently raise the bundle's minimum
OS. Isolation is enforced on several independent channels, then backstopped by
verification:

1. **PATH** is rebuilt as `$TOOLS_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin`, so
   `/opt/homebrew/bin`, `/usr/local/bin`, and `/opt/local/bin` cannot supply a
   tool.
2. **Environment scrubbing** (`scrub_env`) unsets every variable that can inject
   a foreign search path regardless of PATH — `CPATH`, `C_INCLUDE_PATH`,
   `CPLUS_INCLUDE_PATH`, `LIBRARY_PATH`, `DYLD_*`, `*FRAMEWORK_PATH`,
   `CMAKE_PREFIX_PATH`, an inherited `SDKROOT`, and any pre-set
   `CFLAGS`/`LDFLAGS`/`PKG_CONFIG_*` — before each build phase, then sets our
   own. This is run at the top of the tools, per-arch dependency, and mpv build
   environments.
3. **pkg-config** uses `PKG_CONFIG_LIBDIR` (which *replaces*, not augments, the
   default search dirs) pinned to our prefix only, so no Brew/MacPorts `.pc`
   file is ever visible to autotools or meson.
4. **`-isysroot $SDKROOT` on every invocation.** With an explicit sysroot,
   clang's default system include/library/framework paths become
   *sysroot-relative* — `/usr/local/include` is looked up as
   `$SDKROOT/usr/local/include` (clean), never the real `/usr/local`. Our own
   `-I$PREFIX/include` is also placed first.
5. **CMake lockdown.** Because `find_package`/`find_library` search `/usr/local`
   and framework dirs on their own, the cmake wrapper passes
   `CMAKE_IGNORE_PREFIX_PATH`/`CMAKE_SYSTEM_IGNORE_PREFIX_PATH` for
   `/usr/local;/opt/homebrew;/opt/local`, `CMAKE_PREFIX_PATH=$PREFIX`, and
   `CMAKE_FIND_FRAMEWORK/APPBUNDLE=LAST`.
6. **Backstop: the build fails if anything slipped through.** `verify.sh`
   inspects every Mach-O in the finished app and *fails the build* if any object
   references `/usr/local`, `/opt/homebrew`, `/opt/local`, `/Library/Frameworks`,
   or the build prefix, or reports a minimum-OS newer than 11. So the worst case
   for a leak is a failed build you can diagnose — never a silently
   incompatible app shipped to users.

If Homebrew/MacPorts are present, `build.sh` prints a one-time note that their
directories are on your interactive PATH and that the build ignores them; you do
not need to uninstall anything.

## Configuration

Edit `config.sh` to change behaviour; `versions.sh` holds every pinned version
and source URL. Notable toggles:

- `ENABLE_*` flags select feature groups. Defaults give the maximal clean set.
- `ENABLE_FDK_AAC=1` adds the Fraunhofer AAC encoder — **nonfree**, do not
  redistribute the resulting binary.
- `ENABLE_OPENSSL=1` bundles OpenSSL for TLS instead of macOS SecureTransport;
  under a GPL build this implies FFmpeg `--enable-nonfree` (again, not
  redistributable). The default (SecureTransport) needs no extra dylib and is
  license-clean.
- `ENABLE_SRT` / `ENABLE_RIST` add those streaming transports (need OpenSSL).
- `ENABLE_VAPOURSYNTH=1` adds the VapourSynth bridge (pulls in Python + zimg).
- `CODESIGN_IDENTITY="Developer ID Application: …"` re-signs the bundle with a
  hardened runtime for distribution/notarization instead of the default ad-hoc
  signature. To bump a component, change its `*_VER`/`*_URL` pair in
  `versions.sh`.

---

## Licensing (read before redistributing)

The default build is GPLv2+/LGPL only (FFmpeg `--enable-gpl --enable-version3`
with SecureTransport for TLS). Because x264 and x265 are GPL, the resulting
binary as a whole is **GPL** — fine to share under the GPL. If you enable
`ENABLE_FDK_AAC` or `ENABLE_OPENSSL`, FFmpeg switches to `--enable-nonfree`,
producing a binary that **may not be redistributed** at all. Keep those off for
anything you intend to publish, or rebuild without GPL/nonfree pieces if your
distribution terms require it.

---

## Troubleshooting

- **A download 404s / a version vanished.** Upstreams retire old tarballs. Bump
  the relevant `*_VER`/`*_URL` in `versions.sh` to the current release and
  re-run; the version floors required by mpv 0.41 are documented inline there.
- **A meson dependency isn't found** even though it built: confirm its `.pc`
  landed in `work/prefix/lib/pkgconfig` and that `PKG_CONFIG_LIBDIR` points only
  there (it does by default). Run `./build.sh deps` again — the build resumes.
- **`xcrun: error: unable to find utility` / no SDK.** Run
  `xcode-select --install`, or `sudo xcode-select -s /Applications/Xcode.app`
  if you have full Xcode.
- **Subtitles show no fonts.** fontconfig is configured to scan
  `/System/Library/Fonts`, `/Library/Fonts`, and `~/Library/Fonts`. On first
  run the fontconfig cache builds lazily; if needed, set
  `FONTCONFIG_PATH` to the app's fontconfig directory.
- **Gatekeeper blocks the app on another Mac.** The default signature is
  ad-hoc. For distribution, set `CODESIGN_IDENTITY` and notarize, or instruct
  users to right-click → Open the first time.
- **Resuming/forcing a rebuild of one library.** Delete its stamp:
  `rm work/stage/.built/<name>.<arch>` and re-run `./build.sh deps`.

---

## Layout

```
mpv-portable-build/
├── build.sh              # orchestrator / entry point
├── config.sh             # feature toggles, paths, deployment target
├── versions.sh           # pinned versions + canonical source URLs
├── scripts/
│   ├── lib.sh            # logging, fetch/extract, per-arch build wrappers, lipo merge
│   ├── bootstrap.sh      # host tools (pkgconf, nasm, cmake, meson, ninja) from source
│   ├── deps.sh           # one recipe per bundled library + build ordering
│   ├── build-mpv.sh      # universal meson build of mpv
│   ├── bundle.sh         # osxbundle.py wrapper + optional Developer ID re-sign
│   └── verify.sh         # arch / min-OS / no-Brew-MacPorts verification
└── work/                 # (generated) downloads, sources, per-arch staging, prefix
    └── ...
dist/mpv.app              # (generated) the portable universal app
```
