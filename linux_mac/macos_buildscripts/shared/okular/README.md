# Okular 26.04 — Portable Universal macOS 11+ Bundle

A build system that produces a fully self-contained, universal (Apple Silicon +
Intel) `Okular.app` that runs out of the box on a clean install of macOS 11 (Big
Sur) or newer. Every library is bundled inside the `.app`. **No Homebrew, no
MacPorts** are used at any point, and nothing in the finished bundle requires an
OS newer than macOS 11.

It is built with **KDE Craft**, KDE's official meta-build system, which compiles
Qt, the KDE Frameworks, Okular, and every backend library from source.

> **Important reality (learned by running it):** KDE's prebuilt binary cache
> (`files.kde.org/craft/...`) is produced on macOS 12 and ships current Qt 6.9+/KF,
> which require macOS 12. It cannot be used for a macOS 11 bundle. This build
> therefore runs **fully from source** (`craft --no-cache`) for everything that
> lands in the app — Qt twice, KF, plus heavy dependencies (LLVM, Boost, FFmpeg,
> Poppler, Ghostscript). Expect **several hours to a day** of compiling per
> architecture, and be prepared for occasional per-package fixes. This is the
> unavoidable cost of pinning to the only macOS-11-safe Qt/KF.

---

## 1. The version matrix (and why it is forced)

This is the heart of the project. macOS 11 support is a hard ceiling that
constrains everything above it:

| Component | Version | Why this exact version |
|---|---|---|
| **Qt** | **6.7.3** | The **newest Qt that still supports macOS 11.** Qt 6.8 and later raised their minimum deployment target to macOS 12. |
| **KDE Frameworks** | **6.21** | The **last KF6 release that supports Qt 6.7.** KF 6.22 raised its minimum to Qt 6.8 (which would force macOS 12). |
| **Okular** | **26.04** | Requires only Qt ≥ 6.6 and the KF6 baseline, so it builds cleanly on Qt 6.7.3 + KF 6.21. |
| **Deployment target** | **11.0** | Big Sur. Enforced on every sub-build via `MACOSX_DEPLOYMENT_TARGET`. |
| **Architectures** | **arm64 + x86_64** | Built separately, then fused with `lipo`. |

The chain is self-consistent: Okular 26.04 → needs KF ≥ 6.0 (we give it 6.21) →
KF 6.21 needs Qt 6.6–6.7 (we give it 6.7.3) → Qt 6.7.3 runs on macOS 11. Pushing
any single component newer breaks macOS 11 support. These are pinned in
`build/00-config.sh`; the version numbers are the only thing you should normally
need to touch.

> If you ever relax the macOS 11 requirement to macOS 12, you can move up to the
> latest Qt 6.8+/KF 6.22+ and drop the version pins entirely — Craft would then
> just build current defaults.

---

## 2. How the universal build works

Craft builds **one architecture at a time** (its ABI is either
`macos-clang-arm64` or `macos-clang-x86_64`). There is no single-pass universal
mode. So the system builds the **entire stack twice**, into two independent
prefixes, and then merges them:

```
                 build/02 pins Qt 6.7.3 / KF 6.21 / Okular 26.04 in BOTH roots
                                   │
        ┌──────────────────────────┴───────────────────────────┐
        ▼                                                        ▼
  CraftRoot-arm64                                         CraftRoot-x86_64
  (native build)                                          (cross-build on M-series)
        │  build/03 arm64                                        │  build/03 x86_64
        ▼                                                        ▼
  Okular.app (arm64, libs bundled)                 Okular.app (x86_64, libs bundled)
        └──────────────────────────┬───────────────────────────┘
                                   ▼   build/04
                    lipo every Mach-O file → ONE universal Okular.app
                                   ▼   build/05
                    audit: arches + deployment target + no Brew/MacPorts
```

