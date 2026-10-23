#!/bin/bash
# Runtime tests for wget.app.  Run them on the build Mac and - the real proof
# of macOS 11 compatibility - on a stock macOS 11 (Big Sur) machine or VM.
#
#   ./test.sh [path/to/wget.app]
#
# Every architecture slice that can run on this Mac is tested (x86_64 via
# Rosetta 2 on Apple Silicon).  Online checks need internet access; the
# local-server checks need a working /usr/bin/python3 (Command Line Tools)
# and dist/testdata (written by build.sh).  Missing prerequisites skip tests,
# they never fail them.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="${1:-$HERE/dist/wget.app}"
APP="$(cd "$APP" 2>/dev/null && pwd)" || { echo "no such app: ${1:-$HERE/dist/wget.app}"; exit 2; }
W="$APP/Contents/MacOS/wget"
G="$APP/Contents/Resources/gnupg/bin"
TD="$(dirname "$APP")/testdata"
[ -d "$TD" ] || TD="$HERE/dist/testdata"

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m    %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m  %s\n' "$*"; }
skip() { SKIP=$((SKIP + 1)); printf '  skip  %s\n' "$*"; }
has()  { case "$1" in *"$2"*) return 0 ;; esac; return 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/wget2-test.XXXXXX")"
SERVER_PID=""
cleanup() {
	if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null; fi
	if [ -x "$G/gpgconf" ] && [ -d "$T/gnupg" ]; then GNUPGHOME="$T/gnupg" "$G/gpgconf" --kill all 2>/dev/null; fi
	rm -rf "$T"
}
trap cleanup EXIT

echo "wget.app: $APP"
echo "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(uname -m)"
echo

echo "== bundle"
if /usr/bin/codesign --verify --strict "$APP" 2>"$T/cs.txt"; then ok "code signature valid"; else bad "codesign: $(cat "$T/cs.txt")"; fi
for f in ca/cacert.pem hsts/hsts.dafsa dnssec/root-anchors.txt locale/de/LC_MESSAGES/wget2.mo; do
	if [ -s "$APP/Contents/Resources/$f" ]; then ok "Resources/$f"; else bad "missing Resources/$f"; fi
done
icon="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP/Contents/Info.plist" 2>/dev/null)"
if [ -z "$icon" ]; then
	skip "app icon (none configured)"
elif [ "$(head -c 4 "$APP/Contents/Resources/${icon%.icns}.icns" 2>/dev/null)" = icns ]; then
	ok "app icon Resources/${icon%.icns}.icns"
else
	bad "app icon: Info.plist names '$icon', but Resources/${icon%.icns}.icns is missing or not an .icns file"
fi

ARCHS=""
for a in $(/usr/bin/lipo -archs "$W"); do
	if /usr/bin/arch "-$a" /usr/bin/true 2>/dev/null; then ARCHS="$ARCHS $a"; else skip "$a slice cannot run on this Mac"; fi
done

HAVE_PY=0
if /usr/bin/xcode-select -p >/dev/null 2>&1 && /usr/bin/python3 -c 'import http.server' 2>/dev/null; then HAVE_PY=1; fi
HAVE_NET=0
if /usr/bin/curl -fsI -m 15 https://example.com/ >/dev/null 2>&1; then HAVE_NET=1; fi

# ---- local server with test payloads and a signed file
PORT=""
HAVE_GPG=0
if [ -x "$G/gpg" ]; then HAVE_GPG=1; fi
if [ $HAVE_PY = 1 ] && [ -d "$TD" ]; then
	mkdir -p "$T/signed"
	if [ $HAVE_GPG = 1 ]; then
		export GNUPGHOME="$T/gnupg"
		mkdir -m 700 "$GNUPGHOME"
		printf 'signed by the wget2 test suite\n' > "$T/signed/signed.txt"
		if "$G/gpg" --batch --quiet --pinentry-mode loopback --passphrase '' \
				--quick-gen-key 'wget2 test <test@example.invalid>' ed25519 sign 1d >"$T/gpg.log" 2>&1 \
			&& "$G/gpg" --batch --quiet --pinentry-mode loopback --passphrase '' \
				--detach-sign -o "$T/signed/signed.txt.sig" "$T/signed/signed.txt" >>"$T/gpg.log" 2>&1; then
			printf 'tampered content\n' > "$T/signed/tampered.txt"
			cp "$T/signed/signed.txt.sig" "$T/signed/tampered.txt.sig"
		else
			HAVE_GPG=0
			bad "bundled GnuPG could not create a test key/signature: $(tail -n 3 "$T/gpg.log")"
		fi
		unset GNUPGHOME
	fi
	/usr/bin/python3 "$HERE/tools/testserver.py" "$T/port" "$TD" "$T/signed" &
	SERVER_PID=$!
	disown 2>/dev/null # no "Terminated" job notice when cleanup() stops it
	for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$T/port" ] && break; sleep 0.5; done
	PORT="$(cat "$T/port" 2>/dev/null)"
fi

# run the wget slice of the architecture under test
R() { /usr/bin/arch "-$CUR" "$W" "$@"; }

