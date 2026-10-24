#! /bin/sh
# Same as the stock dockerized-bb recipe, but fetched from the official GitHub
# mirror -- gitlab.xiph.org frequently returns 502s. Tarball layout is
# identical (root dir theora-<sha>).

THEORA_VERSION=28fd5ec77f0ad0e07a371cef1047828116f6bd8a

PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HELPERS_DIR=$PACKAGE_DIR/../..
. $HELPERS_DIR/functions.sh

do_make_bdir

do_http_fetch theora "https://github.com/xiph/theora/archive/${THEORA_VERSION}.tar.gz" 'tar xzf'

# Avoid compiling and installing doc
sed -ie 's/^\(SUBDIRS.*\) doc/\1/' Makefile.am

autoreconf -fi -I m4
do_configure --disable-examples --disable-spec --disable-doc "$@"
do_make V=1
do_make install

do_clean_bdir
