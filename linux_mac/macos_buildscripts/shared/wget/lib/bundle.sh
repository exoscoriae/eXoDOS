# shellcheck shell=bash
# Data files, universal binaries, the application bundle, signing, checks.

# ------------------------------------------------------------------- data

curl_https() { # url output
	/usr/bin/curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 --connect-timeout 20 -o "$2" "$1"
}

# Fetched fresh for every build so the bundle ships current data.
# OFFLINE_DATA=1 reuses what is already in $WORK_DIR/data.
prepare_data() {
	DATA="$WORK_DIR/data"
	mkdir -p "$DATA"
	if [ "${OFFLINE_DATA:-0}" = 1 ] && [ -s "$DATA/cacert.pem" ] && [ -s "$DATA/public_suffix_list.dat" ] \
		&& [ -s "$DATA/hsts-chromium.json" ]; then
		log "Using existing data in $DATA (OFFLINE_DATA=1)"
		return 0
	fi

	log "Fetching the Mozilla CA bundle (snapshot shipped in the app)"
	curl_https "$CACERT_URL" "$DATA/cacert.pem.new" || die "cannot download $CACERT_URL"
	curl_https "$CACERT_URL.sha256" "$DATA/cacert.pem.sha256" || die "cannot download $CACERT_URL.sha256"
	local want got n
	want=$(awk '{ print $1 }' "$DATA/cacert.pem.sha256")
	got=$(file_hash 256 "$DATA/cacert.pem.new")
	if [ "$want" != "$got" ]; then die "cacert.pem checksum mismatch"; fi
	n=$(grep -c -- '-----BEGIN CERTIFICATE-----' "$DATA/cacert.pem.new" || true)
	if [ "$n" -lt 100 ] || ! grep '^## Certificate data from Mozilla' "$DATA/cacert.pem.new" >/dev/null; then
		die "cacert.pem does not look like curl's Mozilla bundle ($n certificates)"
	fi
	mv "$DATA/cacert.pem.new" "$DATA/cacert.pem"
	note "$n certificates, $(grep -m1 '^## Certificate data from Mozilla' "$DATA/cacert.pem" | sed 's/^## //')"

	log "Fetching the Public Suffix List (compiled into libpsl)"
	local u ok=0
	for u in $PSL_URLS; do
		if curl_https "$u" "$DATA/psl.new"; then ok=1; break; fi
	done
	if [ $ok != 1 ]; then die "cannot download the Public Suffix List"; fi
	if ! grep '===BEGIN ICANN DOMAINS===' "$DATA/psl.new" >/dev/null; then die "PSL download is not the PSL"; fi
	mv "$DATA/psl.new" "$DATA/public_suffix_list.dat"

	log "Fetching Chromium's HSTS preload list"
	curl_https "$HSTS_JSON_URL" "$DATA/hsts.new" || die "cannot download the HSTS preload list"
	if [ "$(wc -c < "$DATA/hsts.new")" -lt 1000000 ]; then die "HSTS preload list is suspiciously small"; fi
	mv "$DATA/hsts.new" "$DATA/hsts-chromium.json"

	check_dnssec_anchors
}

# The DNSSEC root trust anchors ship from data/; warn if IANA publishes a
# key that is not in the file (a future root KSK rollover).
check_dnssec_anchors() {
	local xml="$WORK_DIR/data/root-anchors.xml"
	if ! curl_https "$IANA_ANCHORS_URL" "$xml"; then
		warn "could not fetch $IANA_ANCHORS_URL to cross-check the DNSSEC trust anchors"
		return 0
	fi
	/usr/bin/python3 -I - "$xml" "$PROJECT_DIR/data/dnssec-root-anchors.txt" <<'PY' || warn "the DNSSEC trust anchors in data/dnssec-root-anchors.txt are not current; see above"
import re, sys, datetime
xml = open(sys.argv[1]).read()
ours = open(sys.argv[2]).read().upper()
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")
missing = 0
for m in re.finditer(r"<KeyDigest([^>]*)>(.*?)</KeyDigest>", xml, re.S):
    attrs, body = m.group(1), m.group(2)
    until = re.search(r'validUntil="([^"]+)"', attrs)
    if until and until.group(1)[:19] < now:
        continue
    tag = re.search(r"<KeyTag>(\d+)</KeyTag>", body).group(1)
    digest = re.search(r"<Digest>([0-9A-Fa-f]+)</Digest>", body).group(1).upper()
    if digest not in ours:
        print("IANA root anchor %s (%s) is missing from dnssec-root-anchors.txt" % (tag, digest))
        missing += 1
sys.exit(1 if missing else 0)
PY
}

