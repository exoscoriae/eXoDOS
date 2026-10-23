#!/usr/bin/env bash
# lib/wine.sh -- configure, build and install Wine itself.
#
# Wine's Unix side is built for x86_64 only.  That is a deliberate decision,
# not an oversight:
#
#   * Running 32-bit and 64-bit x86 Windows binaries is the goal.  On Apple
#     Silicon the only x86 execution engine available on macOS is Rosetta 2,
#     and Rosetta translates whole processes -- an arm64 Wine cannot host x86
#     guest code.  FEX, which CrossOver uses for this on Linux ARM64, has no
#     macOS host port.
#   * So the wine loader, wineserver and every unix-side .so must be x86_64.
#     On Intel Macs they run natively; on Apple Silicon the launcher exec()s
#     them and the kernel hands them to Rosetta.
#   * --enable-archs=i386,x86_64 builds both PE worlds with Wine 11's new
#     WoW64, so 32-bit Windows apps work without any 32-bit host code -- which
#     macOS has not supported since Catalina.
#
# The arm64 slices of the bundled support libraries are still produced so the
# shipped dylibs are universal and a future native ARM64 Wine slice can be
# dropped in beside this one.
# shellcheck shell=bash

WINE_SRC=""
WINE_PATCH_FP=""

# --------------------------------------------------------------------------
# Source patches
#
# Identity of the patch set: everything that decides what the prepared tree
# looks like.  extract() reuses $SOURCES/wine-<ver> whenever the directory
# exists, so without this a tree prepared by an older lib/wine.sh would survive
# a rebuild untouched and the build would succeed while silently shipping the
# previous patch set.  (That is not hypothetical -- see the openglhq note in
# dosbox-daum/lib/daum.sh, which is the same failure one project over.)
# --------------------------------------------------------------------------
wine_patch_fingerprint() {
  {
    printf 'WINE_VERSION=%s\n' "$WINE_VERSION"
    sha256_of "$SCRIPT_DIR/lib/wine.sh"
  } | /usr/bin/shasum -a 256 | awk '{print $1}'
}

# Fetch, extract and patch the Wine tree, leaving the result in $WINE_SRC.
wine_prepare() {
  local root cur
  root="$(extract "$(fetch "$WINE_URL")")"
  WINE_PATCH_FP="$(wine_patch_fingerprint)"
  cur="$(cat "$root/.wine-patched" 2>/dev/null || true)"

  if [[ "$cur" == "$WINE_PATCH_FP" ]]; then
    WINE_SRC="$root"
    ok "sources already patched"
    return 0
  fi

  # A stamp that exists but does not match means this tree carries a different
  # patch set.  Every edit below is marker-guarded, so re-running is safe on a
  # partially patched tree -- but not on a differently patched one, where the
  # markers are present and the anchors are gone.  Start clean instead.
  if [[ -n "$cur" ]]; then
    say "patch set changed since this tree was prepared -- re-extracting"
    rm -rf "$root"
    root="$(extract "$(fetch "$WINE_URL")")"
  fi

  # once() keys on WINE_VERSION alone, so a build stamp left by an unpatched or
  # differently patched tree would skip the rebuild entirely and re-bundle the
  # previous binaries.  Drop it, and the object tree with it: configure has
  # already recorded the old source paths there.
  stamp_clear "wine-${WINE_VERSION}"
  rm -rf "$BUILD/obj/wine"

  wine_patch_sources "$root"
  printf '%s\n' "$WINE_PATCH_FP" > "$root/.wine-patched"
  WINE_SRC="$root"
}

