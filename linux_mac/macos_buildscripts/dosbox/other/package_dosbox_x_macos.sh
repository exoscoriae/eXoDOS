#!/usr/bin/env bash
# package_dosbox_x_macos.sh — Bundle, sign, (optionally) notarize a DOSBox-X
# build as a fully portable universal .app + DMG.
#
# Output naming (fixed):
#   dosbox-x-v2024.07.01 -> dosbox-x-20240701.app (executable: dosbox-x-20240701) + dosbox-x-20240701.dmg
#   dosbox-x-v2024.10.01 -> dosbox-x-20241001.app (executable: dosbox-x-20241001) + dosbox-x-20241001.dmg
#   dosbox-x-v2025.02.01 -> dosbox-x-20250201.app (executable: dosbox-x-20250201) + dosbox-x-20250201.dmg
#   dosbox-x-v2025.05.03 -> dosbox-x-20250503.app (executable: dosbox-x-20250503) + dosbox-x-20250503.dmg
#
# The app icon is DOSBox-X's own icon, taken directly from
# contrib/macos/dosbox.icns inside the source tree.
#
# Every non-system dylib is bundled into Contents/Frameworks with @rpath
# install names; a final audit verifies that NO Mach-O in the bundle requires
# anything newer than macOS 11.0 and that no external paths remain.
#
# Usage:
#   ./package_dosbox_x_macos.sh <dosbox-x-source-dir> [output-dir] [options]
#
# Options:
#   --sign <identity>           Developer ID certificate
#   --apple-id <email>          Apple ID for notarization
#   --team-id <id>              Apple Developer Team ID
#   --password <password>       App-specific password
#   --keychain-profile <name>   Stored notarytool profile
#
# Compatible with the stock /bin/bash 3.2 on macOS.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPS_PREFIX="${DEPS_PREFIX:-$SCRIPT_DIR/deps-prefix}"
MACOS_MIN=11.0

# ── Argument parsing ──────────────────────────────────────────────────────────

SRC_DIR=""
OUTPUT_DIR="$(pwd)"
SIGN_IDENTITY=""
APPLE_ID=""
TEAM_ID=""
NOTARY_PASSWORD=""
KEYCHAIN_PROFILE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --sign)             SIGN_IDENTITY="$2";    shift 2 ;;
        --apple-id)         APPLE_ID="$2";         shift 2 ;;
        --team-id)          TEAM_ID="$2";          shift 2 ;;
        --password)         NOTARY_PASSWORD="$2";  shift 2 ;;
        --keychain-profile) KEYCHAIN_PROFILE="$2"; shift 2 ;;
        -*)
            echo "Unknown option: $1"
            echo "Usage: $0 <dosbox-x-source-dir> [output-dir] [--sign <id>] [--apple-id <email>] [--team-id <id>] [--password <pw>] [--keychain-profile <name>]"
            exit 1
            ;;
        *)
            if [ -z "$SRC_DIR" ]; then
                SRC_DIR="$1"
            else
                OUTPUT_DIR="$1"
            fi
            shift
            ;;
    esac
done

if [ -z "$SRC_DIR" ] || [ ! -d "$SRC_DIR" ]; then
    echo "Usage: $0 <dosbox-x-source-dir> [output-dir] [options]"
    echo "  e.g. $0 dosbox-x-v2025.05.03"
    exit 1
fi

BINARY="$SRC_DIR/src/dosbox-x"
if [ ! -x "$BINARY" ]; then
    echo "ERROR: Binary not found at $BINARY"
    echo "  Run build_all_dosboxx.sh first."
    exit 1
fi

BUNDLER="$SCRIPT_DIR/bundle_dylibs.py"
[ -f "$BUNDLER" ] || { echo "ERROR: bundle_dylibs.py not found next to this script."; exit 1; }
ICO2PNG="$SCRIPT_DIR/ico_to_png.py"

# ── Determine signing mode ────────────────────────────────────────────────────

if [ -n "$SIGN_IDENTITY" ]; then
    if [ -n "$KEYCHAIN_PROFILE" ] || \
       { [ -n "$APPLE_ID" ] && [ -n "$TEAM_ID" ] && [ -n "$NOTARY_PASSWORD" ]; }; then
        SIGN_MODE="notarize"
    else
        SIGN_MODE="devid"
    fi
else
    SIGN_MODE="adhoc"
fi

# ── Derive version / names ────────────────────────────────────────────────────
# Directory names look like dosbox-x-v2025.05.03; the app/executable name is
# dosbox-x-YYYYMMDD (dots stripped from the date).

