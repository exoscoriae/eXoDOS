#!/usr/bin/env python3
"""
DOSBox Gunstick macOS Build Fix Script (current-macOS edition)
==============================================================
Prepares a dosbox-gunstick (DOSBox 0.74-3 + lightgun patches) source
directory for a universal (arm64 + x86_64) macOS 11+ build against the
local deps-prefix, then runs autogen.sh and configure.

No Homebrew, no MacPorts. Requires dynrec_apple_silicon.py alongside
(copied in by build_all_gridc_gunstick.sh).

Apple Silicon dynamic core
--------------------------
The 0.74-3 base predates the ARMv8 dynrec backend, so on arm64 there was
NOTHING to run — that alone made the dynamic core "not work" on Apple
Silicon. Its dynrec framework is, however, interface-identical to the
SVN-era one (verified: risc_x64.h function signatures match GridC/ECE
exactly), so this script GRAFTS risc_armv8le.h in (the file is pre-placed
by build_all_gridc_gunstick.sh from the GridC/ECE sources) and registers
it in core_dynrec.cpp. On top of that, the proven ECE W^X treatment is
applied (mmap(MAP_JIT), 16 KiB pages, pthread_jit_write_protect_np,
icache flushes) plus the per-arch override in include/dosbox.h.

The x86_64 slice keeps core_dyn_x86 but NOT the x86 assembly FPU — the
0.74-3 asm FPU predates x86_64 (there is no --disable-fpu-x64 here);
the portable C FPU is used everywhere.

Fullscreen lightgun fix
-----------------------
The fork samples the gun position from absolute SDL mouse coordinates:
    Mouse_CursorMoved_GunStick(motion->x, motion->y, sdl.clip.w, sdl.clip.h)
and maps them to emulated pixels as x*swidth/w. In fullscreen the image
is letterboxed at offset (sdl.clip.x, sdl.clip.y) inside the screen
surface, so raw coordinates are shifted right/down of where the player
aims — clicks sample the wrong pixel and the gun misses. Windowed mode
has zero offsets, which is why it worked there. Fixed by passing
clip-relative coordinates and treating shots outside the active image
area (the black bars) as dark pixels (a miss), which also preserves any
shoot-off-screen game mechanics.

Usage (normally invoked by build_all_gridc_gunstick.sh):
    cd dosbox-gunstick
    DEPS_PREFIX=../deps-prefix UNIVERSAL=1 python3 fix_gunstick_build.py
"""

import os
import subprocess
import sys

from dynrec_apple_silicon import (
    patch, patch_re, file_contains,
    patch_dynrec_apple_silicon, make_override, apply_per_arch_override,
)


def resolve_deps_prefix():
    prefix = os.environ.get('DEPS_PREFIX')
    if not prefix:
        parent = os.path.dirname(os.path.abspath(os.getcwd()))
        prefix = os.path.join(parent, 'deps-prefix')
    prefix = os.path.abspath(prefix)
    if not os.path.isdir(os.path.join(prefix, 'lib')):
        print(f"ERROR: dependency prefix not found at {prefix}")
        print("       Run build_deps.sh from the script directory first.")
        sys.exit(1)
    return prefix


def resolve_sdkroot():
    if os.environ.get('SDKROOT'):
        return os.environ['SDKROOT']
    try:
        out = subprocess.check_output(['xcrun', '--show-sdk-path'],
                                      stderr=subprocess.DEVNULL).decode().strip()
        return out or None
    except Exception:
        return None


def build_flags(prefix):
    macos_min = os.environ.get('MACOSX_DEPLOYMENT_TARGET', '11.0')
    universal = os.environ.get('UNIVERSAL', '1') == '1'

    arch_flags = '-arch arm64 -arch x86_64' if universal else ''
    ver_flag = f'-mmacosx-version-min={macos_min}'
    c_compat = ('-Wno-error=implicit-function-declaration '
                '-Wno-implicit-function-declaration -Wno-implicit-int')

    cppflags = f'-I{prefix}/include {ver_flag}'
    cflags   = f'{arch_flags} {ver_flag} -O2 {c_compat} -I{prefix}/include'
    # 0.74-3 is old C++; gnu++14 keeps legacy constructs (register, etc.)
    # valid under current clang while allowing nothing it doesn't use.
    cxxflags = f'{arch_flags} {ver_flag} -O2 -std=gnu++14 -I{prefix}/include'
    ldflags  = (f'{arch_flags} {ver_flag} -L{prefix}/lib '
                f'-Wl,-rpath,{prefix}/lib '
                f'-Wl,-rpath,@executable_path/../Frameworks')

    env = {
        'CPPFLAGS':          cppflags.strip(),
        'CFLAGS':            cflags.strip(),
        'CXXFLAGS':          cxxflags.strip(),
        'LDFLAGS':           ldflags.strip(),
        'PKG_CONFIG_LIBDIR': os.pathsep.join([f'{prefix}/lib/pkgconfig',
                                              f'{prefix}/share/pkgconfig']),
        'DYLD_FALLBACK_LIBRARY_PATH': f'{prefix}/lib',
        'MACOSX_DEPLOYMENT_TARGET': macos_min,
    }
    sdk = resolve_sdkroot()
    if sdk:
        env['SDKROOT'] = sdk
    return env, macos_min, universal