wine_patch_sources() {
  local root="$1"
  say "patching Wine sources"
  python3 - "$root" <<'PYEOF' || die "wine source patching failed (see message above)"
# Written against the actual wine-11.0 tree, not guessed.  Every edit is a
# literal replacement that asserts its exact occurrence count and aborts with
# the offending anchor printed, so a future Wine release that moves this code
# fails loudly instead of silently skipping the patch.
import os, sys

root = sys.argv[1]
changed = []

def read(p):
    with open(p, 'r', errors='surrogateescape') as f: return f.read()

def write(p, s):
    with open(p, 'w', errors='surrogateescape') as f: f.write(s)
    changed.append(os.path.relpath(p, root))

def bail(msg, context=""):
    sys.stderr.write("\n  PATCH FAILURE: %s\n" % msg)
    if context:
        sys.stderr.write("  --- anchor that no longer matches ---\n")
        for line in context.splitlines()[:40]:
            sys.stderr.write("    %s\n" % line)
    sys.exit(1)

def rep(s, old, new, what, expect=1):
    """Literal replacement asserting an exact occurrence count."""
    n = s.count(old)
    if n != expect:
        bail("expected %d occurrence(s), found %d: %s" % (expect, n, what), old)
    return s.replace(old, new)

def need(rel):
    p = os.path.join(root, *rel.split('/'))
    if not os.path.exists(p): bail("%s is missing" % rel)
    return p

# ============================================================ conhost.c
#
# Patch 1 of 1 (diagnostic).  The raw-mode setup path for a Unix terminal is
# silent from end to end:
#
#   * ensure_tty_input_thread() returns TRUE -- success -- when tty_input is
#     NULL, without starting the thread that sends IOCTL_CONDRV_SETUP_INPUT.
#   * All six lazy call sites in console_input_ioctl() discard its return, so a
#     failed CreateThread is equally silent.
#   * main() only calls it under !is_unix, and && short-circuits, so on the
#     --unix path it is never reached there at all.
#
# A console whose keyboard never leaves canonical mode is therefore
# indistinguishable from one that was set up correctly, which is why this bug
# produces no diagnostic of any kind.  These probes are compiled in
# unconditionally and gated at RUN time, so toggling them costs no rebuild.
p = need('programs/conhost/conhost.c')
s = read(p)

if 'CONSOLE_PROBE' not in s:
    s = rep(s,
        'WINE_DEFAULT_DEBUG_CHANNEL(console);\n',
        'WINE_DEFAULT_DEBUG_CHANNEL(console);\n'
        r'''
/* --- console input diagnostics ----------------------------------------- *
 * Added by build-wine.sh (lib/wine.sh, wine_patch_sources).  NOT upstream.
 * Enable at run time; no rebuild required:
 *     WINE_CONSOLE_PROBE=1 wine cmd /c pause 2>/tmp/probe.log
 */
static BOOL console_probe_enabled(void)
{
    static int enabled = -1;
    if (enabled == -1)
        enabled = GetEnvironmentVariableA( "WINE_CONSOLE_PROBE", NULL, 0 ) != 0;
    return enabled;
}

#define CONSOLE_PROBE(fmt, ...) \
    do { if (console_probe_enabled()) ERR( fmt, ##__VA_ARGS__ ); } while (0)
''',
        "insert the console probe helper after WINE_DEFAULT_DEBUG_CHANNEL")

    # (a) tty_input() -- entry, and the SETUP_INPUT round trip.  Replaced as a
    #     whole block: `if (console->is_unix)` alone occurs many times, and the
    #     teardown copy of this ioctl differs only in `h = 0` and its message.
    s = rep(s,
        r'''    if (console->is_unix)
    {
        unsigned int h = condrv_handle( console->tty_input );
        status = NtDeviceIoControlFile( console->server, NULL, NULL, NULL, &io, IOCTL_CONDRV_SETUP_INPUT,
                                        &h, sizeof(h), NULL, 0 );
        if (status) ERR( "input setup failed: %#lx\n", status );
    }
''',
        r'''    CONSOLE_PROBE( "tty_input thread running: tty_input=%p is_unix=%d\n",
                   console->tty_input, (int)console->is_unix );

    if (console->is_unix)
    {
        unsigned int h = condrv_handle( console->tty_input );
        status = NtDeviceIoControlFile( console->server, NULL, NULL, NULL, &io, IOCTL_CONDRV_SETUP_INPUT,
                                        &h, sizeof(h), NULL, 0 );
        if (status) ERR( "input setup failed: %#lx\n", status );
        else CONSOLE_PROBE( "SETUP_INPUT accepted for condrv handle %#x\n", h );
    }
''',
        "instrument the SETUP_INPUT request in tty_input()")

    # (b) ensure_tty_input_thread() -- the silent early return.  This fires on
    #     every one of the six lazy call sites, so it identifies a NULL handle
    #     and a failed thread creation without touching any of them.
    s = rep(s,
        r'''static BOOL ensure_tty_input_thread( struct console *console )
{
    if (!console->tty_input) return TRUE;
''',
        r'''static BOOL ensure_tty_input_thread( struct console *console )
{
    CONSOLE_PROBE( "tty_input=%p input_thread=%p is_unix=%d\n",
                   console->tty_input, console->input_thread, (int)console->is_unix );
    if (!console->tty_input) return TRUE;
''',
        "instrument ensure_tty_input_thread()")

    # (c) main() -- the handles the whole chain depends on.
    s = rep(s,
        r'''        console.tty_input  = GetStdHandle( STD_INPUT_HANDLE );
        console.tty_output = GetStdHandle( STD_OUTPUT_HANDLE );
''',
        r'''        console.tty_input  = GetStdHandle( STD_INPUT_HANDLE );
        console.tty_output = GetStdHandle( STD_OUTPUT_HANDLE );

        CONSOLE_PROBE( "headless=%d is_unix=%d tty_input=%p tty_output=%p\n",
                       headless, (int)console.is_unix,
                       console.tty_input, console.tty_output );
''',
        "instrument the headless handle setup in main()")
    write(p, s)

# ============================================================ server/console.c
#
# The IOCTL_CONDRV_SETUP_INPUT handler has four exits that report nothing, and
# its two real failure paths both end in a bare file_set_error() -- so
# "tcgetattr said this is not a terminal" and "tcsetattr was refused" arrive at
# conhost as the same indistinguishable status.
p = need('server/console.c')
s = read(p)

if 'CONSOLE_PROBE' not in s:
    s = rep(s, '#include <termios.h>\n',
               '#include <termios.h>\n#include <errno.h>\n#include <stdlib.h>\n',
            "add errno.h and stdlib.h to server/console.c")

    s = rep(s, '\nstruct screen_buffer;\n',
            '\n'
            r'''/* --- raw-mode diagnostics ---------------------------------------------- *
 * Added by build-wine.sh (lib/wine.sh, wine_patch_sources).  NOT upstream.
 * Gated at run time by the same WINE_CONSOLE_PROBE that conhost honours.
 */
static int console_probe_enabled(void)
{
    static int enabled = -1;
    if (enabled == -1) enabled = getenv( "WINE_CONSOLE_PROBE" ) != NULL;
    return enabled;
}

#define CONSOLE_PROBE(fmt, ...) \
    do { if (console_probe_enabled()) \
             fprintf( stderr, "wineserver:console: " fmt, ##__VA_ARGS__ ); } while (0)

struct screen_buffer;
''',
            "insert the raw-mode probe helper in server/console.c")

    # The three silent exits before raw mode is even attempted.  isatty() is
    # logged too: if the fd is not a terminal, tcgetattr's failure is a
    # consequence and not the cause, and that distinction is the whole question.
    s = rep(s,
        r'''            handle = *(unsigned int *)get_req_data();
            if (!handle) return;
            if (!(file = get_file_obj( current->process, handle, FILE_READ_DATA  )))
            {
                return;
            }
            unix_fd = get_file_unix_fd( file );
            release_object( file );

            if (tcgetattr( unix_fd, &server->termios ))
            {
                file_set_error();
                return;
            }
''',
        r'''            handle = *(unsigned int *)get_req_data();
            CONSOLE_PROBE( "SETUP_INPUT handle=%#x\n", handle );
            if (!handle) return;   /* restore: sent by tty_input() on teardown */
            if (!(file = get_file_obj( current->process, handle, FILE_READ_DATA  )))
            {
                CONSOLE_PROBE( "get_file_obj(%#x) failed\n", handle );
                return;
            }
            unix_fd = get_file_unix_fd( file );
            release_object( file );
            CONSOLE_PROBE( "unix_fd=%d isatty=%d\n", unix_fd, isatty( unix_fd ) );

            if (tcgetattr( unix_fd, &server->termios ))
            {
                CONSOLE_PROBE( "tcgetattr(%d) failed: %s\n", unix_fd, strerror( errno ) );
                file_set_error();
                return;
            }
''',
        "instrument the silent exits in the SETUP_INPUT handler")

    # Split the combined condition so the two failures are distinguishable.
    # || short-circuited, so dup() still only runs when tcsetattr() succeeded:
    # behaviour is unchanged, only the reporting differs.
    s = rep(s,
        r'''            if (tcsetattr( unix_fd, TCSANOW, &term ) || (server->term_fd = dup( unix_fd )) == -1)
                file_set_error();
            return;
''',
        r'''            if (tcsetattr( unix_fd, TCSANOW, &term ))
            {
                CONSOLE_PROBE( "tcsetattr(%d) failed: %s\n", unix_fd, strerror( errno ) );
                file_set_error();
                return;
            }
            if ((server->term_fd = dup( unix_fd )) == -1)
            {
                CONSOLE_PROBE( "dup(%d) failed: %s\n", unix_fd, strerror( errno ) );
                file_set_error();
                return;
            }
            CONSOLE_PROBE( "raw mode active, term_fd=%d\n", server->term_fd );
            return;
''',
        "split the tcsetattr/dup failure paths so they are distinguishable")
    write(p, s)

# ============================================================ cmd/wcmdmain.c
#
# THE FIX.  `wine cmd /c pause` hangs forever on a Unix terminal.
#
# WCMD_wait_for_input() waits on the console input handle BEFORE it ever reads
# from it:
#
#     SetConsoleMode(hIn, oldmode & ~ENABLE_LINE_INPUT);
#     FlushConsoleInputBuffer(hIn);
#     while (...)
#         switch (WaitForMultipleObjects(2, h, FALSE, INFINITE))   <-- blocks
#         case WAIT_OBJECT_0: has_pending_char_events(hIn);         <-- never reached
#
# On a Wine *unix* console that deadlocks. The console input object can only
# become signaled once conhost's tty_input() thread is reading the terminal;
# that thread is only started by ensure_tty_input_thread(), which is only called
# from the six read/peek ioctls; and in this function the only call that issues
# one is has_pending_char_events() -- inside the loop body, after the wait. So
# the wait needs input, input needs the reader, and the reader needs a read that
# only happens once the wait returns.
#
# Priming the input path once before the loop breaks the cycle:
# has_pending_char_events() calls GetNumberOfConsoleInputEvents(), which is
# IOCTL_CONDRV_GET_INPUT_INFO, which starts the reader. The subsequent wait then
# behaves normally.
#
# Assigning return_code rather than returning early is deliberate -- it lets the
# SetConsoleMode(hIn, oldmode) restore at the end of the function still run.
#
# NOT macOS-specific, and not something this bundle introduced: reproduced
# identically on Linux with Flatpak com.retro_exo.wine reporting plain
# wine-11.0, and WCMD_wait_for_input is byte-identical between wine-11.0 and
# upstream master as of 2026-07-29. Report upstream.
#
# The alternative fix -- starting the tty reader eagerly in conhost by dropping
# the `!console.is_unix &&` guard in main() -- would fix every app that waits
# before reading, not just cmd. It is NOT used here: it would put the terminal
# in raw mode for the entire life of every console app, including ones that
# never read input, so a backgrounded `wine tool.exe > out.txt &` would break
# the shell's line editing until it exited. Wine's laziness there looks
# deliberate.
p = need('programs/cmd/wcmdmain.c')
s = read(p)

if 'prime the input path' not in s:
    s = rep(s,
        r'''        SetConsoleMode(hIn, oldmode & ~ENABLE_LINE_INPUT);
        FlushConsoleInputBuffer(hIn);
        while (return_code == ERROR_SIGNAL_PENDING)
''',
        r'''        SetConsoleMode(hIn, oldmode & ~ENABLE_LINE_INPUT);
        FlushConsoleInputBuffer(hIn);
        /* On a Wine unix console, prime the input path before waiting: the
         * console input object cannot become signaled until conhost's tty
         * reader thread is running, and that thread is only started by a read
         * or peek ioctl. has_pending_char_events() issues
         * GetNumberOfConsoleInputEvents(), which is enough to start it.
         * Without this, WaitForMultipleObjects() below never returns.
         * Assigned rather than returned so the mode restore still runs. */
        if (has_pending_char_events(hIn))
            return_code = NO_ERROR;
        while (return_code == ERROR_SIGNAL_PENDING)
''',
        "prime the input path before the wait in WCMD_wait_for_input()")
    write(p, s)

if changed:
    sys.stderr.write("  patched: %s\n" % ", ".join(sorted(set(changed))))
else:
    sys.stderr.write("  all edits already present\n")
PYEOF
  ok "wine sources patched"
}