DIR_BASENAME=$(basename "$SRC_DIR")
DX_VERSION=$(echo "$DIR_BASENAME" | grep -oE 'v[0-9]+(\.[0-9]+)+' || echo "")
if [ -z "$DX_VERSION" ]; then
    echo "ERROR: could not derive a vYYYY.MM.DD version from directory name '$DIR_BASENAME'"
    echo "  Expected something like dosbox-x-v2025.05.03."
    exit 1
fi

FULL_VERSION="${DX_VERSION#v}"                     # 2025.05.03
DATE_COMPACT=$(echo "$FULL_VERSION" | tr -d '.')   # 20250503

APP_NAME="dosbox-x-${DATE_COMPACT}"                # dosbox-x-20250503
EXECUTABLE_NAME="$APP_NAME"                        # dosbox-x-20250503
APP_DISPLAY_NAME="DOSBox-X ${FULL_VERSION}"        # menu bar / Finder display
BUNDLE_ID="com.dosbox-x.dosbox-x-${DATE_COMPACT}"
DMG_NAME="$APP_NAME"                               # dosbox-x-20250503.dmg
ICON_BASENAME="dosbox-x"

echo "=== DOSBox-X macOS Packager ==="
echo "  Source:     $SRC_DIR"
echo "  Binary:     $BINARY ($(lipo -archs "$BINARY" 2>/dev/null || echo unknown))"
echo "  Version:    $FULL_VERSION"
echo "  App bundle: $APP_NAME.app  (executable: $EXECUTABLE_NAME)"
echo "  Output:     $OUTPUT_DIR/$APP_NAME.app  +  $OUTPUT_DIR/$DMG_NAME.dmg"
case "$SIGN_MODE" in
    adhoc)    echo "  Signing:    ad-hoc (local testing / xattr-clear on other Macs)" ;;
    devid)    echo "  Signing:    Developer ID (no notarization)" ;;
    notarize) echo "  Signing:    Developer ID + notarize + staple" ;;
esac
echo

# ── Staging area ──────────────────────────────────────────────────────────────

mkdir -p "$OUTPUT_DIR"
STAGING=$(mktemp -d "$OUTPUT_DIR/.dosbox-x-pkg-XXXXXX")
trap 'rm -rf "$STAGING"' EXIT

APP_BUNDLE="$STAGING/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
FRAMEWORKS="$CONTENTS/Frameworks"

mkdir -p "$MACOS_DIR" "$RESOURCES" "$FRAMEWORKS"

# ── [1/8] Copy binary ────────────────────────────────────────────────────────

cp "$BINARY" "$MACOS_DIR/$EXECUTABLE_NAME"
chmod +x "$MACOS_DIR/$EXECUTABLE_NAME"
echo "[1/8] Copied binary as $EXECUTABLE_NAME ($(lipo -archs "$MACOS_DIR/$EXECUTABLE_NAME"))"

# ── [2/8] App icon ───────────────────────────────────────────────────────────
# DOSBox-X ships its own icon at contrib/macos/dosbox.icns — use it directly.
# Fallbacks: a pre-made dosbox-x.icns next to this script, then an .ico from
# the tree converted via ico_to_png.py + sips + iconutil.

ICON_OK=0
ICNS_OUT="$STAGING/$ICON_BASENAME.icns"

build_icns_from_ico() {
    local ico="$1"
    local master="$STAGING/dosbox-x-icon-master.png"
    local iconset="$STAGING/$ICON_BASENAME.iconset"

    [ -f "$ico" ] || return 1
    [ -f "$ICO2PNG" ] || { echo "  WARNING: ico_to_png.py missing"; return 1; }

    python3 "$ICO2PNG" "$ico" "$master" || return 1

    rm -rf "$iconset"
    mkdir -p "$iconset"
    local sz
    for sz in 16 32 128 256 512; do
        sips -z "$sz" "$sz" "$master" \
            --out "$iconset/icon_${sz}x${sz}.png"      >/dev/null || return 1
        sips -z "$((sz * 2))" "$((sz * 2))" "$master" \
            --out "$iconset/icon_${sz}x${sz}@2x.png"   >/dev/null || return 1
    done
    iconutil -c icns -o "$ICNS_OUT" "$iconset" || return 1
    return 0
}

if [ -f "$SRC_DIR/contrib/macos/dosbox.icns" ]; then
    cp "$SRC_DIR/contrib/macos/dosbox.icns" "$ICNS_OUT"
    echo "[2/8] Used DOSBox-X icon from contrib/macos/dosbox.icns"
    ICON_OK=1
elif [ -f "$SCRIPT_DIR/dosbox-x.icns" ]; then
    cp "$SCRIPT_DIR/dosbox-x.icns" "$ICNS_OUT"
    echo "[2/8] Used pre-made dosbox-x.icns from the script directory"
    ICON_OK=1