`macdeployqt` (invoked by Craft's packaging step) copies every Qt/KF/backend
dylib **into** each `.app`, so each architecture's app is already self-contained;
the merge just fuses the two into one fat binary set.

---

## 3. Requirements on your build machine

- **Apple Silicon Mac** (M-series). It builds arm64 natively and cross-builds
  x86_64. (An Intel Mac can do the reverse, but Apple Silicon is the
  better-supported host — set `ARCHES` in `00-config.sh` if you switch.)
- **Xcode Command Line Tools**: `xcode-select --install`. A full Xcode with a
  recent SDK is fine — the deployment target, not the SDK, is what pins macOS 11.
- **Python 3** (ships with the CLT) and **git**.
- **~40–60 GB free disk** (two full CraftRoots with Qt + KF source and build
  trees) and several hours of CPU time for a first build.
- A network connection (Craft downloads source tarballs from KDE/Qt mirrors).
- **No Homebrew or MacPorts needed** — and you should keep `/opt/homebrew`,
  `/usr/local`, and `/opt/local` *off* your `PATH` during the build so no stray
  system library leaks in. The audit in step 5 will catch any that do.

---

## 4. How to run it

From the `build/` directory on your Mac:

```bash
cd build

# One-shot: bootstrap → pin → build both arches → merge → audit
./build-all.sh

# …or also produce a distributable disk image:
MAKE_DMG=1 ./build-all.sh
```

Prefer running the stages individually the first time, so a failure is easy to
localize:

```bash
./01-bootstrap-craft.sh        # clone Craft, create both CraftRoots
./02-pin-versions.sh           # force Qt 6.7.3 / KF 6.21 / Okular 26.04
./02b-prefetch-qt-source.sh    # pre-place Qt 6.7.3 source (avoids the archive 404)
./03-build-arch.sh arm64       # build the full stack FROM SOURCE (hours)
./03-build-arch.sh x86_64      # build the full stack again, cross (hours)
./04-merge-universal.sh        # lipo into one universal Okular.app
./05-audit-bundle.sh           # verify before you ship
```

`build-all.sh` wipes the two CraftRoots first (`CLEAN_ROOTS=1`, the default) so no
cached macOS-12 library from an earlier run can leak into the bundle. To resume an
interrupted from-source build without wiping, run with `CLEAN_ROOTS=0`.

Output lands in `dist/Okular.app` (and `dist/Okular-26.04.2-universal-macos11.dmg`
if `MAKE_DMG=1`).

Everything is configured in **`build/00-config.sh`** — versions, the two
CraftRoot locations (`~/okular-craft` by default), job count, and the deployment
target. The CraftRoots live outside this project folder on purpose (Craft paths
get long and shouldn't sit on a synced/cloud directory).

---

## 5. The backends ("maximum features")

`build/03-build-arch.sh` explicitly builds the optional backend libraries listed
in `build/backends.txt` **before** Okular, so Okular's CMake detects them and
enables every backend it can:

| Backend | Library |
|---|---|
| PDF | Poppler (+ freetype, fontconfig, lcms2, libjpeg-turbo, openjpeg) |
| PostScript / EPS | libspectre (→ Ghostscript) |
| DjVu | DjVuLibre |
| TIFF / multipage images | libtiff |
| CHM (compiled HTML help) | chmlib |
| Markdown | discount |
| Mobipocket / e-books | qmobipocket |
| ComicBook (zip/rar) | libzip, libarchive |
| Images, FictionBook, Plucker, XPS, ODT, … | Qt image plugins + Okular's built-in generators |

If a particular backend library fails to build, the script logs it and continues
— Okular simply omits that one backend rather than failing the whole build. The
audit report and the build log tell you exactly what made it in.

---

## 6. Verifying the result

`05-audit-bundle.sh` walks every Mach-O file in the `.app` and hard-fails if any
of these is violated:

1. **Universal** — each binary must contain *both* `arm64` and `x86_64`.
2. **Deployment target ≤ 11.x** — reads `LC_BUILD_VERSION` / `LC_VERSION_MIN_MACOSX`
   and flags anything that demands macOS 12+.
3. **No external linkage** — no references to `/opt/homebrew`, `/usr/local`,
   `/opt/local`, or any absolute path outside the `.app`; only macOS-provided
   libraries under `/usr/lib` and `/System` are allowed.
4. **Code signature** validity.

Spot-check manually any time:

```bash
lipo -info dist/Okular.app/Contents/MacOS/okular         # -> arm64 x86_64
vtool -show-build dist/Okular.app/Contents/MacOS/okular  # -> minos 11.0
otool -L dist/Okular.app/Contents/MacOS/okular           # -> @rpath / @executable_path only
```

The truest test is to run it on a **real, clean macOS 11 machine** (or a Big Sur
VM) with no developer tools installed.

---

## 7. Distribution notes (Gatekeeper)

The build ad-hoc-signs the app so it runs locally. To hand it to other people
without the "damaged / unidentified developer" warning you must sign with a
**Developer ID Application** certificate and **notarize**:

```bash
SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./04-merge-universal.sh
xcrun notarytool submit dist/Okular-*.dmg --apple-id you@example.com \
      --team-id TEAMID --password "app-specific-pw" --wait
xcrun stapler staple dist/Okular.app
```

Re-run `lipo`/audit *before* notarization — `lipo` invalidates signatures, which
is why step 4 re-signs after fusing.

---

## 8. Honest caveats

This is a genuinely demanding build, and a few parts are at the edge of what
Craft does out of the box. Expect to iterate:

- **No binary cache → long builds.** Because the macOS-11 pin forces source
  builds (`--no-cache`), the first run compiles Qt (twice), KF, and large deps
  (LLVM, Boost, FFmpeg, Poppler, Ghostscript). Budget the better part of a day.
- **Qt 6.7.3 lives in Qt's archive.** The blueprint's default download URL 404s
  for this version; `02b-prefetch-qt-source.sh` pre-places the tarballs from
  `download.qt.io/archive/qt/6.7/6.7.3/` into Craft's `download/archives/` so the
  build finds them locally. If a Qt submodule isn't a standalone tarball, the
  prefetch skips it and Craft resolves it normally.
- **Old versions, current blueprints.** Okular 26.04 only appears in 2026-era
  blueprints, while Qt 6.7.3/KF 6.21 are older — a combination KDE never shipped
  together. Most builds fine, but a blueprint patch keyed to a newer Qt/KF may
  occasionally need adjusting. Build that one package alone to iterate quickly.
- **Universal cross-builds are the fragile part.** A handful of autotools-based
  dependencies (historically things like FFTW with hand-written x86 assembly)
  occasionally ignore the architecture flags during the x86_64 cross-pass. If one
  fails, build that single blueprint natively on an Intel Mac, or patch its
  blueprint, then re-run. `03-build-arch.sh` injects `-arch` flags to minimize
  this.
- **CraftBootstrap is mildly interactive.** `01-bootstrap-craft.sh` feeds it
  answers and then *force-patches* `CraftSettings.ini` to be authoritative, but if
  the bootstrap prompts change upstream you may need to run it once by hand and
  re-run the script (it will only re-patch on the second pass).
- **Version pinning depends on blueprint paths.** If Craft renames a blueprint,
  `02-pin-versions.sh` logs "could not pin … skipped" — check `craft --search`
  and update `qt6-modules.txt` / `kf6-frameworks.txt`.
- **First build is slow** (compiling Qt + KF twice). Subsequent rebuilds reuse
  Craft's caches.
- **Plasma/desktop integration backends** that only exist on Linux (KActivities,
  PipeWire, etc.) are intentionally absent — they have no macOS equivalent and
  aren't part of Okular's macOS feature set.

---

## 9. File map

```
okular/
├── README.md                  ← this document
└── build/
    ├── 00-config.sh             ← version matrix + paths (edit here)
    ├── 01-bootstrap-craft.sh    ← clone Craft, create both CraftRoots
    ├── 02-pin-versions.sh       ← pin Qt 6.7.3 / KF 6.21 / Okular 26.04
    ├── 02b-prefetch-qt-source.sh← pre-place Qt 6.7.3 source (archive-URL workaround)
    ├── 03-build-arch.sh         ← build the full stack from source for one arch
    ├── 04-merge-universal.sh    ← package each arch + lipo into one universal app
    ├── 05-audit-bundle.sh       ← macOS-11 / portability / no-Brew audit
    ├── build-all.sh             ← run the whole pipeline (CLEAN_ROOTS=1 default)
    ├── qt6-modules.txt          ← Qt 6 blueprints to pin
    ├── kf6-frameworks.txt       ← KDE Frameworks blueprints to pin (tiered paths)
    └── backends.txt             ← optional backend libraries to maximize features
```