wine_configure_args() {
  local args=(
    --prefix="$WINE_INSTALL"
    --build=x86_64-apple-darwin
    --host=x86_64-apple-darwin
    --enable-archs=i386,x86_64
    --disable-tests
    --disable-winebth_sys

    --with-mingw="$MINGW_DIR/bin/clang"

    # Enabled, backed by libraries we bundle
    --with-freetype
    --with-gnutls
    --with-sdl
    --with-vulkan
    --with-ffmpeg
    --with-gstreamer

    # Enabled, backed by macOS system frameworks / SDK libraries
    --with-coreaudio
    --with-cups
    --with-opencl
    --with-pcap
    --with-pcsclite
    --with-pthread
    --with-gettext

    # Not applicable on macOS, or would add dependencies without benefit
    --without-alsa
    --without-capi
    --without-dbus
    --without-gettextpo
    --without-gphoto
    --without-gssapi
    --without-inotify
    --without-krb5
    --without-netapi
    --without-oss
    --without-pulse
    --without-sane
    --without-udev
    --without-usb
    --without-v4l2
    --without-wayland
    --without-x
  )

  # Wine 10.17 onwards drives OpenGL through EGL, which macOS does not provide.
  # Direct3D therefore runs on wined3d's Vulkan backend (or DXVK) over MoltenVK.
  # Set WINE_OPENGL=on only if you have supplied an EGL implementation.
  if [[ "$WINE_OPENGL" == "on" ]]; then
    args+=(--with-opengl)
  else
    args+=(--without-opengl)
  fi

  printf '%s\n' "${args[@]}"
}

