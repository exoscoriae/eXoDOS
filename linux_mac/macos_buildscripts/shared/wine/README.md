# Portable Wine 11.0 for macOS 11+

Builds `wine.app` — a self-contained, relocatable Wine 11.0 bundle that runs
32-bit and 64-bit x86 Windows programs on any Mac running macOS 11 Big Sur or
later, Intel or Apple Silicon, with no Homebrew, no MacPorts, and no network
access after the first launch.

```
./build-wine.sh              # ~2-4 hours, ~35 GB scratch space
./verify-bundle.sh dist/wine.app
```

Output: `dist/wine.app`, whose executable is `Contents/MacOS/wine`.

---

## What you get

| | |
|---|---|
| Wine | 11.0 (Jan 2026), single unified `wine` loader |
| Windows architectures | i386 + x86_64 via Wine 11's new WoW64 |
| Gecko / Mono | 2.47.4 (x86 + x86_64) and 10.4.1, staged offline |
| Graphics | Vulkan via MoltenVK 1.4.1 → Metal (wined3d Vulkan backend, DXVK-ready) |
| Audio | CoreAudio |
| Media | GStreamer 1.24 **and** FFmpeg 7.1 (winedmo) |
| TLS | GnuTLS 3.8 (schannel) |
| Input | SDL2 (gamepads, XInput, DirectInput) |
| Also | CUPS printing, PCSC smartcards, OpenCL, pcap |

Everything not provided by macOS itself is compiled from source at
`MACOSX_DEPLOYMENT_TARGET=11.0` and bundled inside the app.

---

## Requirements

* **Xcode Command Line Tools** — `xcode-select --install`
* **Full Xcode** (optional) — lets MoltenVK be built from source instead of
  using Khronos's official release binary. The verifier audits both identically.
* **~35 GB** of free disk space and 2–4 hours (Apple Silicon, 10 cores)
* **Rosetta 2** on Apple Silicon — needed *at build time* because autoconf and
  meson execute the x86_64 test programs they compile.
  `softwareupdate --install-rosetta --agree-to-license`

The script rebuilds `PATH` from scratch (`/usr/bin:/bin:/usr/sbin:/sbin` plus
its own tool prefix) and unsets every `DYLD_*`, `PKG_CONFIG_*`, `CPATH`,
`LDFLAGS`-style variable, so an existing Homebrew or MacPorts installation on
the machine cannot contaminate the build. Preflight fails loudly if it can.

---

## Why the Unix side is x86_64, and what "universal" means here

This is the one design decision worth understanding before you run anything.

Wine does not emulate CPUs. To run an x86 Windows program you need an x86
execution engine, and on macOS the only one that exists is **Rosetta 2** —
which translates whole *processes*, not code within a process. An arm64 Wine
therefore cannot host x86 guest code. CrossOver solves this on Linux ARM64 by
embedding FEX; FEX has no macOS host port, and Wine 11's ARM64EC support only
helps with ARM Windows binaries.

So:

* `bin/wine`, `wineserver`, `wine-preloader` and every `lib/wine/x86_64-unix/*.so`
  are **x86_64**. Native on Intel Macs; Rosetta 2 on Apple Silicon.
* `Contents/MacOS/wine` — the launcher — is a **universal** binary. It runs
  natively on both architectures, then `exec()`s the x86_64 loader, which the
  kernel hands to Rosetta transparently.
* Bundled support libraries are built **fat (arm64 + x86_64)** by default. The
  arm64 slices are inert today; they exist so a native ARM64 Wine slice can be
  dropped in beside this one when an x86 emulator for macOS hosts materialises.
  `--archs x86_64` skips them and halves the build time with no functional loss.

There is a pleasant side effect. Apple Silicon uses 16 KB pages natively, which
breaks Windows' assumption of 4 KB granularity — but Rosetta processes run with
a **4 KB page size**, so a Wine that runs under Rosetta never encounters the
problem at all. Building Wine native-arm64 is precisely what would surface it.

Low address space is handled the same way it is on Linux: `wine-preloader`
reserves the low memory ranges that Windows programs expect before the loader
starts. It is built, bundled, and signed like everything else.

**Rosetta's future.** Apple has said Rosetta 2 continues through macOS 27 and
becomes more limited in macOS 28, with CodeWeavers' PortJump framework taking
over for Intel-app support. When that lands, the arm64 half of this bundle is
where the replacement engine would plug in.

---

## Apple Silicon: W^X and code signing

macOS enforces write-xor-execute on Apple Silicon. Wine's PE loader maps
Windows code writable and then executes it, and .NET code from wine-mono JITs
at runtime. Both die without an exemption.

Every executable in the bundle is ad-hoc signed with
`src/wine.entitlements`, which requests:

