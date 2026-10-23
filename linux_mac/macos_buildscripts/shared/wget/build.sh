#!/bin/bash
# Build a portable, universal (arm64 + x86_64) GNU Wget2 for macOS 11+:
#   dist/wget.app/Contents/MacOS/wget
#
# No Homebrew, no MacPorts: every library is built from pinned, checksummed
# sources, statically, against the macOS 11 SDK.
#
# usage: ./build.sh [all|deps|app|audit|clean]
#   all    (default) dependencies, wget2, bundle, audit, smoke test
#   deps   only the per-architecture builds
#   app    bundle + audit + smoke test from finished per-arch builds
#   audit  re-run the Mach-O audit on dist/wget.app
#   clean  remove the per-architecture build trees (keeps downloads)
set -eEuo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.sh
. "$PROJECT_DIR/config.sh"
# shellcheck source=lib/common.sh
. "$PROJECT_DIR/lib/common.sh"
# shellcheck source=lib/recipes.sh
. "$PROJECT_DIR/lib/recipes.sh"
# shellcheck source=lib/bundle.sh
. "$PROJECT_DIR/lib/bundle.sh"

TOOLS="$WORK_DIR/tools"
DATA="$WORK_DIR/data"
install_err_trap

PACKAGES="zlib bzip2 xz zstd brotli lzlib libiconv libunistring gettext libidn2 pcre2 libtasn1 gmp nettle"
if [ "$ENABLE_DANE" = 1 ]; then PACKAGES="$PACKAGES expat unbound"; fi
if [ "$ENABLE_PQC" = 1 ]; then PACKAGES="$PACKAGES leancrypto"; fi
PACKAGES="$PACKAGES gnutls nghttp2 libpsl libhsts"
if [ "$ENABLE_GNUPG" = 1 ]; then PACKAGES="$PACKAGES sqlite libgpg-error libgcrypt libassuan libksba npth gpgme gnupg"; fi
PACKAGES="$PACKAGES wget2"

# ------------------------------------------------------------------ checks

preflight() {
	log "Preflight"
	[ "$(uname -s)" = Darwin ] || die "this must run on macOS"
	[ "$(uname -m)" = arm64 ] || die "build on an Apple Silicon Mac (x86_64 is built natively and tested under Rosetta 2)"
	/usr/bin/xcode-select -p >/dev/null 2>&1 || die "install the Command Line Tools: xcode-select --install"
	/usr/bin/clang --version >/dev/null 2>&1 || die "clang does not work (Command Line Tools)"
	/usr/bin/python3 -c 'import sys; assert sys.version_info >= (3, 7)' 2>/dev/null || die "/usr/bin/python3 (3.7+) is required"
	case " $ARCHS " in *" x86_64 "*)
		/usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null \
			|| die "Rosetta 2 is needed for the x86_64 build: softwareupdate --install-rosetta --agree-to-license" ;;
	esac

	[ -d "$MACOS_SDK" ] || die "macOS SDK not found: $MACOS_SDK (set MACOS_SDK=...)"
	local sdkver
	sdkver=$(/usr/bin/python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["Version"])' "$MACOS_SDK/SDKSettings.json" 2>/dev/null || true)
	case "$sdkver" in
	11.*) note "SDK $sdkver: $MACOS_SDK" ;;
	*)
		if [ "${ALLOW_ANY_SDK:-0}" = 1 ]; then warn "SDK version '$sdkver' is not 11.x (ALLOW_ANY_SDK=1)"
		else die "expected a macOS 11.x SDK, found '$sdkver' at $MACOS_SDK (ALLOW_ANY_SDK=1 to override)"; fi ;;
	esac

	case "$WORK_DIR$PROJECT_DIR" in *" "*) die "WORK_DIR and the project path must not contain spaces" ;; esac
	mkdir -p "$WORK_DIR"
	local free_kb
	free_kb=$(df -k "$WORK_DIR" | awk 'NR == 2 { print $4 }')
	if [ "$free_kb" -lt 6000000 ]; then warn "less than 6 GB free in $WORK_DIR"; fi
	if [ -d /opt/homebrew ] || [ -d /usr/local/Homebrew ] || [ -d /opt/local ]; then
		note "Homebrew/MacPorts present: ignored (clean PATH, 11.x SDK sysroot, private pkg-config)"
	fi
	note "clang: $(/usr/bin/clang --version | head -n 1)"
	note "features: GnuPG=$ENABLE_GNUPG DANE=$ENABLE_DANE PQC=$ENABLE_PQC; archs: $ARCHS; jobs: $JOBS"
}

