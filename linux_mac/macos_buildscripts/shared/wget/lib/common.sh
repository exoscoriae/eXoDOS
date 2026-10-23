# shellcheck shell=bash
# Shared helpers.  Written for the stock macOS /bin/bash 3.2:
#  - no associative arrays, no ${var,,}, no mapfile
#  - never "cmd | grep -q" under pipefail (SIGPIPE turns a match into failure)
#  - never "[ test ] && cmd" as a statement under set -e

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33mWARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# errexit stops a script without saying why; this ERR trap names the command
# that failed.  build.sh installs it with "set -E" so that it also applies in
# functions and subshells.
on_error() { # exit-status command line
	printf '\033[1;31mERROR:\033[0m command failed (exit %s) at line %s: %s\n' "$1" "$3" "$2" >&2
}
install_err_trap() { trap 'on_error $? "$BASH_COMMAND" $LINENO' ERR; }

# ------------------------------------------------------------ environment

# Remove anything a Homebrew/MacPorts/user setup could inject into a build.
scrub_environment() {
	local v
	for v in CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH LIBRARY_PATH \
		DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH DYLD_FRAMEWORK_PATH DYLD_INSERT_LIBRARIES \
		PKG_CONFIG_PATH PKG_CONFIG_SYSROOT_DIR PKG_CONFIG_LIBDIR ACLOCAL_PATH \
		CFLAGS CXXFLAGS CPPFLAGS OBJCFLAGS LDFLAGS LIBS CC CXX CPP LD AR RANLIB NM STRIP \
		MAKEFLAGS MFLAGS GNUMAKEFLAGS CONFIG_SITE PYTHONPATH PYTHONHOME PERL5LIB \
		HOMEBREW_PREFIX HOMEBREW_CELLAR HOMEBREW_REPOSITORY MACOSX_DEPLOYMENT_TARGET SDKROOT; do
		unset "$v"
	done
	export PATH=/usr/bin:/bin:/usr/sbin:/sbin
	export LC_ALL=C LANG=C
}

# ------------------------------------------------------------- downloads

# Print "name version file checksum url..." for NAME from sources.lock.
lock_line() {
	awk -v n="$1" '$1 == n && $1 !~ /^#/ { print; exit }' "$PROJECT_DIR/sources.lock"
}
pkg_version() { lock_line "$1" | awk '{ print $2 }'; }
pkg_file()    { lock_line "$1" | awk '{ print $3 }'; }

expand_url() {
	case "$1" in
	gnu:*)
		local p=${1#gnu:}
		echo "https://ftpmirror.gnu.org/$p https://ftp.gnu.org/gnu/$p https://mirrors.kernel.org/gnu/$p"
		;;
	gnupg:*)
		local p=${1#gnupg:}
		echo "https://gnupg.org/ftp/gcrypt/$p https://www.gnupg.org/ftp/gcrypt/$p https://mirrors.dotsrc.org/gcrypt/$p"
		;;
	*) echo "$1" ;;
	esac
}

file_hash() { # algo file
	/usr/bin/shasum -a "$1" "$2" | awk '{ print $1 }'
}

# Download NAME into $WORK_DIR/downloads and verify it.
fetch_source() {
	local name=$1 line version file check url urls target tmp algo want got tofu
	line=$(lock_line "$name")
	if [ -z "$line" ]; then die "no entry for '$name' in sources.lock"; fi
	set -- $line
	version=$2 file=$3 check=$4
	shift 4
	urls=""
	for url in "$@"; do urls="$urls $(expand_url "$url")"; done

	target="$WORK_DIR/downloads/$file"
	mkdir -p "$WORK_DIR/downloads"
	if [ ! -f "$target" ]; then
		tmp="$target.part"
		for url in $urls; do
			note "fetching $url"
			if /usr/bin/curl -fL --proto '=https' --proto-redir '=https' --retry 3 --retry-delay 2 \
				--connect-timeout 20 -o "$tmp" "$url"; then
				mv "$tmp" "$target"
				break
			fi
			rm -f "$tmp"
		done
		if [ ! -f "$target" ]; then die "could not download $file"; fi
	fi

	tofu="$PROJECT_DIR/checksums.tofu"
	if [ "$check" = "tofu" ]; then
		got=$(file_hash 256 "$target")
		want=""
		if [ -f "$tofu" ]; then
			want=$(awk -v f="$file" '$1 == f { print $2 }' "$tofu")
		fi
		if [ -z "$want" ]; then
			printf '%s %s\n' "$file" "$got" >> "$tofu"
			warn "$file: no published checksum known; recorded sha256 $got in checksums.tofu"
		elif [ "$want" != "$got" ]; then
			die "$file: sha256 $got does not match checksums.tofu ($want)"
		fi
	else
		algo=${check%%:*}
		want=${check#*:}
		case "$algo" in sha256) got=$(file_hash 256 "$target") ;; sha512) got=$(file_hash 512 "$target") ;; *) die "bad checksum spec for $name" ;; esac
		if [ "$got" != "$want" ]; then
			mv "$target" "$target.bad"
			die "$file: $algo mismatch (got $got, expected $want); moved to $target.bad"
		fi
	fi
}

# Extract NAME's tarball into DEST (replacing DEST).
extract_source() {
	local name=$1 dest=$2 file
	file="$WORK_DIR/downloads/$(pkg_file "$name")"
	rm -rf "$dest"
	mkdir -p "$dest"
	/usr/bin/tar -xf "$file" -C "$dest" --strip-components 1 || die "cannot extract $file"
}

# ------------------------------------------------------------- per arch

