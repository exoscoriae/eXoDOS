#!/usr/bin/env bash
# build_gunstick_windows.sh — Build DOSBox Gunstick (DOSBox 0.74-3 + lightgun
# patches) on Windows under MSYS2, with the FULLSCREEN LIGHTGUN FIX applied,
# and stage a fully portable folder (DOSBox.exe + every needed DLL).
#
# One-time setup:
#   1. Install MSYS2 from https://www.msys2.org
#   2. Open one of these shells from the Start menu:
#        "MSYS2 MINGW64"  -> 64-bit build, dynrec core (risc_x64)
#        "MSYS2 MINGW32"  -> 32-bit build, classic dyn_x86 core
#      (UCRT64 also works and builds like MINGW64.)
#   3. cd to this script's directory and run:  ./build_gunstick_windows.sh
#
# The script installs its build dependencies with pacman (MSYS2's package
# manager), downloads dosbox-gunstick.tar.gz if it isn't already present
# next to the script, applies the fullscreen lightgun patch (embedded below,
# identical to the macOS-build and flatpak fix), builds, and stages:
#
#     dosbox-gunstick-win-<arch>/
#         DOSBox.exe
#         *.dll                (all transitive MinGW dependencies)
#
# That folder runs on any Windows machine of the same architecture — no
# MSYS2 or other runtime required on the target.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NPROC="$(nproc 2>/dev/null || echo 4)"

msg()  { printf '\033[36m[build]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[ ok  ]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[warn ]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[err  ]\033[0m %s\n' "$*" >&2; exit 1; }

# ── MSYS2 environment check ──────────────────────────────────────────────────

case "${MSYSTEM:-}" in
    MINGW64|UCRT64|MINGW32) ;;
    MSYS)
        die "You are in the plain MSYS shell. Open 'MSYS2 MINGW64' (or MINGW32) from the Start menu instead." ;;
    *)
        die "Not an MSYS2 MinGW shell (MSYSTEM='${MSYSTEM:-unset}'). Install MSYS2 from https://www.msys2.org and open the MINGW64 shell." ;;
esac

PKGPFX="${MINGW_PACKAGE_PREFIX:?}"     # e.g. mingw-w64-x86_64
MPREFIX="${MINGW_PREFIX:?}"            # e.g. /mingw64
case "$MSYSTEM" in
    MINGW32) ARCH_LABEL=x86 ;;
    *)       ARCH_LABEL=x64 ;;
esac

msg "MSYS2 environment: $MSYSTEM  (packages: $PKGPFX, prefix: $MPREFIX)"

# ── Install build dependencies via pacman ────────────────────────────────────
# Base (msys) tools + MinGW toolchain and libraries. sdl12-compat provides
# the SDL 1.2 API on top of SDL2 — same arrangement as the macOS build.

msg "Installing build dependencies (pacman --needed skips anything present)..."
pacman -S --needed --noconfirm \
    autoconf automake libtool make patch tar curl \
    "${PKGPFX}-toolchain" \
    "${PKGPFX}-pkgconf" \
    "${PKGPFX}-sdl12-compat" \
    "${PKGPFX}-SDL_net" \
    "${PKGPFX}-libpng" \
    "${PKGPFX}-zlib" \
    || die "pacman failed — check your MSYS2 installation / network."

# SDL_sound (compressed CD-audio images) is optional and not always packaged.
HAVE_SDL_SOUND=0
if pacman -S --needed --noconfirm "${PKGPFX}-SDL_sound" 2>/dev/null; then
    HAVE_SDL_SOUND=1
    ok "SDL_sound available (compressed CD-audio image support)"
else
    warn "SDL_sound package not available — building without compressed CD-audio support."
fi

# ── Get the source ───────────────────────────────────────────────────────────

TARBALL="$SCRIPT_DIR/dosbox-gunstick.tar.gz"
SRC_URL="https://github.com/jonesaaronj/exo_flatpaks/releases/download/source_bundles/dosbox-gunstick.tar.gz"
SRC_SHA256="21504391b7c4374ac0cee90fa8c2fe019e0c007f1ce30b9375a68f46236ebd2f"

