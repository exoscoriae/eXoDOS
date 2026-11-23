#!/bin/bash
# Set up the dockerized-bb toolchains and the macOS-11 "rebuild" overlay images.
# Run once; safe to re-run (idempotent).
set -euo pipefail
cd "$(dirname "$0")"

DBB_DIR=dockerized-bb
DBB_REPO=https://github.com/scummvm/dockerized-bb.git
PLATFORM=linux/amd64   # toolchain images are amd64; Docker Desktop runs them via Rosetta

# ---------------------------------------------------------------- docker daemon up?
if ! docker info >/dev/null 2>&1; then
    echo "ERROR: Docker daemon is not running."
    echo "Start Docker Desktop (open /Applications/Docker.app), wait for it to"
    echo "finish starting, then re-run ./setup.sh"
    exit 1
fi

# ---------------------------------------------------------------- clone
if [ ! -d "$DBB_DIR/.git" ]; then
    git clone "$DBB_REPO" "$DBB_DIR"
fi

# ---------------------------------------------------------------- patch: drop i386 SDK requirement
# We don't build i386, so we don't want to require the huge Xcode 9.4.1 download.
SDKS_M4="$DBB_DIR/toolchains/apple-sdks/Dockerfile.m4"
if grep -q "I386_XCODE_VERSION" "$SDKS_M4"; then
    python3 - "$SDKS_M4" <<'EOF'
import re, sys
p = sys.argv[1]
t = open(p).read()
# Remove the block extracting the last i386-capable Xcode (define + COPY + local_package)
t = re.sub(r"m4_dnl Use a define[^\n]*\n"
           r"m4_define\(`I386_XCODE_VERSION'[^\n]*\n"
           r"# Extract last MacOS X SDK[^\n]*\n"
           r"COPY Xcode_`'I386_XCODE_VERSION[^\n]*\n"
           r"local_package\(xcode-extractor[^\n]*I386[^\n]*\n\n?",
           "", t)
open(p, "w").write(t)
print("patched", p)
EOF
fi

# ---------------------------------------------------------------- patch: skip ALL library builds in the base toolchain
# The stock toolchain downloads prebuilt MacPorts binaries (now failing: the
# MacPorts servers pruned old darwin_13 x86_64 packages) and source-builds
# other libs. Our overlay wipes the prefix and rebuilds every library from
# source at deployment target 11.0, so none of the base image's library steps
# are needed. No-op them: faster, and zero MacPorts involvement anywhere.
M4_APPLE="$DBB_DIR/toolchains/m4/apple/macosx.m4"
if ! grep -q "macos11-overlay" "$M4_APPLE"; then
    python3 - "$M4_APPLE" \
        "$DBB_DIR/toolchains/macosx-x86_64/Dockerfile.m4" \
        "$DBB_DIR/toolchains/macosx-arm64/Dockerfile.m4" <<'EOF'
import re, sys

# macosx.m4: no-op the two library-building macros, drop the SDL2 ports shim.
p = sys.argv[1]
t = open(p).read()
t = re.sub(r"m4_define\(`helpers_package',[^\n]*\n",
           "m4_dnl macos11-overlay: library builds skipped; overlay rebuilds from source\n"
           "m4_define(`helpers_package',`')m4_dnl\n", t, count=1)
t = re.sub(r"m4_define\(`ports_package',[^\n]*\n",
           "m4_define(`ports_package',`')m4_dnl\n", t, count=1)
t = re.sub(r"\n# This is a shim package[^\n]*\ncommon_package\(libsdl2\)\n", "\n", t)
open(p, "w").write(t)
print("patched", p)

# Per-arch Dockerfiles: drop the Sparkle framework (unused: updates disabled).
for p in sys.argv[2:]:
    t = open(p).read()
    t = re.sub(r"\ncommon_package\(sparkle\)\n", "\n", t)
    open(p, "w").write(t)
    print("patched", p)
EOF
fi

# ---------------------------------------------------------------- check the Xcode xip is present
XCODE_VERSION=$(sed -n "s/^m4_define(\`XCODE_VERSION', *\(.*\))$/\1/p" "$SDKS_M4" | tail -1)
SDKS_DIR="$DBB_DIR/toolchains/apple-sdks"
# Apple names the download Xcode_<ver>_Universal.xip; the Dockerfile expects
# Xcode_<ver>.xip — rename it to the expected form.
if [ -f "$SDKS_DIR/Xcode_${XCODE_VERSION}_Universal.xip" ] && \
   [ ! -f "$SDKS_DIR/Xcode_${XCODE_VERSION}.xip" ]; then
    echo ">>> Renaming Xcode_${XCODE_VERSION}_Universal.xip -> Xcode_${XCODE_VERSION}.xip"
    mv "$SDKS_DIR/Xcode_${XCODE_VERSION}_Universal.xip" "$SDKS_DIR/Xcode_${XCODE_VERSION}.xip"
fi
if ! ls "$DBB_DIR/toolchains/apple-sdks/Xcode_${XCODE_VERSION}.xip"* >/dev/null 2>&1; then
    echo "ERROR: Xcode_${XCODE_VERSION}.xip not found in $DBB_DIR/toolchains/apple-sdks/"
    echo "Download it from https://developer.apple.com/download/all/ and place it there."
    exit 1
fi

# ---------------------------------------------------------------- build stock toolchain images
# TOOLCHAINS_RESTRICTED guards Apple-SDK images; enable them explicitly.
make -C "$DBB_DIR" \
    TOOLCHAINS_RESTRICTED= \
    DOCKER_DEFAULT_PLATFORM=$PLATFORM \
    toolchains/apple-sdks toolchains/macosx-x86_64 toolchains/macosx-arm64

# ---------------------------------------------------------------- build overlay images
# The overlay wipes the MacPorts-sourced prefix and rebuilds every library from
# source with MACOSX_DEPLOYMENT_TARGET=11.0.
for arch in x86_64 arm64; do
    docker build --platform=$PLATFORM \
        --build-arg BASE_ARCH=$arch \
        -t scummvm-macos11-$arch \
        -f docker/Dockerfile.rebuild docker/
done

echo
echo "Setup complete. Images: scummvm-macos11-x86_64, scummvm-macos11-arm64"
echo "Next: ./build-all.sh"