wine_build() {
  local src bdir log
  # The tree is fetched, extracted and patched by wine_prepare(), which runs
  # outside once() so the patch state is checked on every build -- not just the
  # first one.
  src="$WINE_SRC"
  [[ -n "$src" && -d "$src" ]] || die "wine_build called before wine_prepare"
  log="$(start_log "wine.log")"
  bdir="$BUILD/obj/wine"
  rm -rf "$bdir" "$WINE_INSTALL"
  mkdir -p "$bdir" "$WINE_INSTALL"

  local -a cfg
  while IFS= read -r line; do cfg+=("$line"); done < <(wine_configure_args)

  # rpaths are baked in at link time so the install tree already resolves its
  # bundled dylibs without DYLD_* variables:
  #   bin/wine                -> ../lib
  #   lib/wine/x86_64-unix/*  -> ../..
  # The absolute rpath is required at BUILD time, not run time: Wine compiles
  # host tools such as tools/sfnt2fon and then executes them to generate the
  # bitmap fonts.  Those tools link against our freetype, whose install name is
  # @rpath/libfreetype.6.dylib, and no @loader_path-relative rpath resolves from
  # inside the build tree.  bundle_relocate() deletes every absolute rpath when
  # assembling wine.app, and verify-bundle.sh fails the build if one survives.
  local wine_ldflags="$LDFLAGS -Wl,-rpath,@loader_path/../lib -Wl,-rpath,@loader_path/../.. -Wl,-rpath,@executable_path/../lib -Wl,-rpath,${ARCH_PREFIX}/lib"

  # compiler-rt builtins.
  #
  # ntdll/unix/sync.c gates macOS 14.4's os_sync_wait_on_address behind
  # __builtin_available(), which clang lowers to a call to
  # ___isPlatformVersionAtLeast in libclang_rt.osx.a.  Wine links its Unix-side
  # .so modules with -nodefaultlibs, so clang never adds that archive and ntdll
  # fails with an undefined symbol.
  #
  # This is caused by the macOS 11 target itself: build against 14.4 or newer
  # and clang folds the check to a constant, emitting no call at all.  Since a
  # low deployment target is the entire point here, link the archive explicitly.
  local clang_rt
  clang_rt="$(clang -print-file-name=libclang_rt.osx.a 2>/dev/null || true)"
  [[ -f "$clang_rt" ]] || clang_rt="$(clang -print-runtime-dir 2>/dev/null || true)/libclang_rt.osx.a"
  if [[ -f "$clang_rt" ]]; then
    wine_ldflags="$wine_ldflags $clang_rt"
    ok "compiler-rt builtins: $clang_rt"
  else
    warn "libclang_rt.osx.a not found; ntdll will fail on ___isPlatformVersionAtLeast"
  fi

  # Wine's Cocoa driver reaches newer AppKit through runtime capability checks
  # rather than @available -- see cocoa_app.m, where the notification observer
  # for yieldActivationToApplication: is only registered if
  # [NSApplication instancesRespondToSelector:] says the selector exists.  That
  # is correct and macOS 11-safe, but clang cannot see through it, so
  # -Werror=unguarded-availability-new rejects the file.
  #
  # Demote it to a warning for Wine only.  wine_report_availability() below then
  # lists every occurrence, so this stays visible rather than becoming a blanket
  # exemption nobody ever looks at again.
  local wine_cflags="$CFLAGS -Wno-error=unguarded-availability-new"

  # Export the PE toolchain path for the whole subshell rather than prefixing
  # individual commands.  `make install` is not merely a copy step -- it still
  # runs winebuild to generate import libraries, and winebuild shells out to
  # dlltool.  Prefixing only configure and make left install without it.
  ( cd "$bdir" \
    && export PATH="$MINGW_DIR/bin:$PATH" \
    && CFLAGS="$wine_cflags" \
       LDFLAGS="$wine_ldflags" \
       "$src/configure" "${cfg[@]}" \
    && make -j"$(nproc_count)" \
    && make install \
  ) >> "$log" 2>&1 \
    || die "wine build failed -- see $log"

  [[ -x "$WINE_INSTALL/bin/wine" ]] || die "wine loader was not installed"
  wine_report_availability "$log"
}

