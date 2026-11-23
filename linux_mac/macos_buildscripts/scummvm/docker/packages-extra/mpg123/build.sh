#! /bin/sh
# libmpg123 (dependency of libopenmpt; also linked directly by ScummVM's
# ports.mk USE_OPENMPT block). Built from Debian source like the other
# recipes. --with-cpu=generic avoids hand-written asm for maximum
# cross-compile reliability; only used for MO3-embedded MP3 samples.

PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HELPERS_DIR=$PACKAGE_DIR/../..
. $HELPERS_DIR/functions.sh

do_make_bdir

do_pkg_fetch mpg123

do_configure \
	--with-audio=dummy \
	--enable-modules=no \
	--with-cpu=generic \
	--disable-components --enable-libmpg123

do_make
do_make install

do_clean_bdir
