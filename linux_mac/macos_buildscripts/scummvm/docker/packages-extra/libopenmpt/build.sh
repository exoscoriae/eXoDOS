#! /bin/sh
# libopenmpt (tracker/MOD music; preferred over libmikmod by ScummVM 2.9+).
# Debian's orig tarball is the upstream autotools release, fetched with a
# pinned sha256. Needs zlib/ogg/vorbis (already in the prefix) and mpg123
# (built by the mpg123 recipe just before this one).

# NOTE: Debian's pool only keeps the orig tarball of the version currently in
# the archive -- when they upgrade, the old file 404s. If this fetch fails,
# check https://deb.debian.org/debian/pool/main/libo/libopenmpt/ for the new
# version and take its sha256 from the accompanying .dsc file.
OPENMPT_VERSION=0.8.10
OPENMPT_SHA256=976d259288c40cd285771f77d09eff3d02514511d5677ecfcfb53be5013317e2

PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HELPERS_DIR=$PACKAGE_DIR/../..
. $HELPERS_DIR/functions.sh

do_make_bdir

do_http_fetch libopenmpt \
	"https://deb.debian.org/debian/pool/main/libo/libopenmpt/libopenmpt_${OPENMPT_VERSION}.orig.tar.gz" \
	'tar xzf' "sha256:${OPENMPT_SHA256}"

# openmpt123 player, examples, tests and docs are not needed; portaudio,
# sndfile and flac are only used by those and are absent from the toolchain.
do_configure \
	--disable-openmpt123 \
	--disable-examples \
	--disable-tests \
	--disable-doxygen-doc \
	--without-portaudio \
	--without-portaudiocpp \
	--without-sndfile \
	--without-flac

do_make
do_make install

do_clean_bdir