# Sets up the compiler environment for one architecture.  x86_64 objects are
# compiled by the native clang; configure test programs for x86_64 run under
# Rosetta 2, so no package is built in cross-compilation mode.
setup_arch() {
	ARCH=$1
	case "$ARCH" in
	arm64)  TRIPLE=aarch64-apple-darwin20 ;;
	x86_64) TRIPLE=x86_64-apple-darwin20 ;;
	*) die "unsupported architecture $ARCH" ;;
	esac
	PREFIX="$WORK_DIR/$ARCH/prefix"
	SRCROOT="$WORK_DIR/$ARCH/src"
	STAGE="$WORK_DIR/$ARCH/stage"
	STAMPS="$WORK_DIR/$ARCH/stamps"
	mkdir -p "$PREFIX/lib/pkgconfig" "$PREFIX/include" "$PREFIX/bin" "$SRCROOT" "$STAGE" "$STAMPS"

	local base="-isysroot $MACOS_SDK -mmacosx-version-min=$MACOS_MIN"
	export SDKROOT="$MACOS_SDK"
	export MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN"
	export PATH="$PREFIX/bin:$TOOLS/bin:/usr/bin:/bin:/usr/sbin:/sbin"
	export CC="/usr/bin/clang -arch $ARCH"
	export CXX="/usr/bin/clang++ -arch $ARCH"
	export OBJC="$CC"
	export CC_FOR_BUILD="/usr/bin/clang"
	export AR=/usr/bin/ar RANLIB=/usr/bin/ranlib NM=/usr/bin/nm STRIP=/usr/bin/strip
	# -Werror=unguarded-availability-new: using an API newer than macOS 11.0
	# without an availability check is an error, not a silent weak import.
	export CFLAGS="$base -O2 -ffile-prefix-map=$WORK_DIR=/wget2-build -Werror=unguarded-availability-new"
	export CXXFLAGS="$CFLAGS"
	export OBJCFLAGS="$CFLAGS"
	export CPPFLAGS="-I$PREFIX/include"
	export LDFLAGS="$base -L$PREFIX/lib"
	export PKG_CONFIG="$TOOLS/bin/pkg-config"   # wrapper: pkgconf --static
	export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
	unset PKG_CONFIG_PATH
}

# Standard autotools configure for a static library into $PREFIX.
ac_configure() {
	./configure --prefix="$PREFIX" --build="$TRIPLE" --host="$TRIPLE" \
		--enable-static --disable-shared --disable-dependency-tracking "$@"
}

# Signature of a recipe: its code, the compiler setup, and the content of
# every patch file it mentions.  A changed signature forces a rebuild.
recipe_signature() {
	local fn=$1 body f files=""
	body=$(type "$fn")
	for f in "$PROJECT_DIR"/patches/*.py; do
		case "$body" in *"$(basename "$f")"*) files="$files $f" ;; esac
	done
	case "$body" in *macos-bundle*) files="$files $PROJECT_DIR/patches/patchlib.py $PROJECT_DIR/patches/wget2-macos/"'*' ;; esac
	# data compiled into a library (e.g. the public suffix list)
	for f in "$DATA"/*; do
		[ -f "$f" ] || continue
		case "$body" in *"\$DATA/$(basename "$f")"*) files="$files $f" ;; esac
	done
	{
		echo "$body"
		echo "$CFLAGS|$CPPFLAGS|$LDFLAGS|$MACOS_SDK|$MACOS_MIN|$ENABLE_GNUPG|$ENABLE_DANE|$ENABLE_PQC"
		for f in $files; do cat "$f"; done
	} | /usr/bin/shasum -a 256 | awk '{ print $1 }'
}

# Run recipe function FN for package NAME with logging and a stamp file.
# The recipe runs in a subshell with errexit really active: never call
# build_pkg from an "if", "&&" or "||" context, which would disable errexit
# for everything inside.  Once one package is rebuilt, all packages after it
# (they are built in dependency order) are rebuilt too.
build_pkg() {
	local name=$1 fn=$2 version stamp logf rc sig
	version=$(pkg_version "$name")
	[ -n "$version" ] || version=local
	stamp="$STAMPS/$name"
	logf="$WORK_DIR/logs/$ARCH-$name.log"
	sig="$version-$(recipe_signature "$fn")"
	if [ "${REBUILD_REST:-0}" = 0 ] && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$sig" ]; then
		note "[$ARCH] $name $version: up to date"
		return 0
	fi
	log "[$ARCH] building $name $version"
	mkdir -p "$WORK_DIR/logs"
	rm -f "$stamp"
	# (the parent's ERR trap is suspended: the failure is reported below)
	trap - ERR
	set +e
	( set -eE -o pipefail; install_err_trap; "$fn" ) > "$logf" 2>&1
	rc=$?
	set -e
	install_err_trap
	if [ $rc -ne 0 ]; then
		tail -n 60 "$logf" >&2
		die "[$ARCH] $name failed (exit $rc); full log: $logf"
	fi
	echo "$sig" > "$stamp"
	REBUILD_REST=1
}

# Write a pkg-config file.  write_pc FILE NAME VERSION LIBS [REQUIRES_PRIVATE] [LIBS_PRIVATE]
write_pc() {
	cat > "$1" <<EOF
prefix=$PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: $2
Description: $2 (static, wget2 macOS bundle build)
Version: $3
Libs: -L\${libdir} $4
Requires.private: ${5:-}
Libs.private: ${6:-}
Cflags: -I\${includedir}
EOF
}

# Fail unless the files exist.
require_files() {
	local f
	for f in "$@"; do
		if [ ! -e "$f" ]; then die "expected file missing: $f"; fi
	done
}
