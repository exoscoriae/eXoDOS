#!/usr/bin/env bash
#
# 03-build-arch.sh <arch> — build the full Okular stack for ONE architecture.
#
#   ./03-build-arch.sh arm64
#   ./03-build-arch.sh x86_64
#
# Builds Qt 6.7.3 -> KF 6.21 -> backend libraries -> Okular 26.04 into the
# architecture's CraftRoot, with the macOS deployment target forced to 11.0.
# On Apple Silicon the x86_64 pass is a cross-build (arch flags are injected).
# ---------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"
THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ARCH="${1:-}"
[[ -n "$ARCH" ]] || die "usage: $0 <arm64|x86_64>"
ROOT="$(craft_root_for "$ARCH")"
[[ -f "$ROOT/etc/CraftSettings.ini" ]] || die "Root for $ARCH not bootstrapped/pinned. Run 01 and 02 first."

# Force deployment target for clang (autotools deps) and CMake alike.
export MACOSX_DEPLOYMENT_TARGET

# ---------------------------------------------------------------------------
# Toolchain-gap relaxations (macOS 26 / Clang 21 building 2024-era Qt 6.7.3)
# ---------------------------------------------------------------------------
# The host toolchain is ~2 years newer than the newest macOS-11-capable Qt, so
# strict new-Clang diagnostics become hard errors. Demote the ones that aren't
# real bugs back to warnings. These apply to every arch and every package; Qt's
# own -Werror is removed separately via WARNINGS_ARE_ERRORS=OFF (02c).
TOOLCHAIN_RELAX="-Wno-error=implicit-function-declaration -Wno-error=incompatible-function-pointer-types -Wno-error=int-conversion -Wno-error=implicit-int"
export CFLAGS="${CFLAGS:-} $TOOLCHAIN_RELAX"
export CXXFLAGS="${CXXFLAGS:-} -Wno-error=implicit-function-declaration"
export OBJCFLAGS="${OBJCFLAGS:-} $TOOLCHAIN_RELAX"
export OBJCXXFLAGS="${OBJCXXFLAGS:-} -Wno-error=implicit-function-declaration"

# Host CMake is 4.x, which removed compatibility with cmake_minimum_required(<3.5).
# Many 2024-era KDE sources still declare an ancient minimum in example/test subdirs
# (e.g. threadweaver's examples/HelloWorld), so configure aborts. CMake honors this
# env var globally (>=3.31) to treat such projects as if they required 3.5 — one
# lever for every CMake package instead of per-blueprint patching.
export CMAKE_POLICY_VERSION_MINIMUM="3.5"

# For a cross x86_64 build on Apple Silicon, coerce stubborn autotools packages
# (those that ignore CMAKE_OSX_ARCHITECTURES) onto the right slice.
if [[ "$ARCH" == "x86_64" && "$(uname -m)" == "arm64" ]]; then
  log "Configuring x86_64 cross-build flags (host is Apple Silicon)."
  export CFLAGS="${CFLAGS:-} -arch x86_64"
  export CXXFLAGS="${CXXFLAGS:-} -arch x86_64"
  export OBJCFLAGS="${OBJCFLAGS:-} -arch x86_64"
  export OBJCXXFLAGS="${OBJCXXFLAGS:-} -arch x86_64"
  export LDFLAGS="${LDFLAGS:-} -arch x86_64"
fi

run_craft() {
  ( set +u
    scrub_brew_env
    # Re-export the build flags after scrubbing (scrub only clears *_PATH vars).
    export CFLAGS CXXFLAGS OBJCFLAGS OBJCXXFLAGS LDFLAGS CMAKE_POLICY_VERSION_MINIMUM
    # shellcheck disable=SC1091
    source "$ROOT/craft/craftenv.sh"
    craft "$@"
  )
}

# NOTE: we deliberately do NOT run `craft --update craft` here. That would git-pull
# craft-blueprints-kde and revert 02d's edit to kde/frameworks/version.ini (which
# makes KF 6.21 a valid target). The blueprints are intentionally frozen + patched.

# CRITICAL: $CRAFT_NOCACHE_FLAG (--no-cache) forces SOURCE builds. Without it,
# Craft would pull macOS-12 prebuilt binaries from files.kde.org and contaminate
# the bundle. Everything that lands in the app must be compiled here at target 11.
log "[$ARCH] Building FROM SOURCE ($CRAFT_NOCACHE_FLAG). This takes hours — Qt, KF, LLVM, Boost, FFmpeg, Poppler all compile."

# --- 1. Backend dependency libraries (maximize enabled backends) --------------
log "[$ARCH] Building backend dependency libraries from source"
while IFS= read -r line; do
  line="${line%%#*}"; line="$(echo "$line" | xargs)"
  [[ -z "$line" ]] && continue
  log "[$ARCH]   $line"
  run_craft $CRAFT_NOCACHE_FLAG "$line" || warn "[$ARCH] $line failed/optional — Okular will skip that backend. Review log above."
done < "$THIS_DIR/backends.txt"

# --- 2. Okular (pulls Qt 6.7.3 + KF 6.21 transitively, then builds Okular) -----
log "[$ARCH] Building $OKULAR_BLUEPRINT from source (the long one — Qt + KF + Okular)"
run_craft $CRAFT_NOCACHE_FLAG "$OKULAR_BLUEPRINT"

# --- 3. Sanity check: did anything land with a too-new deployment target? -----
log "[$ARCH] Quick deployment-target spot check on the Okular binary"
OKBIN="$ROOT/Applications/KDE/okular.app/Contents/MacOS/okular"
if [[ -x "$OKBIN" ]]; then
  vtool -show-build "$OKBIN" 2>/dev/null | grep -i -E 'minos|platform' || \
    otool -l "$OKBIN" | grep -A3 -i 'LC_BUILD_VERSION|LC_VERSION_MIN_MACOSX' || true
else
  warn "okular.app not found at expected path: $OKBIN (check the build log / Craft layout)."
fi

log "[$ARCH] Build complete. Root: $ROOT"