* `com.apple.security.cs.allow-jit`
* `com.apple.security.cs.allow-unsigned-executable-memory`
* `com.apple.security.cs.disable-library-validation`
* `com.apple.security.cs.allow-dyld-environment-variables`

Entitlements do **not** survive `exec()`, which is why the signing pass covers
every Mach-O executable in the tree rather than just `Contents/MacOS/wine`.
`com.apple.security.cs.disable-executable-page-protection` is deliberately not
requested: it is a restricted entitlement that macOS only honours for
Apple-issued signatures, so on an ad-hoc bundle it is ignored at best.

The bundle is **not notarized**. Distributing it to another Mac means the
recipient needs `xattr -cr /path/to/wine.app` once, or a right-click → Open.
If you want notarization, sign with a Developer ID certificate and add
`--options runtime`; the entitlements above are already notarization-compatible.

---

## Layout

```
wine.app/Contents/
  MacOS/wine                     universal launcher (this is CFBundleExecutable)
  Info.plist                     LSMinimumSystemVersion = 11.0
  Resources/
    BUILD-INFO.txt               exactly what went into this build
    wine.icns
    wine/                        a complete, relocatable Wine installation
      bin/wine  bin/wineserver  bin/wine-preloader  ...
      lib/*.dylib                gnutls, freetype, SDL2, FFmpeg, GStreamer, MoltenVK
      lib/gstreamer-1.0/*.dylib  GStreamer plugins
      lib/wine/x86_64-unix/      Wine's Unix modules
      lib/wine/i386-windows/     32-bit builtin PE DLLs
      lib/wine/x86_64-windows/   64-bit builtin PE DLLs
      libexec/gstreamer-1.0/     gst-plugin-scanner
      share/wine/gecko|mono/     MSIs installed into every new prefix, offline
```

Nothing inside contains an absolute path. Every dependency is `@rpath`-relative
with `@loader_path` rpaths, so the bundle works from `/Applications`, a USB
stick, or anywhere else. The verifier proves this by cloning the bundle to
`/tmp` and running it from there.

## Using it

```bash
wine.app/Contents/MacOS/wine --version
wine.app/Contents/MacOS/wine winecfg
wine.app/Contents/MacOS/wine /path/to/setup.exe
```

Double-clicking in Finder opens `winecfg`.

Handy additions:

```bash
# Prefer the FFmpeg/winedmo Media Foundation backend over GStreamer
wine reg add 'HKCU\Software\Wine\MediaFoundation' /v DisableGstByteStreamHandler /t REG_DWORD /d 1 /f

# Force wined3d onto Vulkan (MoltenVK) rather than its OpenGL path
wine reg add 'HKCU\Software\Wine\Direct3D' /v renderer /t REG_SZ /d vulkan /f
```

---

## Build options

```
--archs "arm64 x86_64"    library architectures (default; use "x86_64" to halve build time)
--output DIR              where wine.app lands            (default ./dist)
--build-dir DIR           scratch space                   (default ./build)
--deployment-target 11.0  minimum macOS
--with-opengl             only if you supply an EGL implementation (see below)
--strict-sha              refuse any download without a verifiable checksum
--clean                   wipe the scratch directory
--clean-wine              rebuild Wine and the bundle, keep the dependencies
--no-avail-guard          drop -Werror=unguarded-availability-new
```

Every version in `versions.sh` is overridable:
`FFMPEG_VERSION=7.1.1 ./build-wine.sh`.

The build is **resumable** — completed stages leave stamp files in
`build/stamps/`, so an interrupted or failed run picks up where it stopped.
Per-package logs are in `build/logs/`.

### How the macOS 11 floor is actually enforced

Three independent mechanisms, because a deployment-target flag alone is not
enough:

1. `-mmacosx-version-min=11.0` plus `MACOSX_DEPLOYMENT_TARGET` on every
   compiler and linker invocation, including meson machine files.
2. `-Werror=unguarded-availability-new` — turns "this API needs a newer macOS
   than your target" from a silent weak-link (which crashes on the older OS)
   into a compile error. This is the check that catches what the others miss.
3. `verify-bundle.sh` reads `LC_BUILD_VERSION` / `LC_VERSION_MIN_MACOSX` from
   every slice of every Mach-O in the finished bundle and fails on any value
   above 11.0.

Preflight also compiles a test binary and confirms the installed SDK still
*accepts* a macOS 11 target before anything else runs — newer Xcode releases
periodically raise that floor.

MoltenVK is pinned to **1.4.1** for exactly this reason: 1.4.2 (24 Jul 2026)
raised its own deployment target to macOS 12.0. Do not bump it.

---

## Verification

