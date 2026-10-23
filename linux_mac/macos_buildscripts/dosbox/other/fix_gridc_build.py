#!/usr/bin/env python3
"""
DOSBox GridC macOS Build Fix Script (current-macOS edition)
===========================================================
Prepares a dosbox-gridc (GC-v4.3.1, hiddenasbestos fork of DOSBox SVN
r4300) source directory for a universal (arm64 + x86_64) macOS 11+ build
against the local deps-prefix, then runs autogen.sh and configure.

No Homebrew, no MacPorts. Requires dynrec_apple_silicon.py alongside
(copied in by build_all_gridc_gunstick.sh).

GridC is the same SVN vintage as ECE r4301, so the entire proven ECE
Apple Silicon dynamic-core treatment applies unchanged:
  * configure.ac taught that host_cpu `arm64` == `aarch64`
  * cache.h W^X patches: mmap(MAP_JIT) allocation, 16 KiB PAGESIZE_TEMP,
    pthread_jit_write_protect_np() toggles, sys_icache_invalidate flushes
  * per-arch override injected into include/dosbox.h: BOTH slices get
    core_dynrec (risc_x64 on x86_64, risc_armv8le on arm64) — this base's
    core_dyn_x86 is 32-bit-only, unlike ECE's

Usage (normally invoked by build_all_gridc_gunstick.sh):
    cd dosbox-gridc-4-3-1
    DEPS_PREFIX=../deps-prefix UNIVERSAL=1 python3 fix_gridc_build.py
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
    # gnu++14: same sweet spot as the ECE SVN-era sources (gamelink uses
    # std::unique_ptr, but newer dialects break legacy constructs).
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
    # GitHub tarballs strip the execute bit from shell scripts.
    for fname in BOOTSTRAP:
        if os.path.exists(fname):
            try:
                st = os.stat(fname).st_mode
                os.chmod(fname, st | 0o755)
            except OSError:
                pass


def main():
    if not os.path.exists('configure.ac') or not os.path.exists('src'):
        print("ERROR: run this script from a dosbox-gridc source directory")
        sys.exit(1)

    prefix = resolve_deps_prefix()
    env_updates, macos_min, universal = build_flags(prefix)

    print("=== DOSBox GridC macOS Build Fix ===")
    print(f"  Source directory:  {os.getcwd()}")
    print(f"  Deps prefix:       {prefix}")
    print(f"  Target macOS:      {macos_min}")
    print(f"  Universal build:   {'yes (arm64 + x86_64)' if universal else 'no'}")
    print()

    print("[1/4] Renaming VERSION file (case-insensitive FS <version> clash)...")
    if os.path.exists('VERSION') and not os.path.exists('VERSION.txt'):
        os.rename('VERSION', 'VERSION.txt')
        print("  DONE: VERSION -> VERSION.txt")
    else:
        print("  SKIP: no VERSION file / already renamed")
    print()

    print("[2/4] Patching configure.ac (arm64 host detection)...")
    if file_contains('configure.ac', 'aarch64 | arm64'):
        print("  SKIP  already patched")
    else:
        patch(
            'configure.ac',
            '   aarch64)\n    AC_DEFINE(C_TARGETCPU,ARMV8LE)',
            '   aarch64 | arm64)\n    AC_DEFINE(C_TARGETCPU,ARMV8LE)',
            'Match arm64 (macOS name for aarch64) in the target cpu case'
        ) or patch_re(
            'configure.ac',
            r'^(\s*)aarch64\)',
            r'\1aarch64 | arm64)',
            'Match arm64 in the target cpu case (regex)'
        )
    print()

    print("[3/4] Patching core_dynrec for Apple Silicon (W^X, MAP_JIT, 16K pages)...")
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
    for opt in (
        '--enable-core-inline',
        '--enable-dynamic-core',
        '--disable-dynamic-x86',
        '--enable-dynrec',
        '--enable-fpu',
        '--disable-fpu-x64',
        '--disable-fpu-x86',
        # GridC-specific opt-ins:
        '--enable-opengl',
        '--enable-gamelink',
    ):
        configure_args.append(opt)

    rc = subprocess.run(configure_args, env=env).returncode
    if rc != 0:
        print("\nERROR: configure failed.")
        sys.exit(1)

    print()
    print("[4/4] Installing per-architecture dynamic core overrides"
          " (include/dosbox.h + config.h)...")
    # dyn_x86=False: GridC's core_dyn_x86.cpp unconditionally includes the
    # 32-bit-only risc_x86.h (no x64 dyn_x86 backend in this base, unlike
    # ECE), so the x86_64 slice uses core_dynrec with risc_x64 instead.
    apply_per_arch_override(make_override(dyn_x86=False, fpu_x86=False))

    print()
    print("=" * 60)
    print("Patches applied and configure succeeded.")
    print("Now run: make -j$(sysctl -n hw.logicalcpu)")
    print("=" * 60)


if __name__ == '__main__':
    main()