# Build hsts.dafsa from Chromium's list with libhsts' own converter and make
# sure libhsts can read it.
make_hsts_dafsa() {
	local src="$WORK_DIR/arm64/src/libhsts" json="$DATA/hsts-chromium.json"
	local clean="$DATA/hsts.json" out="$DATA/hsts.dafsa" opt ok=0
	require_files "$src/src/hsts-make-dafsa"
	# libhsts' test suite strips the // comment lines the same way
	/usr/bin/sed -E 's|^[[:space:]]*//.*$||' "$json" > "$clean"
	for opt in "--output-format=binary" "--binary"; do
		rm -f "$out"
		if /usr/bin/python3 "$src/src/hsts-make-dafsa" "$opt" "$clean" "$out" >/dev/null 2>"$WORK_DIR/logs/hsts-dafsa.log" \
			&& [ -s "$out" ]; then
			ok=1
			break
		fi
	done
	if [ $ok != 1 ]; then cat "$WORK_DIR/logs/hsts-dafsa.log" >&2; die "could not build hsts.dafsa"; fi

	# verify with the arm64 libhsts
	( setup_arch arm64 && $CC $CFLAGS $CPPFLAGS "$PROJECT_DIR/tools/hsts_check.c" -o "$WORK_DIR/hsts_check" \
		$LDFLAGS $($PKG_CONFIG --libs libhsts) ) || die "cannot build tools/hsts_check.c"
	"$WORK_DIR/hsts_check" "$out" || die "hsts.dafsa failed the libhsts self-check"
	note "hsts.dafsa: $(wc -c < "$out" | tr -d ' ') bytes, verified with libhsts"
}

# Compressed test payloads for test.sh (one per Content-Encoding).
make_test_vectors() {
	local td="$DIST_DIR/testdata"
	rm -rf "$td"
	mkdir -p "$td"
	( setup_arch arm64 && $CC $CFLAGS $CPPFLAGS "$PROJECT_DIR/tools/mkvectors.c" -o "$WORK_DIR/mkvectors" \
		$LDFLAGS $($PKG_CONFIG --libs zlib bzip2 liblzma libbrotlienc libzstd liblz) ) || die "cannot build tools/mkvectors.c"
	"$WORK_DIR/mkvectors" "$td" || die "mkvectors failed"
}

# ------------------------------------------------------------------ binaries

archs_csv() { echo "$ARCHS" | tr ' ' ','; }

# Merge the per-architecture builds of one executable (stripped) into OUT.
merge_executable() { # out arch-relative-path
	local out=$1 rel=$2 a inputs="" tmp
	for a in $ARCHS; do
		tmp="$WORK_DIR/merge-$a-$(basename "$rel")"
		require_files "$WORK_DIR/$a/$rel"
		cp "$WORK_DIR/$a/$rel" "$tmp"
		/usr/bin/strip "$tmp"
		inputs="$inputs $tmp"
	done
	mkdir -p "$(dirname "$out")"
	# shellcheck disable=SC2086
	/usr/bin/lipo -create $inputs -output "$out"
	chmod 755 "$out"
	rm -f $inputs
}

is_macho() {
	case "$(/usr/bin/file -b "$1")" in *Mach-O*) return 0 ;; esac
	return 1
}

# ----------------------------------------------------------------- the app

write_info_plist() {
	cat > "$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>wget</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>wget</string>
	<key>CFBundleDisplayName</key>
	<string>GNU Wget2</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$WGET2_VERSION</string>
	<key>CFBundleVersion</key>
	<string>$WGET2_VERSION</string>
	<key>LSMinimumSystemVersion</key>
	<string>$MACOS_MIN</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>GNU Wget2 is free software, licensed under the GNU GPL version 3 or later.</string>
EOF
	if [ -f "$PROJECT_DIR/data/AppIcon.icns" ]; then
		printf '\t<key>CFBundleIconFile</key>\n\t<string>AppIcon</string>\n' >> "$1"
	fi
	printf '</dict>\n</plist>\n' >> "$1"
	/usr/bin/plutil -lint -s "$1" || die "generated Info.plist is invalid"
}