elif build_icns_from_ico "$SRC_DIR/contrib/icons/dosbox-x.ico" \
     || build_icns_from_ico "$SRC_DIR/src/dosbox.ico"; then
    echo "[2/8] Built $ICON_BASENAME.icns from an .ico in the source tree"
    ICON_OK=1
else
    echo "[2/8] WARNING: no icon source found — bundle will have no icon"
fi

if [ "$ICON_OK" = "1" ]; then
    cp "$ICNS_OUT" "$RESOURCES/$ICON_BASENAME.icns"
    ICON_FILE_KEY="$ICON_BASENAME"
else
    ICON_FILE_KEY=""
fi

# ── [3/8] Resources + Info.plist ─────────────────────────────────────────────
# Ship the reference configuration files DOSBox-X users expect.

for conf in dosbox-x.reference.conf dosbox-x.reference.full.conf; do
    if [ -f "$SRC_DIR/$conf" ]; then
        cp "$SRC_DIR/$conf" "$RESOURCES/$conf"
        echo "      Resource: $conf"
    fi
done

cat > "$CONTENTS/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${EXECUTABLE_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>${ICON_FILE_KEY}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_DISPLAY_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${FULL_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${FULL_VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MACOS_MIN}</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>
    <string>DOSBox-X — GNU GPL v2</string>
</dict>
</plist>
PLIST

echo "[3/8] Wrote Info.plist"

# ── [4/8] Bundle every non-system dylib into Frameworks/ ─────────────────────
# DOSBox-X links SDL2 directly (no sdl12-compat shim), so the dependency
# graph walk sees everything — no --also-bundle needed.

echo "[4/8] Bundling dependencies into .app/Contents/Frameworks/ ..."
python3 "$BUNDLER" "$MACOS_DIR/$EXECUTABLE_NAME" "$FRAMEWORKS" \
    "$DEPS_PREFIX/lib"

# NOTE: on a universal binary `otool -L` prints one header line PER SLICE,
# so keep only true dylib-reference lines ("compatibility version") before
# checking for external paths.
DEPS_EXTERNAL=$(otool -L "$MACOS_DIR/$EXECUTABLE_NAME" \
    | awk '/compatibility version/ {print $1}' | sort -u \
    | grep -vE '^(@|/System/|/usr/lib/|/Library/Frameworks/)' || true)
if [ -n "$DEPS_EXTERNAL" ]; then
    echo "  ERROR: main binary still references external paths:"
    printf '    %s\n' $DEPS_EXTERNAL
    exit 1
fi
echo "  All non-system dylibs bundled."

# ── [5/8] macOS 11.0 compliance audit ────────────────────────────────────────

