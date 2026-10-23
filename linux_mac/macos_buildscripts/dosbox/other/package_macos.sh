#!/usr/bin/env bash
# package_macos.sh — Bundle, sign, (optionally) notarize a DOSBox ECE build
# as a fully portable universal .app + DMG.
#
# Output naming (fixed):
#   ece-r4301  ->  dosbox-ece-r4301.app  (executable: dosbox-ece-r4301)  + dosbox-ece-r4301.dmg
#   ece-r4358  ->  dosbox-ece-r4358.app  (executable: dosbox-ece-r4358)  + dosbox-ece-r4358.dmg
#   ece-r4482  ->  dosbox-ece-r4482.app  (executable: dosbox-ece-r4482)  + dosbox-ece-r4482.dmg
#
# The app icon is the DOSBox ECE icon, extracted from src/dosbox.ico inside
# the ECE source tree (the same icon Yesterplay's Windows builds use) and
# converted to .icns with sips + iconutil — no extra tools, no downloads.
#
# Every non-system dylib is bundled into Contents/Frameworks with @rpath
# install names; a final audit verifies that NO Mach-O in the bundle requires
# anything newer than macOS 11.0 and that no external paths remain.
#
# Usage:
#   ./package_macos.sh <ece-source-dir> [output-dir] [options]
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

ECE_DIR=""
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
            echo "Usage: $0 <ece-source-dir> [output-dir] [--sign <id>] [--apple-id <email>] [--team-id <id>] [--password <pw>] [--keychain-profile <name>]"
            exit 1
            ;;
        *)
            if [ -z "$ECE_DIR" ]; then
                ECE_DIR="$1"
            else
                OUTPUT_DIR="$1"
            fi
            shift
            ;;
    esac
done

if [ -z "$ECE_DIR" ] || [ ! -d "$ECE_DIR" ]; then
    echo "Usage: $0 <ece-source-dir> [output-dir] [options]"
    echo "  e.g. $0 ece-r4482"
    exit 1
fi

BINARY="$ECE_DIR/src/dosbox"
if [ ! -x "$BINARY" ]; then
    echo "ERROR: Binary not found at $BINARY"
    echo "  Run build_all_ece.sh first."
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

if [ -f "$ECE_DIR/VERSION.txt" ]; then
    BASE_VERSION=$(tr -d '[:space:]' < "$ECE_DIR/VERSION.txt")
else
    BASE_VERSION="ECE"
fi

DIR_BASENAME=$(basename "$ECE_DIR")
REVISION=$(echo "$DIR_BASENAME" | grep -oE 'r[0-9]+' || echo "")
if [ -z "$REVISION" ]; then
    echo "ERROR: could not derive an rXXXX revision from directory name '$DIR_BASENAME'"
    echo "  Expected something like ece-r4482."
    exit 1
fi

APP_NAME="dosbox-ece-${REVISION}"          # dosbox-ece-r4482
EXECUTABLE_NAME="$APP_NAME"                # dosbox-ece-r4482
APP_DISPLAY_NAME="DOSBox ECE ${REVISION}"  # menu bar / Finder display
BUNDLE_ID="net.yesterplay.dosbox-ece-${REVISION}"
FULL_VERSION="${BASE_VERSION}-${REVISION}"
DMG_NAME="$APP_NAME"                       # dosbox-ece-r4482.dmg
ICON_BASENAME="dosbox-ece"

echo "=== DOSBox ECE macOS Packager ==="
echo "  Source:     $ECE_DIR"
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
STAGING=$(mktemp -d "$OUTPUT_DIR/.dosbox-pkg-XXXXXX")
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

# ── [2/8] Build the DOSBox ECE icon ──────────────────────────────────────────
# Preferred source: src/dosbox.ico inside the ECE source tree — this is the
# DOSBox *ECE* icon (the one embedded in Yesterplay's Windows builds), NOT
# the stock DOSBox icon that lives in src/platform/macosx/dosbox.icns.

ICON_OK=0
ICNS_OUT="$STAGING/$ICON_BASENAME.icns"