# The bundle icon: data/AppIcon.icns, if present (replace it to change the icon).
install_icon() { # resources-dir
	local icon="$PROJECT_DIR/data/AppIcon.icns" magic
	if [ ! -f "$icon" ]; then
		note "no data/AppIcon.icns: the app gets the generic icon"
		return 0
	fi
	magic=$(head -c 4 "$icon")
	if [ "$magic" != icns ]; then die "data/AppIcon.icns is not an .icns file"; fi
	install -m 644 "$icon" "$1/AppIcon.icns"
}

collect_licenses() { # dest
	local dest=$1 pkg dir f
	for pkg in $PACKAGES; do
		dir="$WORK_DIR/arm64/src/$pkg"
		[ -d "$dir" ] || continue
		mkdir -p "$dest/$pkg-$(pkg_version "$pkg")"
		for f in "$dir"/COPYING* "$dir"/LICENSE* "$dir"/LICENCE* "$dir"/COPYRIGHT* "$dir"/LICENSES/*; do
			if [ -f "$f" ]; then cp "$f" "$dest/$pkg-$(pkg_version "$pkg")/"; fi
		done
	done
}

write_buildinfo() { # file
	local p
	{
		echo "GNU Wget2 $WGET2_VERSION - portable macOS application bundle"
		echo
		echo "Built:            $(date -u '+%Y-%m-%d %H:%M UTC') on macOS $(sw_vers -productVersion) ($(uname -m))"
		echo "Compiler:         $(/usr/bin/clang --version | head -n 1)"
		echo "SDK:              $MACOS_SDK"
		echo "Minimum macOS:    $MACOS_MIN"
		echo "Architectures:    $ARCHS"
		echo
		echo "CA snapshot:      $(grep -m1 '^## Certificate data from Mozilla' "$DATA/cacert.pem" | sed 's/^## //')"
		echo "                  (refreshed at run time, see README-macOS.txt)"
		echo "PSL sha256:       $(file_hash 256 "$DATA/public_suffix_list.dat")"
		echo "HSTS list sha256: $(file_hash 256 "$DATA/hsts-chromium.json")"
		echo
		echo "Components (all linked statically):"
		for p in $PACKAGES; do printf '  %-14s %s\n' "$p" "$(pkg_version "$p")"; done
		echo
		echo "Source tarballs and checksums: SOURCES.txt; patches applied: patches/."
	} > "$1"
}

assemble_app() {
	local app="$DIST_DIR/wget.app" res f rel a
	log "Assembling $app"
	rm -rf "$app"
	mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
	res="$app/Contents/Resources"

	merge_executable "$app/Contents/MacOS/wget" stage/wget2/usr/local/bin/wget2
	write_info_plist "$app/Contents/Info.plist"
	printf 'APPL????' > "$app/Contents/PkgInfo"
	install_icon "$res"

	mkdir -p "$res/ca" "$res/hsts" "$res/dnssec" "$res/man/man1"
	install -m 644 "$DATA/cacert.pem" "$res/ca/cacert.pem"
	install -m 644 "$DATA/hsts.dafsa" "$res/hsts/hsts.dafsa"
	install -m 644 "$PROJECT_DIR/data/dnssec-root-anchors.txt" "$res/dnssec/root-anchors.txt"
	if [ -f "$WORK_DIR/arm64/stage/wget2-extra/wget2.1" ]; then
		install -m 644 "$WORK_DIR/arm64/stage/wget2-extra/wget2.1" "$res/man/man1/wget2.1"
	else
		warn "no prebuilt wget2.1 man page in the release tarball"
	fi
	if [ -d "$WORK_DIR/arm64/stage/wget2/usr/local/share/locale" ]; then
		cp -R "$WORK_DIR/arm64/stage/wget2/usr/local/share/locale" "$res/locale"
	else
		die "no translations were installed (NLS)"
	fi

	if [ "$ENABLE_GNUPG" = 1 ]; then
		local groot="stage/gnupg/Applications/wget.app/Contents/Resources/gnupg"
		# bin/ and libexec/ only (sbin/ holds admin scripts with absolute paths)
		for f in $(cd "$WORK_DIR/arm64/$groot" && find bin libexec -type f); do
			if is_macho "$WORK_DIR/arm64/$groot/$f"; then
				merge_executable "$res/gnupg/$f" "$groot/$f"
			else
				mkdir -p "$(dirname "$res/gnupg/$f")"
				cp -p "$WORK_DIR/arm64/$groot/$f" "$res/gnupg/$f"
			fi
		done
		if [ -d "$WORK_DIR/arm64/$groot/share/gnupg" ]; then
			mkdir -p "$res/gnupg/share"
			cp -R "$WORK_DIR/arm64/$groot/share/gnupg" "$res/gnupg/share/gnupg"
		fi
	fi

	collect_licenses "$res/licenses"
	mkdir -p "$res/patches"
	cp -R "$PROJECT_DIR/patches/." "$res/patches/"
	find "$res/patches" -name '__pycache__' -prune -exec rm -rf {} +
	find "$res/patches" -name '.DS_Store' -type f -exec rm -f {} +
	grep -v '^#' "$PROJECT_DIR/sources.lock" | grep -v '^[[:space:]]*$' > "$res/SOURCES.txt"
	install -m 644 "$PROJECT_DIR/README-macOS.txt" "$res/README-macOS.txt"
	write_buildinfo "$res/BUILDINFO.txt"
}

sign_app() {
	local app="$DIST_DIR/wget.app" f
	log "Signing (identity: $SIGN_IDENTITY)"
	# helpers first (inside-out), then the bundle, which signs the main
	# executable and seals Contents/Resources
	while IFS= read -r f; do
		if is_macho "$f"; then
			/usr/bin/codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$f"
		fi
	done <<EOF
$(find "$app/Contents/Resources" -type f -perm -u+x)
EOF
	/usr/bin/codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$app"
	/usr/bin/codesign --verify --strict --verbose=2 "$app"
}

# ------------------------------------------------------------------- checks

audit_app() {
	local app="$DIST_DIR/wget.app"
	log "Auditing every Mach-O file against the macOS $MACOS_MIN floor"
	/usr/bin/python3 -I -B "$PROJECT_DIR/tools/macho_audit.py" "$app" \
		--sdk "$MACOS_SDK" --min "$MACOS_MIN" --archs "$(archs_csv)" --require-signature \
		--leak "$WORK_DIR" --leak "$PROJECT_DIR" \
		--leak /opt/homebrew --leak /opt/local --leak /usr/local/Cellar --leak /usr/local/MacGPG2 \
		--relative-to "$DIST_DIR" \
		|| die "audit failed (see above)"
}

# Quick functional check of every architecture that can run on this Mac.
smoke_test() {
	local app="$DIST_DIR/wget.app" a out feat missing=""
	local want="+https +ssl/gnutls +ipv6 +iri +large-file +nls +psl +hsts +iconv +idn2 +zlib +lzma +brotlidec +zstd +bzip2 +lzip +http2"
	if [ "$ENABLE_GNUPG" = 1 ]; then want="$want +gpgme"; fi
	for a in $ARCHS; do
		log "Smoke test ($a)"
		out=$(/usr/bin/arch "-$a" "$app/Contents/MacOS/wget" --version 2>&1) || die "wget --version failed on $a"
		for feat in $want; do
			case " $(echo "$out" | tr '\n' ' ') " in *" $feat "*) ;; *) missing="$missing $a:$feat" ;; esac
		done
		printf '%s\n' "$out" | sed -n '1,3s/^/    /p'
		if [ "$ENABLE_GNUPG" = 1 ]; then
			out=$(/usr/bin/arch "-$a" "$app/Contents/Resources/gnupg/bin/gpgconf" --list-dirs bindir 2>&1) \
				|| die "bundled gpgconf failed on $a"
			case "$out" in
			"$app/Contents/Resources/gnupg/bin") note "GnuPG relocation OK" ;;
			*) die "bundled GnuPG is not relocatable: bindir=$out" ;;
			esac
		fi
	done
	if [ -n "$missing" ]; then die "features missing from --version:$missing"; fi
}

make_zip() {
	local zip="$DIST_DIR/wget2-$WGET2_VERSION-macos$MACOS_MIN-$(echo "$ARCHS" | tr ' ' '-').zip"
	rm -f "$zip"
	(cd "$DIST_DIR" && /usr/bin/ditto -c -k --sequesterRsrc --keepParent wget.app "$zip")
	log "Archive: $zip"
}