echo "[5/8] Auditing minimum-OS of every Mach-O in the bundle..."
AUDIT_FAIL=0
while IFS= read -r machofile; do
    minos_list=$(otool -l "$machofile" 2>/dev/null \
        | awk '/^ *minos /{print $2} /LC_VERSION_MIN_MACOSX/{grab=1} grab&&/^ *version /{print $2; grab=0}' \
        | sort -u)
    for v in $minos_list; do
        v_major=${v%%.*}; v_rest=${v#*.}; v_minor=${v_rest%%.*}
        [ "$v_rest" = "$v" ] && v_minor=0
        m_major=${MACOS_MIN%%.*}; m_rest=${MACOS_MIN#*.}; m_minor=${m_rest%%.*}
        [ "$m_rest" = "$MACOS_MIN" ] && m_minor=0
        if [ $(( v_major * 100 + v_minor )) -gt $(( m_major * 100 + m_minor )) ] 2>/dev/null; then
            echo "  FAIL: $machofile declares minos $v (> $MACOS_MIN)"
            AUDIT_FAIL=1
        fi
    done
    printf '  %-8s %s\n' "$(echo $minos_list | tr '\n' ' ')" "$(basename "$machofile")"
done < <(find "$APP_BUNDLE" -type f \( -perm -111 -o -name '*.dylib' \) \
            -exec sh -c 'file "$1" | grep -q Mach-O' _ {} \; -print)

if [ "$AUDIT_FAIL" = "1" ]; then
    echo "  ERROR: bundle contains Mach-O files requiring newer than macOS $MACOS_MIN"
    exit 1
fi
echo "  All Mach-O files target macOS $MACOS_MIN or older."

# ── [6/8] Code sign ─────────────────────────────────────────────────────────

if [ "$SIGN_MODE" = "adhoc" ]; then
    find "$FRAMEWORKS" -name "*.dylib" -type f -exec \
        codesign --force --sign - {} \; 2>&1 | sed 's/^/  /'
    codesign --force --sign - "$MACOS_DIR/$EXECUTABLE_NAME" 2>&1 | sed 's/^/  /'
    codesign --force --sign - "$APP_BUNDLE" 2>&1 | sed 's/^/  /'
    echo "[6/8] Ad-hoc code signed"
else
    # Hardened runtime + JIT entitlements: the dynamic recompiler needs
    # executable memory (Darwin dual-mapped cache) under the hardened runtime.
    ENTITLEMENTS="$STAGING/dosbox-x.entitlements"
    cat > "$ENTITLEMENTS" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-jit</key>
    <true/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
EOF

    find "$FRAMEWORKS" -name "*.dylib" -type f -exec \
        codesign --force \
            --options runtime \
            --sign "$SIGN_IDENTITY" \
            {} \; 2>&1 | sed 's/^/  /'

    codesign --force \
        --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGN_IDENTITY" \
        "$MACOS_DIR/$EXECUTABLE_NAME" 2>&1 | sed 's/^/  /'

    codesign --force --deep \
        --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGN_IDENTITY" \
        "$APP_BUNDLE" 2>&1 | sed 's/^/  /'

    codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" 2>&1 | sed 's/^/  /'
    echo "[6/8] Developer ID signed (hardened runtime + JIT entitlements)"
fi

# ── [7/8] Export the .app + create DMG ───────────────────────────────────────

rm -rf "$OUTPUT_DIR/$APP_NAME.app"
ditto "$APP_BUNDLE" "$OUTPUT_DIR/$APP_NAME.app"
echo "[7/8] Exported $OUTPUT_DIR/$APP_NAME.app"

DMG_PATH="$OUTPUT_DIR/$DMG_NAME.dmg"
rm -f "$DMG_PATH"
RW_DMG="$STAGING/rw.dmg"

DMG_SRC="$STAGING/dmg-root"
mkdir -p "$DMG_SRC"
ditto "$APP_BUNDLE" "$DMG_SRC/$APP_NAME.app"
ln -s /Applications "$DMG_SRC/Applications"

hdiutil create \
    -volname "$APP_DISPLAY_NAME" \
    -srcfolder "$DMG_SRC" \
    -ov -format UDRW \
    "$RW_DMG" > /dev/null

hdiutil convert "$RW_DMG" \
    -format UDZO \
    -o "$DMG_PATH" > /dev/null

echo "      Created DMG: $DMG_PATH"

if [ "$SIGN_MODE" != "adhoc" ]; then
    echo "      Signing DMG..."
    codesign --force --sign "$SIGN_IDENTITY" "$DMG_PATH" 2>&1 | sed 's/^/  /'
fi

# ── [8/8] Notarize + staple ──────────────────────────────────────────────────

if [ "$SIGN_MODE" = "notarize" ]; then
    echo "[8/8] Submitting to Apple Notary Service (may take a few minutes)..."
    NOTARY_ARGS=(xcrun notarytool submit "$DMG_PATH" --wait)
    if [ -n "$KEYCHAIN_PROFILE" ]; then
        NOTARY_ARGS=("${NOTARY_ARGS[@]}" --keychain-profile "$KEYCHAIN_PROFILE")
    else
        NOTARY_ARGS=("${NOTARY_ARGS[@]}" --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$NOTARY_PASSWORD")
    fi
    if ! "${NOTARY_ARGS[@]}"; then
        echo
        echo "ERROR: Notarization failed. Retrieve the full log with:"
        echo "  xcrun notarytool log <submission-id> --keychain-profile <profile>"
        exit 1
    fi
    echo "      Stapling notarization ticket..."
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler staple "$OUTPUT_DIR/$APP_NAME.app" || true
    echo "      Stapled."
else
    echo "[8/8] (skipped — not notarizing)"
fi

# ── Done ──────────────────────────────────────────────────────────────────────

echo
echo "Done!"
echo "  App:  $OUTPUT_DIR/$APP_NAME.app"
echo "  DMG:  $(du -sh "$DMG_PATH" | cut -f1) — $DMG_PATH"
echo
echo "Bundled dylibs ($(find "$FRAMEWORKS" -name '*.dylib' | wc -l | tr -d ' ')):"
find "$FRAMEWORKS" -name '*.dylib' -maxdepth 2 -exec basename {} \; | sed 's/^/  /'
echo

case "$SIGN_MODE" in
    adhoc)
        echo "Note: Ad-hoc signed (no Apple Developer account)."
        echo "  - Works on this Mac without restrictions."
        echo "  - Other Macs: right-click → Open on first launch, or run:"
        echo "      xattr -dr com.apple.quarantine \"/Applications/$APP_NAME.app\""
        ;;
    devid)
        echo "Note: Developer ID signed but not notarized."
        ;;
    notarize)
        echo "Fully signed, notarized, and stapled — installs on any Mac 11.0+ without warnings."
        ;;
esac
echo
