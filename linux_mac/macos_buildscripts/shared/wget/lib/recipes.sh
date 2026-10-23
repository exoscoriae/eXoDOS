# shellcheck shell=bash
# One recipe per package, in dependency order (see PACKAGES in build.sh).
# Each recipe runs in a subshell (build_pkg) with the per-architecture
# environment from setup_arch, starting from a freshly extracted source tree.
# Every library is built static-only; the final executables link nothing but
# libSystem and a few system frameworks.

prep() { # fresh source tree for NAME and cd into it
	extract_source "$1" "$SRCROOT/$1"
	cd "$SRCROOT/$1"
}

patch_src() { # run a patcher from patches/ on the current directory
	/usr/bin/python3 -I -B "$PROJECT_DIR/patches/$1" .
}

mk() { make -j"$JOBS" "$@"; }

# Fail if config.h defines any of the given macros.
refute_defines() {
	local header=$1 m
	shift
	for m in "$@"; do
		if grep -E "^#define $m( |$)" "$header" >/dev/null; then
			die "$header: $m is defined, but macOS 11 does not have it - a configure check was misled"
		fi
	done
}

# Fail unless config.h defines all of the given macros.
require_defines() {
	local header=$1 m
	shift
	for m in "$@"; do
		if ! grep -E "^#define $m( |$)" "$header" >/dev/null; then
			die "$header: $m is not defined - a feature was not detected (see config.log)"
		fi
	done
}

# ----------------------------------------------------------------- compression

r_zlib() {
	prep zlib
	# zlib's hand-written configure takes CC/CFLAGS/LDFLAGS from the environment
	CC=/usr/bin/clang CFLAGS="-arch $ARCH $CFLAGS" LDFLAGS="-arch $ARCH $LDFLAGS" \
		./configure --prefix="$PREFIX" --static
	mk libz.a
	make install
	require_files "$PREFIX/lib/libz.a" "$PREFIX/lib/pkgconfig/zlib.pc"
}

r_bzip2() {
	prep bzip2
	mk libbz2.a CC="/usr/bin/clang -arch $ARCH" AR="$AR" RANLIB="$RANLIB" \
		CFLAGS="$CFLAGS -D_FILE_OFFSET_BITS=64 -Wall"
	install -d "$PREFIX/lib" "$PREFIX/include"
	install -m 644 libbz2.a "$PREFIX/lib/"
	install -m 644 bzlib.h "$PREFIX/include/"
	write_pc "$PREFIX/lib/pkgconfig/bzip2.pc" bzip2 "$(pkg_version bzip2)" "-lbz2"
}

r_xz() {
	prep xz
	ac_configure --disable-xz --disable-xzdec --disable-lzmadec --disable-lzmainfo \
		--disable-lzma-links --disable-scripts --disable-doc --disable-nls
	mk
	make install
	require_files "$PREFIX/lib/liblzma.a"
}

r_zstd() {
	prep zstd
	mk -C lib libzstd.a
	make -C lib install-static install-includes install-pc PREFIX="$PREFIX" prefix="$PREFIX"
	require_files "$PREFIX/lib/libzstd.a" "$PREFIX/lib/pkgconfig/libzstd.pc"
}