# List every API Wine uses that postdates our deployment target.
#
# Each one is a place where the binary weak-links a symbol that does not exist
# on macOS 11, so it is only safe if Wine checks for it at runtime.  As of
# wine 11.0 the hits are in winemac.drv and are all gated by
# -instancesRespondToSelector:.  If this list ever grows, the new entries want
# checking against the source before the build is trusted on Big Sur.
wine_report_availability() {
  local log="$1" hits
  [[ -f "$log" ]] || return 0
  # Match warning: and error: alike -- the same diagnostic prints as one or the
  # other depending on whether -Werror= is in force.
  hits="$(grep -oE '[^ /]+\.[cm]:[0-9]+:[0-9]+: (warning|error): .+ is only available on macOS [0-9.]+ or newer' "$log" \
          | sort -u)"
  [[ -z "$hits" ]] && { ok "no uses of APIs newer than macOS ${DEPLOYMENT_TARGET}"; return 0; }

  warn "Wine uses $(printf '%s\n' "$hits" | wc -l | tr -d ' ') API(s) newer than macOS ${DEPLOYMENT_TARGET}:"
  printf '%s\n' "$hits" | sed 's/^/      /' >&2
  warn "These are weak-linked; they are safe only because Wine guards them with"
  warn "runtime -instancesRespondToSelector: checks that clang cannot see."
}

