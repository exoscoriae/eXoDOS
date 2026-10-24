#!/bin/bash
# Build one ScummVM version as a portable universal macOS 11+ app bundle.
# Usage: ./build-one.sh <bundle-name> <git tag or full commit sha>
set -euo pipefail
cd "$(dirname "$0")"

NAME=${1:?usage: build-one.sh <name> <ref>}
REF=${2:?usage: build-one.sh <name> <ref>}
PLATFORM=linux/amd64
SCUMMVM_REPO=https://github.com/scummvm/scummvm.git
JOBS=$(sysctl -n hw.ncpu)

SRC=$PWD/work/src/$NAME
OUT=$PWD/out
mkdir -p "$OUT" work/src work/build

# ---------------------------------------------------------------- fetch source
if [ ! -f "$SRC/configure" ]; then
    rm -rf "$SRC"; mkdir -p "$SRC"
    if [[ "$REF" =~ ^[0-9a-f]{40}$ ]]; then
        git -C "$SRC" init -q
        git -C "$SRC" remote add origin "$SCUMMVM_REPO"
        git -C "$SRC" fetch --depth 1 origin "$REF"
        git -C "$SRC" checkout -q FETCH_HEAD
    else
        git clone --depth 1 --branch "$REF" "$SCUMMVM_REPO" "$SRC"
    fi
fi

# ---------------------------------------------------------------- compat fixes for old trees
# ICB px_array.h: invalid const-member assignment; upstream later fixed it with
# const_cast. Modern clang rejects the old form outright.
PX="$SRC/engines/icb/common/px_array.h"
if [ -f "$PX" ] && grep -q '((const rcActArray<Type> \*)this)' "$PX"; then
    echo ">>> Applying px_array const_cast fix"
    sed -i '' \
        -e 's/((const rcActArray<Type> \*)this)/(const_cast<rcActArray<Type> *>(this))/g' \
        -e 's/((const rcIntArray<Type> \*)this)/(const_cast<rcIntArray<Type> *>(this))/g' \
        -e 's/((const rcAutoArray<Type> \*)this)/(const_cast<rcAutoArray<Type> *>(this))/g' \
        "$PX"
fi
# AGS vendored FreeType 2.1.3: signed/unsigned pointer mismatches that are hard
# errors in C++ under modern clang; upstream later fixed these with unsigned
# declarations (guarded by FT version checks). Apply to trees lacking the fix.
AHG="$SRC/engines/ags/lib/freetype-2.1.3/autohint/ahglyph.cpp"
if [ -f "$AHG" ] && ! grep -q "2013003" "$AHG"; then
    echo ">>> Applying AGS freetype signedness fix"
    sed -i '' \
        -e 's/^\([[:space:]]*\)char \*tag = gloader->current\.outline\.tags;/\1unsigned char *tag = gloader->current.outline.tags;/' \
        -e 's/^\([[:space:]]*\)char \*tag = source->tags;/\1unsigned char *tag = source->tags;/' \
        -e 's/^\([[:space:]]*\)short \*end = source->contours;/\1unsigned short *end = source->contours;/' \
        "$AHG"
fi

# Older ports.mk (<= 2.8) hardcodes the macOS static-lib list and predates
# sonivox, so USE_SONIVOX builds but never links. Append the block upstream
# added later (no-op on trees where USE_SONIVOX is never defined).
PM="$SRC/ports.mk"
if [ -f "$PM" ] && grep -q "OSX_STATIC_LIBS" "$PM" && ! grep -q "SONIVOX" "$PM"; then
    echo ">>> Adding sonivox to ports.mk static-lib list"
    cat >> "$PM" <<'EOF'

ifdef USE_SONIVOX
OSX_STATIC_LIBS += $(STATICLIBPATH)/lib/libsonivox-static.a
endif
EOF
fi

# Optional user-provided patches: macos/patches/<name>/*.patch (-p1)
if compgen -G "patches/$NAME/*.patch" > /dev/null; then
    for p in patches/$NAME/*.patch; do
        echo ">>> Applying $p"
        patch -d "$SRC" -tN -p1 < "$p" || true
    done
fi

# ---------------------------------------------------------------- per-arch builds
for arch in x86_64 arm64; do
    BUILD=$PWD/work/build/$NAME/$arch
    mkdir -p "$BUILD"
    echo ">>> Building $NAME for $arch"
    docker run --rm --platform=$PLATFORM \
        -v "$SRC":/src:ro \
        -v "$BUILD":/build \
        -w /build \
        -e DISCORD_LIBS="-framework AppKit" \
        scummvm-macos11-$arch \
        bash -ec '
            /src/configure --host=$HOST \
                --enable-release --disable-debug \
                --enable-all-engines \
                --disable-system-dialogs \
                --enable-static \
                --with-staticlib-prefix=${DESTDIR}/${PREFIX} \
                --disable-osx-dock-plugin
            make -j'"$JOBS"'
            make bundle
        '
    test -d "$BUILD/ScummVM.app" || { echo "ERROR: no bundle produced for $arch"; exit 1; }
done

# ---------------------------------------------------------------- merge to universal
echo ">>> Merging universal bundle"
APP="$OUT/$NAME.app"
rm -rf "$APP"
cp -R "work/build/$NAME/arm64/ScummVM.app" "$APP"

BIN_DIR="$APP/Contents/MacOS"
for f in "$BIN_DIR"/*; do
    base=$(basename "$f")
    other="work/build/$NAME/x86_64/ScummVM.app/Contents/MacOS/$base"
    if file "$f" | grep -q "Mach-O"; then
        test -f "$other" || { echo "ERROR: $base missing in x86_64 bundle"; exit 1; }
        lipo -create "$f" "$other" -output "$f.universal"
        mv "$f.universal" "$f"
        chmod +x "$f"
    fi
done

# ---------------------------------------------------------------- rename app + executable
mv "$BIN_DIR/scummvm" "$BIN_DIR/$NAME"
PB=/usr/libexec/PlistBuddy
PLIST="$APP/Contents/Info.plist"
$PB -c "Set :CFBundleExecutable $NAME" "$PLIST"
$PB -c "Set :CFBundleIdentifier org.scummvm.$NAME" "$PLIST"
$PB -c "Set :CFBundleName $NAME" "$PLIST" 2>/dev/null || true
$PB -c "Set :CFBundleDisplayName $NAME" "$PLIST" 2>/dev/null || \
    $PB -c "Add :CFBundleDisplayName string $NAME" "$PLIST" || true
# Declare our support floor in the plist as well
$PB -c "Set :LSMinimumSystemVersion 11.0" "$PLIST" 2>/dev/null || \
    $PB -c "Add :LSMinimumSystemVersion string 11.0" "$PLIST" || true

# ---------------------------------------------------------------- sign + verify + zip
echo ">>> Ad-hoc signing"
codesign --force --deep --sign - "$APP"
codesign --verify --deep "$APP"

echo ">>> Verifying portability"
./verify-bundle.sh "$APP"

echo ">>> Zipping"
rm -f "$OUT/$NAME.app.zip"
ditto -c -k --keepParent "$APP" "$OUT/$NAME.app.zip"

echo ">>> Done: $APP"