if [ ! -f "$TARBALL" ]; then
    msg "downloading dosbox-gunstick.tar.gz ..."
    curl -fL --retry 3 "$SRC_URL" -o "$TARBALL.tmp" && mv "$TARBALL.tmp" "$TARBALL" \
        || { rm -f "$TARBALL.tmp"; die "could not download dosbox-gunstick.tar.gz"; }
fi
echo "$SRC_SHA256  $TARBALL" | sha256sum -c - >/dev/null \
    || die "dosbox-gunstick.tar.gz checksum mismatch — delete it and re-run."
ok "source tarball verified (sha256)"

BUILD_DIR="$SCRIPT_DIR/dosbox-gunstick-win-src"
msg "extracting into $(basename "$BUILD_DIR") (clean)..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
tar --strip-components=1 -xzf "$TARBALL" -C "$BUILD_DIR"
cd "$BUILD_DIR"

# ── Apply the fullscreen lightgun fix ────────────────────────────────────────
# Identical to the macOS-build patch and the flatpak lightgun-fullscreen.patch:
# the gun samples absolute SDL mouse coordinates, but in fullscreen the image
# is letterboxed at (sdl.clip.x, sdl.clip.y) — without subtracting those
# offsets, clicks sample the wrong pixel and the gun misses. Shots into the
# black bars now read as dark pixels (a miss).

