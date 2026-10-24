# Portable universal macOS app bundles for eXo ScummVM builds

Builds seven fully self-contained, universal (x86_64 + arm64) `.app` bundles that
run out of the box on macOS 11.0 and later, on a fresh install, with **all engines**
and as many features as possible enabled.

| App bundle | Executable | Source |
|---|---|---|
| scummvm-2-3-0-git18903-g313a824fb9.app | scummvm-2-3-0-git18903-g313a824fb9 | commit 313a824fb91c88b9d8cfe6234c73608c3a55dfa4 |
| scummvm-2-5-0.app | scummvm-2-5-0 | tag v2.5.0 |
| scummvm-2-8-0.app | scummvm-2-8-0 | tag v2.8.0 |
| scummvm-2-8-0-git9335-g00e72a17004.app | scummvm-2-8-0-git9335-g00e72a17004 | commit 00e72a17004d393d8f44e4c54aa51c0a7efe75cc |
| scummvm-2-9-0.app | scummvm-2-9-0 | tag v2.9.0 |
| scummvm-3-0-0-git20192-g3ca9da6a1c3.app | scummvm-3-0-0-git20192-g3ca9da6a1c3 | commit 3ca9da6a1c36ed1450ec5c5f08d48a225c7699df |
| scummvm-2026-1-0.app | scummvm-2026-1-0 | tag v2026.1.0 |

## How it works

The toolchain is ScummVM's own [dockerized-bb](https://github.com/scummvm/dockerized-bb)
(osxcross + clang cross-compilers), which is how official macOS builds are made.
Two customizations enforce your portability constraints:

1. **`MACOSX_DEPLOYMENT_TARGET=11.0` everywhere.** The stock arm64 toolchain
   targets macOS 14.0 and x86_64 targets 10.9; we override both to 11.0 so every
   object gets `minos 11.0`.
2. **No MacPorts (or Homebrew) binaries anywhere.** The stock toolchain downloads
   prebuilt *MacPorts* static libraries, which are built against whatever macOS
   the MacPorts builders run — exactly the "binary blob needs newer macOS" trap.
   Our overlay image (`docker/Dockerfile.rebuild`) wipes the entire library
   prefix from the stock toolchain and rebuilds **every** third-party library
   from source with deployment target 11.0, using dockerized-bb's own
   `lib-helpers` recipes (plus one added recipe for SDL2). Nothing is installed
   on your Mac; Homebrew/MacPorts are never touched.

All libraries are linked **statically** into the executable
(`--enable-static`), so the bundles carry no dylibs at all. The only runtime
dependencies are macOS system libraries (`/usr/lib`, `/System/Library`), which
exist on every macOS 11 install. `verify-bundle.sh` proves both properties for
every Mach-O in every bundle.

Features enabled (auto-detected from the rebuilt libs, varying by ScummVM
version support): SDL2, SDL2_net, zlib, bzip2, png, jpeg, gif, ogg/vorbis,
theora, FLAC, mad, faad2, mpeg2, a52, mpcdec, vpx, freetype, fribidi, mikmod,
sonivox, FluidSynth, Discord RPC, retrowave, and system curl (cloud/DLC) from
the SDK. Sparkle updates are intentionally omitted (pointless for ad-hoc-signed
side-loaded bundles). `--disable-system-dialogs` matches your Linux flatpaks;
remove it in `build-one.sh` if you want native file dialogs.

## Prerequisites (on your M1 MacBook Pro)

- **Docker Desktop** with *"Use Rosetta for x86_64/amd64 emulation"* enabled
  (Settings → General). The toolchain images are linux/amd64. Expect the
  toolchain build to take a few hours under emulation — it compiles clang and
  every library. It only happens once.
- **Xcode Command Line Tools** (`xcode-select --install`) — for `lipo`,
  `codesign`, `otool`, `PlistBuddy` on the host. Full Xcode not required.
- **Xcode 26.2 `.xip`** downloaded from https://developer.apple.com/download/all/
  (free Apple ID required; Apple's license does not allow us to redistribute the
  SDK). Apple names the file `Xcode_26.2_Universal.xip`; place it as-is into
  `macos/dockerized-bb/toolchains/apple-sdks/` — setup.sh renames it to the
  `Xcode_26.2.xip` form the Dockerfile expects.
  after running `setup.sh` once (it clones the repo, then tells you this again).
  If dockerized-bb has moved to a newer Xcode when you run this, use the version
  named in `toolchains/apple-sdks/Dockerfile.m4` (`XCODE_VERSION`).
  You do *not* need the old Xcode 9.4.1 xip — setup.sh patches out the i386 SDK.
  Note: an .xip over 4 GB is fine; setup.sh splits it for Docker automatically
  if needed per dockerized-bb's README.

## Usage

```sh
cd macos
./setup.sh          # clone dockerized-bb, patch, build toolchain + overlay images (once)
./build-all.sh      # build all 7 versions, both arches, merge + sign + verify
# or a single one:
./build-one.sh scummvm-2-9-0 v2.9.0
```

Finished bundles land in `macos/out/<name>.app` plus a `<name>.app.zip`.

## Verification

`build-one.sh` runs `verify-bundle.sh` automatically. It fails the build if any
Mach-O in the bundle:

- is not universal (missing x86_64 or arm64 slice), or
- has a `minos`/`LC_VERSION_MIN` greater than 11.0 in either slice, or
- links any dylib outside `/usr/lib` or `/System/Library`.

You can also run it manually: `./verify-bundle.sh out/scummvm-2-9-0.app`.

## Signing / Gatekeeper

Bundles are ad-hoc signed (`codesign -s -`), which arm64 macOS requires. They
are not notarized, so on first launch users must right-click → Open, or you can
strip quarantine after unpacking: `xattr -dr com.apple.quarantine <app>`.

## Known wrinkles

- The two oldest trees (2.3.0-git, v2.5.0) predate several modern-clang fixes.
  `build-one.sh` applies the known ones automatically (the ICB `px_array.h`
  const-cast fix, same issue you hit with GCC on Linux). If an old tree throws a
  new compiler error, add a fix to `patches/<name>/` (unified diffs, `-p1`) —
  they're applied automatically.
- If `make toolchains/...` complains about restricted toolchains, that's the
  Apple-SDK licensing guard; `setup.sh` passes the right variables.
- If SDL2 2.32.10 disappears from GitHub someday, bump `SDL2_VERSION` in
  `docker/packages/libsdl2/build.sh`.
