#!/bin/sh
# Rebuild every third-party library from source at MACOSX_DEPLOYMENT_TARGET=11.0.
# Runs inside the overlay image (see Dockerfile.rebuild). Recipes are the stock
# dockerized-bb lib-helpers; where both common and apple-common provide one, the
# apple-common (darwin-aware) version is used; our own packages/ overrides last.
set -e

[ -n "$DESTDIR" ] && [ -n "$PREFIX" ] || { echo "DESTDIR/PREFIX not set"; exit 1; }

echo ">>> Wiping MacPorts-sourced prefix: ${DESTDIR}"
rm -rf "${DESTDIR}"
mkdir -p "${DESTDIR}${PREFIX}"

SDK_PATH=$(ls -d ${TARGET_DIR}/SDK/MacOSX*.sdk 2>/dev/null | head -1)
# HOST is e.g. x86_64-apple-darwin25.2 or aarch64-apple-darwin25.2
ARCH=${HOST%%-*}
# CMake cross-builds need both of these; an empty CMAKE_SYSTEM_PROCESSOR breaks
# arch detection (libjpeg-turbo SIMD selection, among others)
DARWIN_CMAKE="-DCMAKE_SYSTEM_NAME=Darwin -DCMAKE_SYSTEM_PROCESSOR=${ARCH}"

build() {
    echo ">>> Building $1 (deployment target ${MACOSX_DEPLOYMENT_TARGET})"
    pkg=$1; shift
    sh /lib-helpers/packages/$pkg/build.sh "$@"
}

# --- base compression / images
build zlib
build bzip2
build libpng1.6
build libjpeg-turbo $DARWIN_CMAKE -DCMAKE_ASM_NASM_COMPILER=nasm
build giflib

# --- audio codecs
build libogg
build libvorbis
build libtheora
build flac
build libmad
build faad2
build mpeg2dec
build a52dec
build libmpcdec

# --- video
build libvpx

# --- text / gui
build freetype
build fribidi

# --- music
build libmikmod
build sonivox $DARWIN_CMAKE
build fluidsynth $DARWIN_CMAKE -DLIB_SUFFIX= -DCMAKE_FRAMEWORK_PATH=${SDK_PATH}/usr/lib

# --- extras
build discord-rpc $DARWIN_CMAKE
build retrowave $DARWIN_CMAKE

# --- SDL (our from-source recipe replaces the MacPorts shim)
build libsdl2
build libsdl2-net

# Some recipes (bzip2, notably) install directly into ${PREFIX} instead of
# ${DESTDIR}${PREFIX}; merge them into the prefix the linker actually uses.
if [ -d "${PREFIX}" ] && [ "$(ls -A "${PREFIX}" 2>/dev/null)" ]; then
    echo ">>> Merging ${PREFIX} into ${DESTDIR}${PREFIX}"
    cp -a "${PREFIX}/." "${DESTDIR}${PREFIX}/"
fi

# ScummVM's configure (2.3-2.8 era) hardcodes -lglib-2.0 -lintl -lreadline for
# static FluidSynth on macOS, assuming the old glib-based FluidSynth. Ours is
# glib-free (osal=embedded), so no glib symbols are referenced -- provide empty
# stub archives to satisfy the link.
mkdir -p "${DESTDIR}${PREFIX}/lib"
# Apple ar refuses zero-member archives, so give the stubs one empty object.
STUB_TMP=$(mktemp -d)
: > "${STUB_TMP}/scummvm_stub.c"
"${TARGET_DIR}/bin/${HOST}-cc" ${CFLAGS} -c "${STUB_TMP}/scummvm_stub.c" -o "${STUB_TMP}/scummvm_stub.o"
for stub in glib-2.0 intl readline; do
    if [ ! -f "${DESTDIR}${PREFIX}/lib/lib${stub}.a" ]; then
        echo ">>> Creating stub lib${stub}.a"
        "${TARGET_DIR}/bin/${HOST}-ar" cr "${DESTDIR}${PREFIX}/lib/lib${stub}.a" "${STUB_TMP}/scummvm_stub.o"
        "${TARGET_DIR}/bin/${HOST}-ranlib" "${DESTDIR}${PREFIX}/lib/lib${stub}.a" || true
    fi
done
rm -rf "${STUB_TMP}"

echo ">>> All libraries rebuilt for macOS ${MACOSX_DEPLOYMENT_TARGET}+"