msg "applying the fullscreen lightgun fix..."
patch -p1 --forward << 'LIGHTGUN_PATCH_EOF'
--- a/src/gui/sdlmain.cpp	2026-05-19 21:38:25.000000000 -0500
+++ b/src/gui/sdlmain.cpp	2026-07-17 15:43:33.765004471 -0500
@@ -1463,7 +1463,11 @@
 }
 
 static void HandleMouseMotion(SDL_MouseMotionEvent * motion) {
-    Mouse_CursorMoved_GunStick(motion->x, motion->y, sdl.clip.w, sdl.clip.h);
+    /* Fullscreen fix: the drawn image is letterboxed at
+	   (sdl.clip.x, sdl.clip.y) inside the surface; the gun must
+	   sample in image-relative coordinates or fullscreen shots
+	   land right/down of the aim point. */
+	Mouse_CursorMoved_GunStick(motion->x - sdl.clip.x, motion->y - sdl.clip.y, sdl.clip.w, sdl.clip.h);
 	if (sdl.mouse.locked || !sdl.mouse.autoenable)
 		Mouse_CursorMoved((float)motion->xrel*sdl.mouse.sensitivity/100.0f,
 						  (float)motion->yrel*sdl.mouse.sensitivity/100.0f,
--- a/src/ints/mouse.cpp	2026-05-19 21:49:07.000000000 -0500
+++ b/src/ints/mouse.cpp	2026-07-17 15:43:33.766004471 -0500
@@ -520,6 +520,11 @@
     if(!sdlw || !sdlh)
         return 0;
 
+    /* Fullscreen letterbox fix: coordinates outside the active
+       image (the black bars) cannot hit anything — read as dark. */
+    if(sdlx < 0 || sdly < 0 || sdlx >= sdlw || sdly >= sdlh)
+        return 0;
+
     x = sdlx * CurMode->swidth / sdlw;
     y = sdly * CurMode->sheight / sdlh;
 
LIGHTGUN_PATCH_EOF
ok "fullscreen lightgun fix applied"

# ── Win64 compatibility fix ──────────────────────────────────────────────────
# 0.74-3 predates 64-bit Windows: midiOutOpen's callback parameter is
# DWORD_PTR (pointer-sized), but the old code casts the event HANDLE to a
# 32-bit DWORD — a hard error on Win64 GCC. Upstream DOSBox SVN later made
# this exact change. Harmless on 32-bit (DWORD_PTR == DWORD there).

msg "applying Win64 MIDI callback cast fix..."
sed -i 's/(DWORD)m_event/(DWORD_PTR)m_event/g' src/gui/midi_win32.h
grep -q '(DWORD_PTR)m_event' src/gui/midi_win32.h \
    || die "midi_win32.h Win64 fix did not apply"
ok "midi_win32.h: HANDLE cast widened to DWORD_PTR"

# ── Fullscreen focus-loss fix ────────────────────────────────────────────────
# DOSBox 0.74-3 has a Win32-only workaround that force-exits fullscreen
# whenever input focus is lost (the SDL 1.2 DirectX driver couldn't survive
# alt-tab). Under sdl12-compat/SDL2 the fullscreen mode switch ITSELF fires
# a transient focus-loss event, so every fullscreen attempt (Alt+Enter or
# fullscreen=true) flickered and instantly reverted to a window. SDL2
# handles alt-tab from fullscreen fine on its own, so the workaround goes.

msg "applying the fullscreen focus-loss fix..."
patch -p1 --forward << 'FULLSCREEN_FOCUS_PATCH_EOF'
--- a/src/gui/sdlmain.cpp	2026-05-19 21:38:25.000000000 -0500
+++ b/src/gui/sdlmain.cpp	2026-07-17 16:33:57.795005913 -0500
@@ -1588,13 +1588,13 @@
 					CPU_Disable_SkipAutoAdjust();
 				} else {
 					if (sdl.mouse.locked) {
-#ifdef WIN32
-						if (sdl.desktop.fullscreen) {
-							VGA_KillDrawing();
-							sdl.desktop.fullscreen=false;
-							GFX_ResetScreen();
-						}
-#endif
+						/* NOTE: the old Win32-only block that forced an exit from
+						   fullscreen on focus loss (a workaround for the SDL 1.2
+						   DirectX driver) is removed: under sdl12-compat/SDL2 the
+						   fullscreen mode switch itself fires a transient focus
+						   loss, which made every fullscreen attempt instantly
+						   revert to a window. SDL2 handles alt-tab from real
+						   fullscreen fine on its own. */
 						GFX_CaptureMouse();
 					}
 					SetPriority(sdl.priority.nofocus);
FULLSCREEN_FOCUS_PATCH_EOF
ok "fullscreen focus-loss fix applied"

# ── DPI scaling fix ──────────────────────────────────────────────────────────
# Declare the process per-monitor DPI aware (V2) BEFORE any window is
# created, so Windows never applies its own bitmap scaling to the window —
# that scaling is what caused the blurry/mis-sized output regardless of the
# SDL_WINDOWS_DPI_SCALING hint (which the modern SDL stack under
# sdl12-compat does not reliably honor). Win10 1703+ uses
# SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2); older Windows falls
# back to SetProcessDPIAware().

msg "applying the DPI awareness fix..."
patch -p1 --forward << 'DPI_AWARE_PATCH_EOF'
--- a/src/gui/sdlmain.cpp	2026-05-19 21:38:25.000000000 -0500
+++ b/src/gui/sdlmain.cpp	2026-07-24 11:26:04.630000806 -0500
@@ -1942,7 +1942,29 @@
 
 
 //extern void UI_Init(void);
+#if defined (WIN32)
+static void SetProcessDPIAware_Compat() {
+	//Declare DPI awareness before any window is created, so Windows does not
+	//apply its own bitmap scaling to our window (which is what causes the
+	//blurry/mis-sized behaviour independent of the SDL_WINDOWS_DPI_SCALING hint).
+	typedef BOOL (WINAPI *SetProcessDpiAwarenessContext_t)(HANDLE);
+	typedef BOOL (WINAPI *SetProcessDPIAware_t)(void);
+	HMODULE user32 = GetModuleHandleA("user32.dll");
+	if (user32) {
+		SetProcessDpiAwarenessContext_t pSetCtx =
+			(SetProcessDpiAwarenessContext_t)GetProcAddress(user32,"SetProcessDpiAwarenessContext");
+		//DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 == (HANDLE)-4, available Win10 1703+
+		if (pSetCtx && pSetCtx((HANDLE)-4)) return;
+		SetProcessDPIAware_t pOld = (SetProcessDPIAware_t)GetProcAddress(user32,"SetProcessDPIAware");
+		if (pOld) pOld();
+	}
+}
+#endif
+
 int main(int argc, char* argv[]) {
+#if defined (WIN32)
+	SetProcessDPIAware_Compat();
+#endif
 	try {
 		CommandLine com_line(argc,argv);
 		Config myconf(&com_line);
DPI_AWARE_PATCH_EOF
ok "DPI awareness fix applied"

# ── Build ────────────────────────────────────────────────────────────────────

msg "regenerating the build system (autoreconf)..."
autoreconf -fiv >/dev/null

# gnu++14: keeps 0.74-3's legacy C++ (register storage class, etc.) valid
# under current GCC. Configure auto-detects the target CPU:
#   MINGW64/UCRT64 -> x86_64 -> dynrec core (risc_x64)
#   MINGW32        -> i686   -> classic dyn_x86 core
msg "running ./configure ..."
./configure \
    CFLAGS="-O2" \
    CXXFLAGS="-O2 -std=gnu++14" \
    --enable-core-inline \
    --enable-dynamic-core \
    --enable-fpu \
    --enable-opengl \
    || die "configure failed"

msg "building (-j$NPROC)..."
make -j"$NPROC" || die "build failed"

EXE="$BUILD_DIR/src/dosbox.exe"
[ -f "$EXE" ] || die "build finished but src/dosbox.exe is missing?!"

# ── Verify the dynamic core made it in ───────────────────────────────────────

case "$MSYSTEM" in
    MINGW32) CORE_SYM="CPU_Core_Dyn_X86_Run"; CORE_DESC="classic dyn_x86 core" ;;
    *)       CORE_SYM="CPU_Core_Dynrec_Run";  CORE_DESC="dynrec core (risc_x64)" ;;
esac
if nm "$EXE" 2>/dev/null | grep "$CORE_SYM" >/dev/null; then
    ok "dynamic core verified in the exe ($CORE_DESC)"
else
    warn "could not find $CORE_SYM in the exe — dynamic core may be missing!"
fi

# ── Stage the portable folder ────────────────────────────────────────────────

OUT="$SCRIPT_DIR/dosbox-gunstick-win-$ARCH_LABEL"
msg "staging portable folder $(basename "$OUT")..."
rm -rf "$OUT"
mkdir -p "$OUT"
cp "$EXE" "$OUT/DOSBox.exe"

# Copy every transitive MinGW DLL dependency (fixpoint over ldd output so
# DLL-of-DLL dependencies — e.g. SDL.dll -> SDL2.dll — are picked up too).
msg "collecting DLL dependencies..."
changed=1
while [ "$changed" = "1" ]; do
    changed=0
    for f in "$OUT"/*.exe "$OUT"/*.dll; do
        [ -e "$f" ] || continue
        for dll in $(ldd "$f" 2>/dev/null | awk -v p="$MPREFIX" 'index($3, p) == 1 {print $3}'); do
            base="$(basename "$dll")"
            if [ ! -e "$OUT/$base" ]; then
                cp "$dll" "$OUT/$base"
                changed=1
            fi
        done
    done
done
ok "$(ls "$OUT"/*.dll 2>/dev/null | wc -l | tr -d ' ') DLL(s) bundled"

cat > "$OUT/README.txt" << 'README_EOF'
DOSBox Gunstick for Windows (portable)
======================================
DOSBox 0.74-3 with lightgun/gunstick input support and the fullscreen
lightgun fix (mouse clicks now fire correctly in fullscreen, not just
in a window).

Run DOSBox.exe — no installation needed. Keep the DLLs in the
same folder as the exe.
README_EOF

echo
ok "Done: $OUT"
ls -1 "$OUT" | sed 's/^/    /'
echo
msg "Test the fix: run a lightgun game, toggle fullscreen (Alt+Enter), and"
msg "confirm mouse clicks register at the aimed position."