for a in $ARCHS; do
	CUR=$a
	echo
	echo "== $a"

	out="$(R --version 2>&1)"
	missing=""
	for feat in +https +ssl/gnutls +ipv6 +iri +large-file +nls +psl +hsts +iconv +idn2 +zlib +lzma +brotlidec +zstd +bzip2 +lzip +http2; do
		has " $(echo "$out" | tr '\n' ' ') " " $feat " || missing="$missing $feat"
	done
	if [ $HAVE_GPG = 1 ]; then has "$out" "+gpgme" || missing="$missing +gpgme"; fi
	if has "$out" "GNU Wget2 2.3.0" && [ -z "$missing" ]; then ok "--version and features"; else bad "--version (missing:$missing)"; fi

	# HSTS preload (offline): any *.dev host is preloaded, so the URL is
	# upgraded to https before the (failing) name lookup.  wget2 names the
	# port of the original URL in this message (":80").
	out="$(LC_ALL=C R -O /dev/null -t 1 -T 5 http://wget2-hsts-selftest.dev/ 2>&1)"
	if has "$out" "HSTS in effect for wget2-hsts-selftest.dev:"; then ok "HSTS preload list"; else bad "HSTS preload not applied: $(echo "$out" | head -n 3)"; fi

	# translations
	c="$(LC_ALL=C R --no-such-option-xyz 2>&1)"
	tr_ok=0
	for l in de fr es; do
		t="$(LANGUAGE=$l LC_ALL=${l}_$(echo $l | tr a-z A-Z).UTF-8 R --no-such-option-xyz 2>&1)"
		if [ "$t" != "$c" ]; then tr_ok=1; break; fi
	done
	if [ $tr_ok = 1 ]; then ok "translations load ($l)"; else bad "translations are not used"; fi

	if [ -n "$PORT" ]; then
		for enc in gzip deflate bzip2 xz br zstd lzip; do
			rm -f "$T/out"
			if R -q -O "$T/out" "http://127.0.0.1:$PORT/enc/$enc" && cmp -s "$T/out" "$TD/payload.txt"; then
				ok "Content-Encoding: $enc"
			else
				bad "Content-Encoding: $enc"
			fi
		done
		if R -q -O /dev/null --regex-type=pcre --accept-regex '^.*\.txt$' "http://127.0.0.1:$PORT/enc/gzip" 2>"$T/err"; then
			ok "PCRE regex support"
		else
			bad "PCRE: $(cat "$T/err")"
		fi
		if [ $HAVE_GPG = 1 ]; then
			rm -rf "$T/dl"; mkdir "$T/dl"
			out="$(cd "$T/dl" && R --verify-sig --gnupg-homedir="$T/gnupg" "http://127.0.0.1:$PORT/signed.txt" 2>&1)"
			if [ $? = 0 ] && has "$out" "successfully verified"; then ok "--verify-sig accepts a good signature"; else bad "--verify-sig: $(echo "$out" | tail -n 3)"; fi
			out="$(cd "$T/dl" && R --verify-sig --gnupg-homedir="$T/gnupg" "http://127.0.0.1:$PORT/tampered.txt" 2>&1)"
			if [ $? != 0 ] && [ ! -e "$T/dl/tampered.txt" ]; then ok "--verify-sig rejects a bad signature"; else bad "tampered file accepted: $(echo "$out" | tail -n 3)"; fi
		else
			skip "--verify-sig (no bundled GnuPG)"
		fi
	else
		skip "local server tests (need python3 and $TD)"
	fi

	if [ -x "$G/gpgconf" ]; then
		out="$(/usr/bin/arch "-$a" "$G/gpgconf" --list-dirs bindir 2>&1)"
		if [ "$out" = "$G" ]; then ok "bundled GnuPG is relocatable"; else bad "gpgconf bindir: $out"; fi
	fi

	if [ $HAVE_NET = 1 ]; then
		out="$(GNUTLS_DEBUG_LEVEL=2 R -d -O /dev/null https://curl.se/ 2>&1)"; rc=$?
		if [ $rc = 0 ]; then ok "HTTPS download"; else bad "HTTPS download (exit $rc)"; fi
		if has "$out" "Server accepted protocol 'h2'"; then ok "HTTP/2"; else bad "no HTTP/2"; fi
		if has "$out" "macOS Keychain:"; then ok "Keychain trust: $(echo "$out" | grep -o 'macOS Keychain: [^,]*, [0-9]* distrusted' | head -n 1)"; else bad "Keychain trust store not loaded"; fi
		if has "$out" "Using Mozilla CA bundle"; then ok "$(echo "$out" | grep -o 'Using Mozilla CA bundle .*' | head -n 1)"; else bad "Mozilla CA bundle not loaded"; fi

		out="$(XDG_CACHE_HOME="$T/cache-$a" WGET_CA_UPDATE_INTERVAL=0 R -d -O /dev/null https://example.com/ 2>&1)"
		if [ -s "$T/cache-$a/wget2/cacert.pem" ] && has "$out" "CA update: stored"; then ok "CA bundle auto-update"; else bad "CA bundle auto-update: $(echo "$out" | grep 'CA update' | tail -n 2)"; fi
		out="$(XDG_CACHE_HOME="$T/cache-$a" WGET_CA_UPDATE_INTERVAL=0 R -d -O /dev/null https://example.com/ 2>&1)"
		if has "$out" "CA update: bundle unchanged"; then ok "CA bundle conditional re-check"; else bad "re-check: $(echo "$out" | grep 'CA update' | tail -n 2)"; fi

		for h in expired untrusted-root wrong.host self-signed; do
			if R -q -t 1 -O /dev/null "https://$h.badssl.com/" 2>/dev/null; then bad "accepted https://$h.badssl.com/"; else ok "rejects $h.badssl.com"; fi
		done
	else
		skip "online tests (no internet access)"
	fi
done

echo
echo "passed: $PASS  failed: $FAIL  skipped: $SKIP"
[ "$FAIL" -eq 0 ]