`verify-bundle.sh` is standalone and can be pointed at any `wine.app`,
including one that has been zipped, moved and unzipped elsewhere.

* Layout, naming, `CFBundleExecutable`, `LSMinimumSystemVersion`
* Launcher is universal; loader has an x86_64 slice; both PE architectures present
  and are genuine `MZ` images
* Every Mach-O slice targets macOS 11.0 or older
* No binary links outside the bundle except `/usr/lib` and `/System/Library`
* Every `@rpath` dependency resolves inside the bundle
* Every `LC_RPATH` is `@loader_path`/`@executable_path` relative
* No Homebrew/MacPorts path strings embedded anywhere
* Signature valid on the bundle and on every individual Mach-O; JIT entitlement
  present on both the launcher and the real loader
* Gecko and Mono MSIs present with the checksums Wine itself verifies
* **Runtime**: clones the bundle to `/tmp`, runs it from there, creates a fresh
  prefix offline, confirms gecko and mono install, then executes both
  `system32\cmd.exe` (64-bit) and `syswow64\cmd.exe` (32-bit)

`--no-run` skips the runtime section; `--verbose` lists individual offenders.

---

## Known limitations

**OpenGL works, despite `--without-opengl`.** That configure flag governs
Wine's generic Unix-side OpenGL (EGL/GLX), which macOS does not provide.
`winemac.drv` has its own CGL path that is not gated by it, so Windows programs
that call OpenGL directly do render — verified in practice: wined3d reports
`GL_VENDOR "Apple"` and drives its OpenGL backend. This is the same
configuration the official WineHQ macOS packages ship.

Two caveats. macOS's OpenGL stops at 4.1, so wined3d uses GL for Direct3D 9 and
below and Vulkan (MoltenVK) for D3D10+. And 32-bit programs reach GL through
Wine's WoW64 thunking layer, which is newer and less exercised — a
`fixme:opengl:wow64_map_buffer` in your log is that path working, just slowly.

**Guest programs that JIT their own code can fail on Apple Silicon.** This is a
Rosetta limitation and nothing in the bundle can work around it. Rosetta
detects self-modifying code by write-protecting pages it has already
translated; a guest that rewrites its code cache aggressively can end up
executing a stale translation, which surfaces as a wild jump — a valid
instruction at a nonsensical address, reached through a pointer that no longer
means anything.

Confirmed example: DOSBox's `core=dynamic` (dyn_x86) crashes, `core=normal`
works. Emulators, older .NET workloads and executable packers are the usual
suspects. Where a program offers an interpreter mode, use it. Where a 64-bit
build exists, prefer it: Rosetta's self-modifying-code handling for x86_64 is
far better exercised than for the 32-bit compat-mode segments that only Wine's
WoW64 produces.

Note that no entitlement helps here. On Apple Silicon
`com.apple.security.cs.disable-executable-page-protection` behaves identically
to `allow-unsigned-executable-memory`, which the bundle already requests.

**Bluetooth** (`winebth`) is disabled — the Wine driver is Linux-specific.

**libinotify is not bundled**, so Wine uses its polling fallback for directory
change notifications. Functionally identical, marginally less efficient.

**No notarization** — see the code signing section.

**gst-plugins-ugly** is built with `auto_features=disabled` and only
`asfdemux` enabled, so no GPL-encumbered codecs enter the bundle. FFmpeg is
configured LGPL-only (no `--enable-gpl`, no `--enable-nonfree`), which keeps
redistribution alongside Wine's LGPL clean.

## If the build fails

Version pins go stale. Preflight HEAD-checks all 27 source URLs before doing
any work and tells you exactly which ones moved — override those from the
environment and re-run; completed stages are skipped.

For a compile failure, `build/logs/<package>.<arch>.log` has the full output.
The most likely first-run casualties are:

* `-Werror=unguarded-availability-new` rejecting a third-party source file that
  uses a newer macOS API without an `@available` guard. Re-run with
  `--no-avail-guard` to confirm that is the cause, then decide whether that
  library's use of the API is actually reachable on macOS 11.
* A meson option name that changed between GStreamer releases. The modules are
  configured with `auto_features` and `--wrap-mode=nodownload` specifically to
  minimise this, but `gst-plugins-ugly` names `asfdemux` explicitly.

## Docker

Not used, and not usable. Building Mach-O binaries requires the macOS SDK,
Apple's linker, `codesign`, and — for `winemac.drv` — the Cocoa, Metal and
CoreAudio Objective-C frameworks. Cross-compiling that from Linux means
osxcross plus an extracted Apple SDK, which Apple's licence does not permit you
to redistribute and which cannot produce a valid Apple Silicon code signature.
A host build on the target OS is the only approach that reaches the stated goal.