BOOTSTRAP = ('autogen.sh', 'configure', 'config.sub', 'config.guess',
             'install-sh', 'mkinstalldirs', 'missing', 'depcomp',
             'compile', 'ltmain.sh')


def chmod_execs():
    for fname in BOOTSTRAP:
        if os.path.exists(fname):
            try:
                st = os.stat(fname).st_mode
                os.chmod(fname, st | 0o755)
            except OSError:
                pass


def graft_armv8_backend():
    """Register the SVN-era ARMv8 dynrec backend in the 0.74-3 core.

    risc_armv8le.h itself must already be at src/cpu/core_dynrec/ —
    build_all_gridc_gunstick.sh copies it from the GridC (or ECE) source
    before invoking this script. The backend interface is identical
    between 0.74-3 and SVN r4300 (verified via risc_x64.h signatures)."""
    risc = 'src/cpu/core_dynrec/risc_armv8le.h'
    core = 'src/cpu/core_dynrec.cpp'

    if not os.path.exists(risc):
        print(f"  FAIL: {risc} is missing.")
        print("        build_all_gridc_gunstick.sh pre-places it from the")
        print("        GridC or ECE sources — run the build via that script,")
        print("        or copy the file in manually.")
        sys.exit(1)
    print(f"  OK:   {risc} present")

    # (a) numeric token for the C_TARGETCPU comparison
    if not file_contains(core, 'define ARMV8LE'):
        patch_re(
            core,
            r'(#define\s+POWERPC\s+0x04\n)',
            r'\1#define ARMV8LE\t\t0x07\n',
            'Add ARMV8LE target cpu token',
            required=True
        )

    # (b) backend include chain
    if not file_contains(core, 'risc_armv8le.h'):
        patch(
            core,
            '#include "core_dynrec/risc_armv4le.h"',
            '#include "core_dynrec/risc_armv4le.h"\n'
            '#elif C_TARGETCPU == ARMV8LE\n'
            '#include "core_dynrec/risc_armv8le.h"',
            'Register the ARMv8 backend in the include chain',
            required=True
        )


def patch_lightgun_fullscreen():
    """Make mouse clicks fire the lightgun correctly in fullscreen."""
    sdlmain = 'src/gui/sdlmain.cpp'
    mouse = 'src/ints/mouse.cpp'

    # (a) pass clip-relative coordinates (fullscreen letterbox offsets)
    if not file_contains(sdlmain, 'GunStick(motion->x - sdl.clip.x'):
        patch(
            sdlmain,
            'Mouse_CursorMoved_GunStick(motion->x, motion->y, '
            'sdl.clip.w, sdl.clip.h);',
            '/* Fullscreen fix: the drawn image is letterboxed at\n'
            '\t   (sdl.clip.x, sdl.clip.y) inside the surface; the gun must\n'
            '\t   sample in image-relative coordinates or fullscreen shots\n'
            '\t   land right/down of the aim point. */\n'
            '\tMouse_CursorMoved_GunStick(motion->x - sdl.clip.x, '
            'motion->y - sdl.clip.y, sdl.clip.w, sdl.clip.h);',
            'Lightgun: subtract fullscreen letterbox offsets',
            required=True
        )

    # (b) shots outside the active image area read as dark (a miss)
    if not file_contains(mouse, 'sdlx >= sdlw || sdly >= sdlh'):
        ok = patch(
            mouse,
            '    if(!sdlw || !sdlh)\n'
            '        return 0;\n'
            '\n'
            '    x = sdlx * CurMode->swidth / sdlw;',
            '    if(!sdlw || !sdlh)\n'
            '        return 0;\n'
            '\n'
            '    /* Fullscreen letterbox fix: coordinates outside the active\n'
            '       image (the black bars) cannot hit anything — read as dark. */\n'
            '    if(sdlx < 0 || sdly < 0 || sdlx >= sdlw || sdly >= sdlh)\n'
            '        return 0;\n'
            '\n'
            '    x = sdlx * CurMode->swidth / sdlw;',
            'Lightgun: treat out-of-image shots as dark pixels'
        )
        if not ok:
            patch_re(
                mouse,
                r'(if\s*\(\s*!sdlw\s*\|\|\s*!sdlh\s*\)\s*\n\s*return 0;\s*\n)',
                r'\1\n'
                r'    if(sdlx < 0 || sdly < 0 || sdlx >= sdlw || sdly >= sdlh)\n'
                r'        return 0;\n',
                'Lightgun: treat out-of-image shots as dark pixels (regex)',
                required=True
            )