# ------------------------------------------------------------------- tools

build_tools() {
	mkdir -p "$TOOLS/bin" "$TOOLS/src" "$WORK_DIR/logs"
	if [ ! -x "$TOOLS/bin/pkgconf" ]; then
		log "Building pkgconf (build tool)"
		fetch_source pkgconf
		extract_source pkgconf "$TOOLS/src/pkgconf"
		# (errexit is off inside "( ... ) || die", hence the && chain)
		( cd "$TOOLS/src/pkgconf" \
			&& ./configure --prefix="$TOOLS" --disable-shared --enable-static --disable-dependency-tracking \
			&& make -j"$JOBS" && make install ) > "$WORK_DIR/logs/tool-pkgconf.log" 2>&1 \
			|| die "pkgconf build failed; see $WORK_DIR/logs/tool-pkgconf.log"
	fi
	# Everything uses this wrapper: static link flags (Libs.private) always.
	cat > "$TOOLS/bin/pkg-config" <<EOF
#!/bin/sh
exec "$TOOLS/bin/pkgconf" --static "\$@"
EOF
	chmod 755 "$TOOLS/bin/pkg-config"

	if [ "$ENABLE_PQC" = 1 ] && [ ! -x "$TOOLS/bin/ninja" ]; then
		log "Installing meson and ninja into a private venv (for leancrypto)"
		rm -rf "$TOOLS/venv"
		/usr/bin/python3 -m venv "$TOOLS/venv"
		printf '%s\n%s\n' "$MESON_WHEEL" "$NINJA_WHEEL" > "$TOOLS/requirements.txt"
		"$TOOLS/venv/bin/python3" -m pip install --disable-pip-version-check --quiet \
			--only-binary :all: --require-hashes -r "$TOOLS/requirements.txt" \
			|| die "pip could not install meson/ninja"
		ln -sf "$TOOLS/venv/bin/meson" "$TOOLS/bin/meson"
		ln -sf "$TOOLS/venv/bin/ninja" "$TOOLS/bin/ninja"
	fi
}

# ------------------------------------------------------------------- steps

fetch_all() {
	local p
	log "Fetching and verifying sources"
	for p in $PACKAGES; do fetch_source "$p"; done
}

build_arch() {
	local p
	setup_arch "$1"
	REBUILD_REST=0
	for p in $PACKAGES; do
		build_pkg "$p" "r_$(echo "$p" | tr '-' '_')"
	done
}

do_deps() {
	local a
	build_tools
	fetch_all
	prepare_data
	for a in $ARCHS; do
		log "=== $a ==="
		build_arch "$a"
	done
}

do_app() {
	case " $ARCHS " in *" arm64 "*) ;; *) die "the bundle step uses the arm64 build for data generation; keep arm64 in ARCHS" ;; esac
	mkdir -p "$DIST_DIR"
	make_hsts_dafsa
	make_test_vectors
	assemble_app
	sign_app
	audit_app
	smoke_test
	if [ "$MAKE_ZIP" = 1 ]; then make_zip; fi
	log "Done: $DIST_DIR/wget.app  (run ./test.sh for the full runtime checks)"
}

main() {
	local cmd=${1:-all}
	scrub_environment
	case "$cmd" in
	all)   preflight; do_deps; do_app ;;
	deps)  preflight; do_deps ;;
	app)   preflight; build_tools; do_app ;;
	audit) audit_app ;;
	clean)
		local a
		for a in $ARCHS; do rm -rf "${WORK_DIR:?}/$a"; done
		rm -rf "$WORK_DIR/logs" "$WORK_DIR/merge-"* "$DIST_DIR/wget.app"
		log "Cleaned (downloads and tools kept)" ;;
	*) sed -n '2,15p' "$0"; exit 2 ;;
	esac
}

main "$@"