r_brotli() {
	# Brotli only ships a CMake build; compile the C library directly instead
	# of bootstrapping CMake.
	prep brotli
	local part f
	for part in common dec enc; do
		mkdir -p "obj/$part"
		for f in c/$part/*.c; do
			$CC $CFLAGS -Ic/include -c "$f" -o "obj/$part/$(basename "$f" .c).o"
		done
		rm -f "libbrotli$part.a"
		$AR rcs "libbrotli$part.a" obj/$part/*.o
		install -m 644 "libbrotli$part.a" "$PREFIX/lib/"
	done
	install -d "$PREFIX/include/brotli"
	install -m 644 c/include/brotli/*.h "$PREFIX/include/brotli/"
	local v
	v=$(pkg_version brotli)
	write_pc "$PREFIX/lib/pkgconfig/libbrotlicommon.pc" libbrotlicommon "$v" "-lbrotlicommon"
	write_pc "$PREFIX/lib/pkgconfig/libbrotlidec.pc" libbrotlidec "$v" "-lbrotlidec" libbrotlicommon
	write_pc "$PREFIX/lib/pkgconfig/libbrotlienc.pc" libbrotlienc "$v" "-lbrotlienc" libbrotlicommon
}

r_lzlib() {
	prep lzlib
	./configure --prefix="$PREFIX" CC=/usr/bin/clang CFLAGS="-arch $ARCH $CFLAGS" \
		CPPFLAGS="$CPPFLAGS" LDFLAGS="-arch $ARCH $LDFLAGS"
	mk liblz.a
	install -m 644 liblz.a "$PREFIX/lib/"
	install -m 644 lzlib.h "$PREFIX/include/"
	write_pc "$PREFIX/lib/pkgconfig/liblz.pc" liblz "$(pkg_version lzlib)" "-llz"
}

# ---------------------------------------------------------------- text / i18n

r_libiconv() {
	prep libiconv
	ac_configure --disable-nls --enable-extra-encodings
	mk
	make install
	require_files "$PREFIX/lib/libiconv.a" "$PREFIX/include/iconv.h"
}

r_libunistring() {
	prep libunistring
	ac_configure --with-libiconv-prefix="$PREFIX"
	mk
	make install
}

r_gettext() {
	# only gettext-runtime: provides libintl for wget2's translations
	prep gettext
	cd gettext-runtime
	# gettext 1.0 renamed --with-included-gettext to --with-included-libintl.
	# The language-binding switches keep configure from probing compilers;
	# on macOS, probing /usr/bin/javac pops up a "install a JDK" dialog.
	# libintl compiles in LOCALEDIR as the fallback catalog directory; keep the
	# build directory out of the binary (wget2 binds its own domain to the
	# bundle's Resources/locale) and install into $PREFIX as usual.
	ac_configure --with-libiconv-prefix="$PREFIX" --with-included-libintl \
		--disable-libasprintf --disable-java --disable-csharp --disable-d --disable-modula2 \
		--localedir=/usr/share/locale
	mk
	make install localedir="$PREFIX/share/locale"
	require_files "$PREFIX/lib/libintl.a" "$PREFIX/include/libintl.h"
}

r_libidn2() {
	prep libidn2
	ac_configure --with-libiconv-prefix="$PREFIX" --with-libunistring-prefix="$PREFIX" \
		--disable-doc --disable-nls --disable-valgrind-tests
	mk
	make install
}

r_pcre2() {
	prep pcre2
	ac_configure --enable-pcre2-8 --disable-pcre2-16 --disable-pcre2-32 --enable-unicode \
		--disable-jit --disable-pcre2grep-libz --disable-pcre2grep-libbz2 --disable-pcre2test-libedit
	mk
	make install
}

# ------------------------------------------------------------------ TLS stack

r_libtasn1() {
	prep libtasn1
	ac_configure --disable-doc --disable-valgrind-tests
	mk
	make install
}

r_gmp() {
	# The generic host triplet selects the baseline x86_64/arm64 assembly,
	# never code tuned to the build machine's CPU.
	prep gmp
	CFLAGS="$CFLAGS -std=gnu17" ac_configure --with-pic --disable-cxx
	mk
	make install
	require_files "$PREFIX/lib/libgmp.a"
}

r_nettle() {
	# --enable-fat (default): optimised code paths chosen at run time
	prep nettle
	ac_configure --disable-documentation --disable-openssl --enable-fat \
		--with-include-path="$PREFIX/include" --with-lib-path="$PREFIX/lib"
	mk
	make install
	require_files "$PREFIX/lib/libnettle.a" "$PREFIX/lib/libhogweed.a" "$PREFIX/lib/pkgconfig/hogweed.pc"
}

r_expat() {
	prep expat
	ac_configure --without-docbook --without-examples --without-tests --without-xmlwf
	mk
	make install
}

r_unbound() {
	# libunbound only (the DNSSEC resolver behind libgnutls-dane), with nettle
	# as crypto backend
	prep unbound
	patch_src unbound-1.26.2-macos-getentropy.py
	# -fno-common: Apple clang still emits uninitialised globals (here the
	# config lexer's yytext, yyleng, ...) as common symbols, which the
	# partial link below cannot make local - and which a static link would
	# silently merge with same-named globals of other libraries
	CFLAGS="$CFLAGS -fno-common"
	ac_configure --sysconfdir=/etc --with-libunbound-only --with-nettle="$PREFIX" \
		--with-libexpat="$PREFIX" --with-pthreads --without-pyunbound --without-pythonmodule \
		--without-libevent --disable-flto
	mk
	make install
	require_files "$PREFIX/lib/libunbound.a" "$PREFIX/lib/pkgconfig/libunbound.pc"
	# libunbound's internals are global under generic names (log_init,
	# verbose, ...) and clash with wget2's own; keep only its official API
	local d="$PWD/prelink" n
	rm -rf "$d"
	mkdir -p "$d"
	/usr/bin/nm -gU "$PREFIX/lib/libunbound.a" | awk 'NF == 3 { print $3 }' | sort -u > "$d/defined.txt"
	tr -d '\r' < libunbound/ubsyms.def | sed -n 's/^\(ub_[A-Za-z0-9_]*\)$/_\1/p' | sort -u \
		| comm -12 - "$d/defined.txt" > "$d/exports.txt"
	n=$(wc -l < "$d/exports.txt")
	if [ "$n" -lt 30 ]; then die "libunbound: only $n of the ubsyms.def API symbols found"; fi
	prelink_static_lib "$PREFIX/lib/libunbound.a" "$d/exports.txt"
}

# meson machine file for leancrypto (meson ignores CFLAGS for cross builds)
meson_machine_file() {
	/usr/bin/python3 -I - "$1" "$ARCH" "$CFLAGS $CPPFLAGS" "$LDFLAGS" "$TOOLS/bin/pkg-config" <<'PY'
import shlex, sys
out, arch, cflags, ldflags, pkgconfig = sys.argv[1:]
q = lambda a: "'" + a.replace("\\", "\\\\").replace("'", "\\'") + "'"
arr = lambda l: "[" + ", ".join(q(a) for a in l) + "]"
with open(out, "w") as f:
    f.write("[binaries]\n")
    f.write("c = %s\n" % arr(["/usr/bin/clang", "-arch", arch]))
    f.write("ar = '/usr/bin/ar'\nstrip = '/usr/bin/strip'\npkg-config = %s\n" % q(pkgconfig))
    f.write("\n[built-in options]\n")
    f.write("c_args = %s\n" % arr(shlex.split(cflags)))
    f.write("c_link_args = %s\n" % arr(shlex.split(ldflags)))
    if arch == "x86_64":
        f.write("\n[properties]\nneeds_exe_wrapper = false\n")
        f.write("\n[host_machine]\nsystem = 'darwin'\nkernel = 'xnu'\ncpu_family = 'x86_64'\ncpu = 'x86_64'\nendian = 'little'\n")
PY
}

r_leancrypto() {
	prep leancrypto
	patch_src leancrypto-1.9.1-macos11-sdk.py
	local mf="$PWD/machine-$ARCH.ini" kind=--native-file
	# leancrypto switches on LTO for itself; plain objects are needed for
	# the partial link below (-fno-lto comes after its -flto=auto)
	CFLAGS="$CFLAGS -fno-lto"
	meson_machine_file "$mf"
	if [ "$ARCH" = x86_64 ]; then kind=--cross-file; fi
	env -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS -u CC -u CXX \
		"$TOOLS/bin/meson" setup build "$kind" "$mf" --prefix="$PREFIX" --libdir=lib \
		--buildtype=release --default-library=static -Dstrip=false \
		-Dapps=disabled -Dtests=disabled
	"$TOOLS/bin/ninja" -C build -j "$JOBS"
	"$TOOLS/bin/ninja" -C build install
	require_files "$PREFIX/lib/libleancrypto.a" "$PREFIX/lib/pkgconfig/leancrypto.pc"
	leancrypto_localize
}

# Partial link ("single-object prelink") of static library LIB that keeps
# only the symbols listed in EXPORTS (sorted, one per line, with the leading
# underscore) global; every other symbol becomes local to the library.
# All static libraries end up in one global namespace, and some export their
# internal helpers under generic names that clash with other code.  Stops the
# build if any symbol outside EXPORTS is still global afterwards.
prelink_static_lib() { # lib exports-file
	local lib=$1 exports=$2 d extra
	d=$(dirname "$exports")
	printf 'static int prelink_unused;\n' > "$d/empty.c"
	$CC $CFLAGS -c "$d/empty.c" -o "$d/empty.o"
	$CC $CFLAGS $LDFLAGS -nostdlib -r -o "$d/prelinked.o" "$d/empty.o" \
		-Wl,-force_load,"$lib" -Wl,-exported_symbols_list,"$exports"
	rm -f "$lib"
	"$AR" rc "$lib" "$d/prelinked.o"
	"$RANLIB" "$lib"
	extra=$(/usr/bin/nm -gU "$lib" | awk 'NF == 3 { print $3 }' | sort -u | comm -23 - "$exports")
	if [ -n "$extra" ]; then die "$(basename "$lib"): symbols outside its API are still global: $(echo $extra)"; fi
	note "$(basename "$lib"): $(wc -l < "$exports" | tr -d ' ') API symbols global, internals made local"
}

# leancrypto marks its internals hidden, but a static link ignores that, so
# they clash with same-named functions elsewhere: gf_mul in libgcrypt (GnuPG's
# dirmngr links both) and the OpenSSL-derived aes_v8_* of GnuTLS's own ARM64
# assembly, which could even bind one library's calls to the other's code.
# Its API is every default-visibility lc_* symbol.
leancrypto_localize() {
	local lib="$PREFIX/lib/libleancrypto.a" d="$PWD/prelink" n
	rm -rf "$d"
	mkdir -p "$d"
	/usr/bin/nm -m "$lib" | awk '!/undefined/ && /\) external _lc_/ { print $NF }' | sort -u > "$d/exports.txt"
	n=$(wc -l < "$d/exports.txt")
	if [ "$n" -lt 500 ]; then die "leancrypto: only $n public lc_* symbols found"; fi
	rm -f "$PREFIX/lib/libleancrypto-raw.a" "$PREFIX/lib/libleancrypto-fips.a"
	prelink_static_lib "$lib" "$d/exports.txt"
}

r_gnutls() {
	prep gnutls
	patch_src gnutls-3.8.13-macos-keychain-trust.py
	patch_src gnutls-3.8.13-trust-list-blocklist.py
	patch_src gnutls-3.8.13-dane-root-key-env.py
	local extra="" want="HAVE_ZLIB HAVE_LIBBROTLI HAVE_LIBZSTD HAVE_LIBIDN2"
	if [ "$ENABLE_DANE" = 1 ]; then
		# configure links its libunbound probe with "$oldlibs -lunbound" but
		# never sets oldlibs; with a static libunbound the probe needs
		# unbound's own dependencies, otherwise DANE is silently disabled.
		export oldlibs
		oldlibs="$($PKG_CONFIG --libs libunbound)"
		extra="$extra --enable-libdane --with-unbound-root-key-file=/etc/unbound/root.key"
		want="$want HAVE_DANE"
	else
		extra="$extra --disable-libdane"
	fi
	if [ "$ENABLE_PQC" = 1 ]; then
		extra="$extra --with-leancrypto"
		want="$want HAVE_LEANCRYPTO"
	fi
	# shellcheck disable=SC2086
	ac_configure --sysconfdir=/etc --disable-doc --disable-manpages --disable-tools \
		--disable-tests --disable-full-test-suite --disable-cxx --disable-nls \
		--without-p11-kit --without-tpm --without-tpm2 \
		--with-zlib=link --with-brotli=link --with-zstd=link \
		--with-libiconv-prefix="$PREFIX" --with-libunistring-prefix="$PREFIX" $extra
	# shellcheck disable=SC2086
	require_defines config.h $want
	mk
	make install
	if [ "$ENABLE_DANE" = 1 ]; then
		# make "pkg-config --static gnutls-dane" pull in libunbound's dependencies
		sed -i '' 's/^Requires.private: gnutls$/Requires.private: gnutls, libunbound/' "$PREFIX/lib/pkgconfig/gnutls-dane.pc"
		grep 'Requires.private: gnutls, libunbound' "$PREFIX/lib/pkgconfig/gnutls-dane.pc" >/dev/null \
			|| die "could not fix gnutls-dane.pc"
	fi
}

# ------------------------------------------------------------ HTTP / web data

r_nghttp2() {
	prep nghttp2
	ac_configure --enable-lib-only
	mk
	make install
}

r_libpsl() {
	# public suffix list compiled in (fetched fresh for this build)
	prep libpsl
	PYTHON=/usr/bin/python3 ac_configure --enable-runtime=libidn2 --enable-builtin \
		--disable-man --disable-gtk-doc --with-psl-file="$DATA/public_suffix_list.dat" \
		--with-libiconv-prefix="$PREFIX"
	# libpsl 0.23 records the list's *base name* as the file psl_latest()
	# re-reads when it is newer than the built-in data - a path relative to
	# whatever directory wget2 runs in.  Blank it: the compiled-in list is
	# used.  (The tarball ships a pre-generated header; remove it so the list
	# fetched for this build is the one compiled in.)
	rm -f src/suffixes_dafsa.h
	make -C src suffixes_dafsa.h
	grep -F "$(shasum -a 1 "$DATA/public_suffix_list.dat" | cut -d' ' -f1)" src/suffixes_dafsa.h >/dev/null \
		|| die "suffixes_dafsa.h was not generated from $DATA/public_suffix_list.dat"
	sed -i '' 's/^static const char _psl_filename\[\] = ".*";$/static const char _psl_filename[] = "";/' src/suffixes_dafsa.h
	grep -F 'static const char _psl_filename[] = "";' src/suffixes_dafsa.h >/dev/null \
		|| die "could not neutralise _psl_filename in suffixes_dafsa.h"
	mk
	make install
}

r_libhsts() {
	prep libhsts
	PYTHON=/usr/bin/python3 ac_configure --disable-doc --disable-nls
	mk
	make install
	require_files "$PREFIX/lib/libhsts.a" "$PREFIX/include/libhsts.h"
}

# ---------------------------------------------------------------- GnuPG stack

r_sqlite() {
	# autosetup-based configure: plain CC, architecture via the flags
	prep sqlite
	CC=/usr/bin/clang CFLAGS="-arch $ARCH $CFLAGS" LDFLAGS="-arch $ARCH $LDFLAGS" \
		./configure --prefix="$PREFIX" --disable-shared
	mk
	make install
	require_files "$PREFIX/lib/libsqlite3.a" "$PREFIX/lib/pkgconfig/sqlite3.pc"
}

r_libgpg_error() {
	prep libgpg-error
	# --sysconfdir=/etc: libgpg-error compiles its sysconfdir in (the fallback
	# for system config files); the default would be the build prefix
	ac_configure --sysconfdir=/etc --disable-nls --disable-doc --disable-tests --disable-languages
	mk
	make install
}

r_libgcrypt() {
	prep libgcrypt
	patch_src libgcrypt-1.12.4-darwin-aarch64-asm.py
	ac_configure --with-libgpg-error-prefix="$PREFIX" --disable-doc
	mk
	make install
}

r_libassuan() {
	prep libassuan
	ac_configure --with-libgpg-error-prefix="$PREFIX" --disable-doc
	mk
	make install
}

r_libksba() {
	prep libksba
	ac_configure --with-libgpg-error-prefix="$PREFIX"
	mk
	make install
}

r_npth() {
	prep npth
	ac_configure
	mk
	make install
}

r_gpgme() {
	prep gpgme
	patch_src gpgme-2.2.0-no-fallback-paths.py
	ac_configure --with-libgpg-error-prefix="$PREFIX" --with-libassuan-prefix="$PREFIX" \
		--disable-gpgconf-test --disable-gpg-test --disable-gpgsm-test --disable-g13-test
	mk
	make install
	require_files "$PREFIX/lib/libgpgme.a" "$PREFIX/lib/pkgconfig/gpgme.pc"
}

r_gnupg() {
	# The programs end up in wget.app/Contents/Resources/gnupg; the patch makes
	# them find each other relative to their own location.
	prep gnupg
	patch_src gnupg-2.5.24-relocatable.py
	CPPFLAGS="$CPPFLAGS -DGNUPG_MACOS_RELOCATABLE" ./configure \
		--prefix=/Applications/wget.app/Contents/Resources/gnupg \
		--sysconfdir=/etc --localstatedir=/var \
		--build="$TRIPLE" --host="$TRIPLE" --disable-dependency-tracking \
		--with-libgpg-error-prefix="$PREFIX" --with-libgcrypt-prefix="$PREFIX" \
		--with-libassuan-prefix="$PREFIX" --with-ksba-prefix="$PREFIX" --with-npth-prefix="$PREFIX" \
		--with-zlib="$PREFIX" --with-bzip2="$PREFIX" \
		--enable-sqlite --enable-gnutls --disable-ldap \
		--disable-scdaemon --disable-card-support --disable-ccid-driver --disable-tpm2d \
		--disable-g13 --disable-wks-tools --disable-gpgtar --disable-photo-viewers \
		--disable-doc --disable-nls --disable-tests --without-readline
	mk
	rm -rf "$STAGE/gnupg"
	make install DESTDIR="$STAGE/gnupg"
	require_files "$STAGE/gnupg/Applications/wget.app/Contents/Resources/gnupg/bin/gpg" \
		"$STAGE/gnupg/Applications/wget.app/Contents/Resources/gnupg/bin/gpgconf" \
		"$STAGE/gnupg/Applications/wget.app/Contents/Resources/gnupg/bin/gpg-agent" \
		"$STAGE/gnupg/Applications/wget.app/Contents/Resources/gnupg/libexec/keyboxd"
}

# ---------------------------------------------------------------------- wget2

r_wget2() {
	prep wget2
	patch_src wget2-2.3.0-backports.py
	patch_src wget2-2.3.0-macos-bundle.py

	local with="--with-ssl=gnutls" want=""
	if [ "$ENABLE_DANE" = 1 ]; then with="$with --with-libdane"; want="$want WITH_LIBDANE"
	else with="$with --without-libdane"; fi
	if [ "$ENABLE_GNUPG" = 1 ]; then with="$with --with-gpgme"; want="$want WITH_GPGME"
	else with="$with --without-gpgme"; fi

	# No extra LIBS for configure: gnulib's checks (first in configure)
	# would find its replacement functions inside the static libraries and
	# conclude that macOS has mempcpy, rawmemchr, ... - it does not.
	# shellcheck disable=SC2086
	# --prefix=/usr/local (overrides ac_configure's): only LOCALEDIR, the
	# fallback when the bundle has no Resources/locale, is compiled in.
	ac_configure --prefix=/usr/local --sysconfdir=/etc $with \
		--with-libpsl --with-libhsts --with-libnghttp2 --with-libidn2 --with-libpcre2 \
		--with-zlib --with-bzip2 --with-lzma --with-brotlidec --with-zstd --with-lzip \
		--without-libmicrohttpd --disable-doc --enable-xattr \
		--with-libiconv-prefix="$PREFIX" --with-libintl-prefix="$PREFIX"

	# shellcheck disable=SC2086
	require_defines config.h WITH_GNUTLS WITH_OCSP WITH_LIBPSL WITH_LIBHSTS WITH_LIBNGHTTP2 \
		WITH_LIBIDN2 WITH_LIBPCRE2 WITH_ZLIB WITH_BZIP2 WITH_LZMA WITH_BROTLIDEC WITH_ZSTD \
		WITH_LZIP ENABLE_NLS ENABLE_XATTR PLUGIN_SUPPORT HAVE_ICONV $want
	# glibc-only functions that macOS 11 lacks: gnulib must replace them
	refute_defines config.h HAVE_MEMPCPY HAVE_RAWMEMCHR HAVE_STRCHRNUL HAVE_MEMRCHR \
		HAVE_EXPLICIT_BZERO HAVE_PIPE2

	# wget2 2.3.0's configure.ac assigns GNULIB_LIBS (libintl + libiconv +
	# CoreFoundation for gettext, ...) with broken quoting, so it ends up
	# empty (fixed upstream after 2.3.0).  Rebuild it from the variables
	# configure did compute and hand it to make.
	local gl
	gl=$(awk -F' = ' '
		$1 ~ /^(CLOCK_TIME_LIB|GETADDRINFO_LIB|GETHOSTNAME_LIB|GETLOGIN_LIB|GETRANDOM_LIB|HARD_LOCALE_LIB|HOSTENT_LIB|INET_NTOP_LIB|INET_PTON_LIB|LIBMULTITHREAD|LIBSOCKET|LIBTHREAD|LIB_CRYPTO|LTLIBC32CONV|LTLIBICONV|LTLIBINTL|LTLIBUNISTRING|MBRTOWC_LIB|NANOSLEEP_LIB|POLL_LIB|POSIX_SPAWN_LIB|PTHREAD_SIGMASK_LIB|SELECT_LIB|SERVENT_LIB|SETLOCALE_LIB|SETLOCALE_NULL_LIB|INTL_MACOSX_LIBS)$/ && NF > 1 { printf "%s ", $2 }' src/Makefile)
	case "$gl" in *-lintl*|*libintl.a*) ;; *) die "could not reconstruct GNULIB_LIBS (no libintl): '$gl'" ;; esac
	note "GNULIB_LIBS: $gl"

	mk GNULIB_LIBS="$gl"
	rm -rf "$STAGE/wget2"
	make install DESTDIR="$STAGE/wget2" GNULIB_LIBS="$gl"
	require_files "$STAGE/wget2/usr/local/bin/wget2"

	# keep what the bundle needs from the source tree
	rm -rf "$STAGE/wget2-extra"
	mkdir -p "$STAGE/wget2-extra"
	local man
	man=$(find . -name wget2.1 -type f | sed -n 1p)
	if [ -n "$man" ]; then cp "$man" "$STAGE/wget2-extra/"; fi
}