# Report which optional features configure actually accepted.  Wine prints a
# "libraries not found" notice at the end of configure; a silent miss there is
# the classic way to end up with a bundle that cannot play video or do TLS.
wine_report_features() {
  local cfglog="$BUILD/obj/wine/config.log"
  [[ -f "$cfglog" ]] || return 0
  local missing
  missing="$(sed -n '/libraries.*not found/,/^$/p' "$LOGDIR/wine.log" | head -40)"
  if [[ -n "$missing" ]]; then
    warn "Wine's configure reported missing optional libraries:"
    printf '%s\n' "$missing" | sed 's/^/      /'
  fi

  local f
  for f in winegstreamer winedmo winevulkan; do
    if [[ -f "$WINE_INSTALL/lib/wine/x86_64-unix/${f}.so" \
       || -f "$WINE_INSTALL/lib/wine/x86_64-windows/${f}.dll" ]]; then
      ok "$f built"
    else
      warn "$f is MISSING -- the corresponding feature will not work"
    fi
  done
}

# --------------------------------------------------------------------------
# Gecko and Mono
#
# Wine looks for these MSIs in $WINEDATADIR/<subdir>/ before it tries to
# download them (dlls/appwiz.cpl/addons.c).  Staging them into share/wine means
# every new prefix installs them offline, which is what "works out of the box
# on a fresh macOS install" requires.  Both gecko architectures are needed: a
# 64-bit prefix installs the x86 MSI for its WoW64 side as well.
# --------------------------------------------------------------------------
wine_stage_addons() {
  local gdir="$WINE_INSTALL/share/wine/gecko"
  local mdir="$WINE_INSTALL/share/wine/mono"
  mkdir -p "$gdir" "$mdir"

  local f
  for f in "wine-gecko-${GECKO_VERSION}-x86.msi" "wine-gecko-${GECKO_VERSION}-x86_64.msi"; do
    cp -p "$(fetch "${GECKO_BASE}/${f}")" "$gdir/$f"
  done
  f="wine-mono-${MONO_VERSION}-x86.msi"
  cp -p "$(fetch "${MONO_BASE}/${f}")" "$mdir/$f"

  ok "staged gecko ${GECKO_VERSION} (x86 + x86_64) and mono ${MONO_VERSION}"
}

build_wine() {
  set_arch x86_64
  step "Stage 4: Wine ${WINE_VERSION}"
  wine_prepare
  once "wine-${WINE_VERSION}" wine_build
  once "wine-addons-${WINE_VERSION}" wine_stage_addons
  wine_report_features
  ok "wine tree installed at $WINE_INSTALL"
}
