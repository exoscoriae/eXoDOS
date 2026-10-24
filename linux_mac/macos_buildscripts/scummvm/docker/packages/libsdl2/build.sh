#! /bin/sh
# SDL2 built from source for osxcross (replaces dockerized-bb's MacPorts shim),
# so the static library honors MACOSX_DEPLOYMENT_TARGET=11.0.

SDL2_VERSION=2.32.10

PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HELPERS_DIR=$PACKAGE_DIR/../..
. $HELPERS_DIR/functions.sh

do_make_bdir

do_http_fetch SDL2 \
	"https://github.com/libsdl-org/SDL/releases/download/release-${SDL2_VERSION}/SDL2-${SDL2_VERSION}.tar.gz" 'tar xzf'

# Static only; no X11 (native Cocoa/Metal backends come from the SDK)
do_configure \
	--enable-static --disable-shared \
	--without-x \
	--disable-render-d3d

do_make
do_make install

# Point sdl2-config at the cross prefix (same fix the stock shim applies)
sed -i -e "s#^prefix=.*\$#prefix=${DESTDIR}${PREFIX}#" ${DESTDIR}${PREFIX}/bin/sdl2-config

do_clean_bdir