def main():
    if not os.path.exists('configure.ac') or not os.path.exists('src'):
        print("ERROR: run this script from a dosbox-gunstick source directory")
        sys.exit(1)

    prefix = resolve_deps_prefix()
    env_updates, macos_min, universal = build_flags(prefix)

    print("=== DOSBox Gunstick macOS Build Fix ===")
    print(f"  Source directory:  {os.getcwd()}")
    print(f"  Deps prefix:       {prefix}")
    print(f"  Target macOS:      {macos_min}")
    print(f"  Universal build:   {'yes (arm64 + x86_64)' if universal else 'no'}")
    print()

    print("[1/5] Renaming VERSION file (case-insensitive FS <version> clash)...")
    if os.path.exists('VERSION') and not os.path.exists('VERSION.txt'):
        os.rename('VERSION', 'VERSION.txt')
        print("  DONE: VERSION -> VERSION.txt")
    else:
        print("  SKIP: no VERSION file / already renamed")
    print()

    print("[2/5] Grafting the ARMv8 dynrec backend (0.74-3 predates it)...")
    graft_armv8_backend()
    print()

    print("[3/5] Fixing fullscreen lightgun coordinate mapping...")
    patch_lightgun_fullscreen()
    print()

    print("[4/5] Patching core_dynrec for Apple Silicon (W^X, MAP_JIT, 16K pages)...")
    patch_dynrec_apple_silicon()
    print()

    # ── Environment: sanitized + our flags ──────────────────────────────────
    env = os.environ.copy()
    env.update(env_updates)
    for var in (
        'PKG_CONFIG_PATH',
        'CPATH', 'C_INCLUDE_PATH', 'CPLUS_INCLUDE_PATH',
        'OBJC_INCLUDE_PATH', 'OBJCPLUS_INCLUDE_PATH',
        'LIBRARY_PATH', 'DYLD_LIBRARY_PATH',
        'CMAKE_PREFIX_PATH', 'CMAKE_FRAMEWORK_PATH',
    ):
        env.pop(var, None)
    env['PATH'] = prefix + os.sep + 'bin' + os.pathsep + env.get('PATH', '')

    needs_autogen = (
        not os.path.exists('configure') or
        os.path.getmtime('configure.ac') > os.path.getmtime('configure')
    )
    if needs_autogen:
        print("[*] Running ./autogen.sh ...")
        chmod_execs()
        if subprocess.run(['sh', './autogen.sh'], env=env).returncode != 0:
            print("\nERROR: autogen.sh failed. Run ./bootstrap_tools.sh first.")
            sys.exit(1)
        print()
    else:
        print("[*] configure is up to date, skipping autogen.sh")

    print(f"[*] Running ./configure (universal, macOS-min={macos_min})...")
    chmod_execs()

    configure_args = [
        './configure',
        f'--with-sdl-prefix={prefix}',
        f'CPPFLAGS={env_updates["CPPFLAGS"]}',
        f'CFLAGS={env_updates["CFLAGS"]}',
        f'CXXFLAGS={env_updates["CXXFLAGS"]}',
        f'LDFLAGS={env_updates["LDFLAGS"]}',
    ]
    if os.path.exists(os.path.join(prefix, 'bin', 'sdl-config')):
        configure_args.insert(1, f'--with-sdl-exec-prefix={prefix}')

    # Definitive per-arch core selection happens in the post-configure
    # override; these flags keep configure itself universal-safe.
    # (No --disable-fpu-x64: that option doesn't exist in 0.74-3.)
    for opt in (
        '--enable-core-inline',
        '--enable-dynamic-core',
        '--disable-dynamic-x86',
        '--enable-dynrec',
        '--enable-fpu',
        '--disable-fpu-x86',
        '--enable-opengl',
    ):
        configure_args.append(opt)

    rc = subprocess.run(configure_args, env=env).returncode
    if rc != 0:
        print("\nERROR: configure failed.")
        sys.exit(1)

    print()
    print("[5/5] Installing per-architecture dynamic core overrides"
          " (include/dosbox.h + config.h)...")
    # dyn_x86=False: 0.74-3's core_dyn_x86.cpp unconditionally includes the
    # 32-bit-only risc_x86.h — the x86_64 slice uses core_dynrec (risc_x64).
    # fpu_x86=False: the 0.74-3 x86 asm FPU also predates x86_64.
    apply_per_arch_override(make_override(dyn_x86=False, fpu_x86=False))

    print()
    print("=" * 60)
    print("Patches applied and configure succeeded.")
    print("Now run: make -j$(sysctl -n hw.logicalcpu)")
    print("=" * 60)


if __name__ == '__main__':
    main()