build_icns_from_ico() {
    local ico="$1"
    local master="$STAGING/ece-icon-master.png"
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

if build_icns_from_ico "$ECE_DIR/src/dosbox.ico"; then
    echo "[2/8] Built $ICON_BASENAME.icns from ECE source icon (src/dosbox.ico)"
    ICON_OK=1
elif [ -f "$SCRIPT_DIR/dosbox-ece.icns" ]; then
    cp "$SCRIPT_DIR/dosbox-ece.icns" "$ICNS_OUT"
    echo "[2/8] Used pre-made dosbox-ece.icns from the script directory"
    ICON_OK=1
elif [ -f "$ECE_DIR/src/platform/macosx/dosbox.icns" ]; then
    cp "$ECE_DIR/src/platform/macosx/dosbox.icns" "$ICNS_OUT"
    echo "[2/8] WARNING: fell back to the ORIGINAL DOSBox icon"
    echo "      (src/dosbox.ico missing or unreadable — the bundle will not"
    echo "       show the ECE logo)"
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

# ── [3/8] Write Info.plist ───────────────────────────────────────────────────

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
    <string>DOSBox ECE — GNU GPL v2</string>
</dict>
</plist>
PLIST

echo "[3/8] Wrote Info.plist"

# ── [4/8] Bundle every non-system dylib into Frameworks/ ─────────────────────
# --also-bundle libSDL2: the binary links the sdl12-compat shim
# (libSDL-1.2.0.dylib), which dlopen()s libSDL2 at runtime, so otool -L on
# the binary never shows it. Without force-bundling, the app dies on a fresh
# system with "sdl12-compat: Failed loading SDL2 library."

echo "[4/8] Bundling dependencies into .app/Contents/Frameworks/ ..."
ALSO_BUNDLE=()
SDL2_LIB=""
for cand in \
    "$DEPS_PREFIX/lib/libSDL2-2.0.0.dylib" \
    "$DEPS_PREFIX/lib/libSDL2.dylib"; do
    if [ -e "$cand" ]; then
        SDL2_LIB="$cand"
        break
    fi
done
if [ -n "$SDL2_LIB" ]; then
    ALSO_BUNDLE=(--also-bundle "$SDL2_LIB")
    echo "  --also-bundle: $(basename "$SDL2_LIB")  (dlopen'd by sdl12-compat)"
else
    echo "  WARNING: libSDL2-2.0.0.dylib not found in $DEPS_PREFIX/lib —"
    echo "           sdl12-compat shim will fail at runtime."
fi

python3 "$BUNDLER" "$MACOS_DIR/$EXECUTABLE_NAME" "$FRAMEWORKS" \
    ${ALSO_BUNDLE[@]+"${ALSO_BUNDLE[@]}"} \
    "$DEPS_PREFIX/lib"

# NOTE: on a universal binary `otool -L` prints one header line PER SLICE
# ("/path/to/binary (architecture arm64):"), so `tail -n +2` is not enough —
# keep only true dylib-reference lines (they all carry "compatibility
# version") before checking for external paths.
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
# Walk EVERY Mach-O in the bundle (executable + all dylibs) and verify no
# slice declares a minimum OS newer than $MACOS_MIN. This guarantees the
# bundle contains no library or binary blob that requires anything newer
# than macOS 11.

echo "[5/8] Auditing minimum-OS of every Mach-O in the bundle..."
AUDIT_FAIL=0
while IFS= read -r machofile; do
    minos_list=$(otool -l "$machofile" 2>/dev/null \
        | awk '/^ *minos /{print $2} /LC_VERSION_MIN_MACOSX/{grab=1} grab&&/^ *version /{print $2; grab=0}' \
        | sort -u)
    for v in $minos_list; do
        # numeric compare major.minor against MACOS_MIN (11.0)
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
    # Hardened runtime + JIT entitlements. The dynamic recompiler needs:
    #   allow-jit                        -> mmap(MAP_JIT) on Apple Silicon
    #   allow-unsigned-executable-memory -> classic RWX path on Intel
    ENTITLEMENTS="$STAGING/dosbox-ece.entitlements"
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

# Keep only the .app + /Applications symlink in the DMG.
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
