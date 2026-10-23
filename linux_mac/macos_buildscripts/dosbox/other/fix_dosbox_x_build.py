#!/usr/bin/env python3
"""
DOSBox-X macOS Build Fix Script (current-macOS edition)
=======================================================
Prepares a dosbox-x source directory (v2024.07.01 / v2024.10.01 /
v2025.02.01 / v2025.05.03) for a universal (arm64 + x86_64) macOS 11+
build against the local deps-prefix, then runs autogen.sh and configure.

No Homebrew, no MacPorts: libraries come from deps-prefix (build_deps.sh),
build tools from tools-prefix (bootstrap_tools.sh).

Dynamic core on Apple Silicon
-----------------------------
All four DOSBox-X versions already ship a W^X-safe dyncore allocator
(src/cpu/dynamic_alloc_common.h): on Darwin it dual-maps the code cache
via mach_vm_remap() (RW view for the recompiler, RX view for execution,
icache flushed via __builtin___clear_cache), so — unlike DOSBox ECE — no
cache-level W^X/MAP_JIT patching is needed, and PAGESIZE comes from the
per-slice SDK headers (16384 on arm64, 4096 on x86_64) so kernel page
size is automatically right.

What CAN break the dynamic core in a universal build is configure:
  * it runs once on the arm64 host, so a single shared config.h decides
    C_TARGETCPU for BOTH slices (and historically could end up UNKNOWN,
    silently disabling every dynamic core — the exact ECE failure mode);
  * the C_HAVE_MMAP / C_HAVE_MPROTECT / C_HAVE_MACH_VM_REMAP feature
    probes gate the Darwin dual-mapping path.
This script therefore injects a per-architecture override block into
include/dosbox.h (right after '#include "config.h"'), re-deriving
C_TARGETCPU / C_DYNREC from the compiler's own target macros per slice
and force-enabling the Darwin feature macros (all present on macOS 11+).
It survives any config.h regeneration. A copy is also appended to
config.h as belt-and-braces.

Usage (normally invoked by build_all_dosboxx.sh):
    cd dosbox-x-v2025.05.03
    DEPS_PREFIX=../deps-prefix UNIVERSAL=1 python3 fix_dosbox_x_build.py
"""

import os
import re
import sys
import shutil
import subprocess


# ──────────────────────────────────────────────────────────────────────────────
# Patch helpers (same semantics as fix_macos_build.py)
# ──────────────────────────────────────────────────────────────────────────────

def patch(filename, old, new, description, required=False):
    """Apply an exact-string replacement patch to a file. Idempotent."""
    if not os.path.exists(filename):
        print(f"  SKIP  (not found):         {filename} — {description}")
        return False
    with open(filename, 'r', encoding='utf-8', errors='replace') as f:
        content = f.read()
    if old not in content:
        if new in content:
            print(f"  SKIP  (already applied):   {filename} — {description}")
            return False
        if required:
            print(f"  FAIL  (pattern not found): {filename} — {description}")
            sys.exit(1)
        print(f"  WARN  (pattern not found): {filename} — {description}")
        return False
    content = content.replace(old, new, 1)
    with open(filename, 'w', encoding='utf-8') as f:
        f.write(content)
    print(f"  PATCH (applied):           {filename} — {description}")
    return True


def file_contains(filename, needle):
    if not os.path.exists(filename):
        return False
    with open(filename, 'r', encoding='utf-8', errors='replace') as f:
        return needle in f.read()


# ──────────────────────────────────────────────────────────────────────────────
# Environment helpers
# ──────────────────────────────────────────────────────────────────────────────

def resolve_deps_prefix():
    prefix = os.environ.get('DEPS_PREFIX')
    if not prefix:
        parent = os.path.dirname(os.path.abspath(os.getcwd()))
        prefix = os.path.join(parent, 'deps-prefix')
    prefix = os.path.abspath(prefix)
    if not os.path.isdir(os.path.join(prefix, 'lib')):
        print(f"ERROR: dependency prefix not found at {prefix}")
        print("       Run build_deps.sh --all from the script directory first,")
        print("       or set DEPS_PREFIX to an alternate location.")
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


def detect_version():
    """Parse the DOSBox-X version out of configure.ac (AC_INIT line)."""
    try:
        with open('configure.ac', encoding='utf-8', errors='replace') as f:
            for line in f:
                m = re.match(r'\s*AC_INIT\s*\(\s*\[?dosbox-x\]?\s*,\s*\[?([^\],)]+)\]?', line)
                if m:
                    return m.group(1).strip()
    except OSError:
        pass
    return 'unknown'


def internal_dep_dir():
    if os.path.isdir('vs'):
        return 'vs'
    if os.path.isdir('vs2015'):
        return 'vs2015'
    return None


def chmod_execs(files):
    for fname in files:
        if os.path.exists(fname):
            try:
                st = os.stat(fname).st_mode
                os.chmod(fname, st | 0o755)
            except OSError:
                pass


def build_flags(prefix):
    macos_min = os.environ.get('MACOSX_DEPLOYMENT_TARGET', '11.0')
    universal = os.environ.get('UNIVERSAL', '1') == '1'

    arch_flags = '-arch arm64 -arch x86_64' if universal else ''
    ver_flag = f'-mmacosx-version-min={macos_min}'

    # Recent clang (Xcode 15+) hard-errors on implicit declarations; keep the
    # older C in the tree compiling.
    c_compat = ('-Wno-error=implicit-function-declaration '
                '-Wno-implicit-function-declaration -Wno-implicit-int')

    cppflags = f'-I{prefix}/include {ver_flag}'
    cflags   = f'{arch_flags} {ver_flag} -O2 {c_compat} -I{prefix}/include'
    # NOTE: no -std= override. DOSBox-X is actively maintained against
    # current Xcode/clang; let its configure and the compiler default decide
    # (forcing gnu++14 was only right for the old macOS 12 VM toolchain).
    cxxflags = f'{arch_flags} {ver_flag} -O2 -I{prefix}/include'
    ldflags  = (f'{arch_flags} {ver_flag} -L{prefix}/lib '
                f'-Wl,-rpath,{prefix}/lib '
                f'-Wl,-rpath,@executable_path/../Frameworks')

    pkgconfig_libdir = os.pathsep.join([
        f'{prefix}/lib/pkgconfig',
        f'{prefix}/share/pkgconfig',
    ])

    env = {
        'CPPFLAGS':          cppflags.strip(),
        'CFLAGS':            cflags.strip(),
        'CXXFLAGS':          cxxflags.strip(),
        'OBJCFLAGS':         cflags.strip(),
        'OBJCXXFLAGS':       cxxflags.strip(),
        'LDFLAGS':           ldflags.strip(),
        'PKG_CONFIG_LIBDIR': pkgconfig_libdir,
        'DYLD_FALLBACK_LIBRARY_PATH': f'{prefix}/lib',
        'MACOSX_DEPLOYMENT_TARGET': macos_min,
    }
    sdk = resolve_sdkroot()
    if sdk:
        env['SDKROOT'] = sdk
    return env, macos_min, universal


# ──────────────────────────────────────────────────────────────────────────────
# Per-architecture dynamic core override
# ──────────────────────────────────────────────────────────────────────────────

CONFIG_H_OVERRIDE = """
/* ---- per-architecture dynamic core selection (fix_dosbox_x_build.py) -------
 * A universal (arm64 + x86_64) build shares one config.h between both
 * slices, but configure runs only once (on the arm64 host) and cannot get
 * CPU-specific settings right for both. Re-derive them from the compiler's
 * target macros, which are always correct per slice.
 *
 * Both slices use the portable recompiler (core_dynrec):
 *   x86_64 slice -> risc_x64 backend
 *   arm64  slice -> risc_armv8le backend
 * The x86-only dyn_x86 core and x86 assembly FPU stay off (same choice as
 * upstream DOSBox-X macOS builds). */
#undef C_DYNAMIC_X86
#undef C_DYNREC
#undef C_TARGETCPU
#undef C_UNALIGNED_MEMORY
#undef C_FPU_X86
#if defined(__x86_64__)
#define C_TARGETCPU X86_64
#define C_DYNREC 1
#define C_UNALIGNED_MEMORY 1
#elif defined(__aarch64__)
#define C_TARGETCPU ARMV8LE
#define C_DYNREC 1
#define C_UNALIGNED_MEMORY 1
#endif
/* DOSBox-X's dyncore allocator (src/cpu/dynamic_alloc_common.h) has a
 * Darwin dual-mapping path (mach_vm_remap: RW view for the recompiler,
 * RX view for execution) — the W^X-safe way to JIT on Apple Silicon.
 * Force-enable the feature macros that gate it; mmap/mprotect/
 * mach_vm_remap all exist on every macOS >= 11, so this only guards
 * against a configure probe failing in an isolated environment. */
#if defined(__APPLE__)
#ifndef C_HAVE_MMAP
#define C_HAVE_MMAP 1
#endif
#ifndef C_HAVE_MPROTECT
#define C_HAVE_MPROTECT 1
#endif
#ifndef C_HAVE_MACH_VM_REMAP
#define C_HAVE_MACH_VM_REMAP 1
#endif
#endif
/* ---- end per-architecture overrides ---------------------------------------- */
"""


def apply_per_arch_override():
    """Install the override in include/dosbox.h (primary) and config.h
    (secondary). The dosbox.h copy survives config.h regeneration by
    automake's remake rules — the failure mode that silently disabled
    every dynamic core in the ECE builds."""
    dosbox_h = os.path.join('include', 'dosbox.h')
    if file_contains(dosbox_h, 'per-architecture dynamic core selection'):
        print("  SKIP  include/dosbox.h override already present")
    else:
        ok = patch(
            dosbox_h,
            '#include "config.h"',
            '#include "config.h"\n' + CONFIG_H_OVERRIDE,
            'Inject per-arch core override (survives config.h regeneration)'
        )
        if not ok:
            print("  WARN  could not inject into include/dosbox.h — relying on")
            print("        the config.h copy only")

    if not os.path.exists('config.h'):
        print("ERROR: config.h not found after configure — cannot apply the")
        print("       per-architecture dynamic core overrides.")
        sys.exit(1)
    if file_contains('config.h', 'per-architecture dynamic core selection'):
        print("  SKIP  config.h override already present")
    else:
        with open('config.h', 'a', encoding='utf-8') as f:
            f.write(CONFIG_H_OVERRIDE)
        print("  PATCH config.h — appended per-architecture dynamic core overrides")

    if not (file_contains(dosbox_h, 'per-architecture dynamic core selection')
            or file_contains('config.h', 'per-architecture dynamic core selection')):
        print("ERROR: per-arch override could not be installed anywhere.")
        sys.exit(1)


# ──────────────────────────────────────────────────────────────────────────────
# Source patches carried over from the macOS 12 VM script
# ──────────────────────────────────────────────────────────────────────────────

def patch_fpu_control_x86_for_arm64():
    """Arch-guard raw x86 inline asm (fldcw/fnstcw) in
    include/fpu_control_x86.h so the arm64 compile pass of a universal
    build doesn't try to assemble x86 mnemonics. No-op on versions that
    already ship arch guards (v2024.07.01+ generally do)."""
    path = os.path.join('include', 'fpu_control_x86.h')
    if not os.path.isfile(path):
        return False

    with open(path, 'r', encoding='utf-8', errors='replace') as f:
        content = f.read()

    sentinel = '/* DOSBOX_X_ARM64_FPU_PATCH */'
    if sentinel in content:
        return False
    if '__i386__' in content or '__x86_64__' in content or '__arm64__' in content:
        return False

    lines = content.splitlines(keepends=False)
    out = []
    i = 0
    patched = False
    asm_re = re.compile(
        r'^(?P<prefix>\s*#\s*define\s+(?P<name>\w+)\s*\((?P<args>[^)]*)\)\s+)'
        r'(?P<body>.*__asm__.*)$'
    )

    while i < len(lines):
        line = lines[i]
        m = asm_re.match(line)
        if m:
            collected = [line]
            while collected[-1].rstrip().endswith('\\'):
                i += 1
                if i >= len(lines):
                    break
                collected.append(lines[i])

            name = m.group('name')
            args = m.group('args').strip()
            arg_names = [a.strip() for a in args.split(',') if a.strip()]
            if arg_names:
                noop_body = ' '.join(f'((void)({a}))' for a in arg_names)
            else:
                noop_body = '((void)0)'

            out.append('#if defined(__i386__) || defined(__x86_64__)')
            out.extend(collected)
            out.append('#else')
            out.append(f'#define {name}({args}) {noop_body}')
            out.append('#endif')
            patched = True
        else:
            out.append(line)
        i += 1

    if not patched:
        return False

    out.insert(0, sentinel)
    with open(path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(out) + '\n')
    return True


def ensure_sdlnet_stub_paths(top, prefix):
    """configure.ac hardcodes -I$pwd/vs/sdlnet/linux-host/include{,/SDL}
    into CPPFLAGS. Create those directories and symlink our SDL2_net
    header in so the hardcoded -I contributes the right file."""
    vs = internal_dep_dir()
    if not vs:
        return
    base = os.path.join(top, vs, 'sdlnet', 'linux-host')
    inc = os.path.join(base, 'include')
    inc_sdl = os.path.join(inc, 'SDL')
    lib = os.path.join(base, 'lib')
    for d in (inc, inc_sdl, lib):
        os.makedirs(d, exist_ok=True)
    src_hdr = os.path.join(prefix, 'include', 'SDL2', 'SDL_net.h')
    if os.path.isfile(src_hdr):
        for dst in (os.path.join(inc, 'SDL_net.h'),
                    os.path.join(inc_sdl, 'SDL_net.h')):
            if os.path.lexists(dst):
                try:
                    os.unlink(dst)
                except OSError:
                    pass
            try:
                os.symlink(src_hdr, dst)
            except OSError:
                shutil.copy2(src_hdr, dst)


# ──────────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────────

def main():
    if not os.path.exists('configure.ac') or not os.path.exists('src'):
        print("ERROR: run this script from a dosbox-x source directory "
              "(e.g., cd dosbox-x-v2025.05.03)")
        sys.exit(1)

    prefix = resolve_deps_prefix()
    env_updates, macos_min, universal = build_flags(prefix)
    version = detect_version()
    vs_dir = internal_dep_dir()

    print("=== DOSBox-X macOS Build Fix ===")
    print(f"  Source directory:   {os.getcwd()}")
    print(f"  Detected version:   {version}")
    print(f"  Internal dep tree:  {vs_dir or '(none)'}")
    print(f"  Deps prefix:        {prefix}")
    print(f"  Target macOS:       {macos_min}")
    print(f"  Universal build:    {'yes (arm64 + x86_64)' if universal else 'no'}")
    print()

    print("[1/4] Normalizing VERSION file (case-insensitive FS <version> clash)...")
    if os.path.exists('VERSION') and not os.path.exists('VERSION.txt'):
        os.rename('VERSION', 'VERSION.txt')
        print("  DONE: VERSION -> VERSION.txt")
    else:
        print("  SKIP: no VERSION file")
    print()

    print("[2/4] Populating internal SDL_net include stubs...")
    ensure_sdlnet_stub_paths(os.getcwd(), prefix)
    print(f"  DONE: {vs_dir}/sdlnet/linux-host/{{include,lib}} created" if vs_dir
          else "  SKIP: no vs/vs2015 tree in this source")
    print()

    print("[3/4] Arch-guarding x86 FPU inline asm for the arm64 compile pass...")
    if patch_fpu_control_x86_for_arm64():
        print("  DONE: include/fpu_control_x86.h patched")
    else:
        print("  SKIP: header already arch-guarded or not present")
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

    # ── autogen.sh ──────────────────────────────────────────────────────────
    BOOTSTRAP = ('autogen.sh', 'configure', 'config.sub', 'config.guess',
                 'install-sh', 'mkinstalldirs', 'missing', 'depcomp',
                 'compile', 'ltmain.sh')
    needs_autogen = (
        not os.path.exists('configure') or
        os.path.getmtime('configure.ac') > os.path.getmtime('configure')
    )
    if needs_autogen:
        print("[*] Running ./autogen.sh ...")
        chmod_execs(BOOTSTRAP)
        if subprocess.run(['sh', './autogen.sh'], env=env).returncode != 0:
            print("\nERROR: autogen.sh failed.")
            print("  Build the autotools first (no Homebrew/MacPorts needed):")
            print("      ./bootstrap_tools.sh")
            sys.exit(1)
        print()
    else:
        print("[*] configure is up to date, skipping autogen.sh")

    # ── configure ───────────────────────────────────────────────────────────
    print(f"[*] Running ./configure (universal, macOS-min={macos_min}, SDL2)...")
    chmod_execs(BOOTSTRAP)

    configure_args = [
        './configure',
        f'CPPFLAGS={env_updates["CPPFLAGS"]}',
        f'CFLAGS={env_updates["CFLAGS"]}',
        f'CXXFLAGS={env_updates["CXXFLAGS"]}',
        f'OBJCFLAGS={env_updates["OBJCFLAGS"]}',
        f'OBJCXXFLAGS={env_updates["OBJCXXFLAGS"]}',
        f'LDFLAGS={env_updates["LDFLAGS"]}',
        # Definitive per-arch core selection happens in the override that is
        # installed AFTER configure (see CONFIG_H_OVERRIDE). These flags just
        # keep configure itself from enabling something that cannot compile
        # in a universal build:
        #   --disable-dynamic-x86  x86-only Dyn-X core can't build for arm64
        #   --enable-dynrec        portable recompiler; backend per slice
        #   --disable-fpu-x86/x64  asm FPU is arch-specific; portable C FPU
        '--enable-core-inline',
        '--enable-dynamic-core',
        '--disable-dynamic-x86',
        '--enable-dynrec',
        '--enable-fpu',
        '--disable-fpu-x64',
        '--disable-fpu-x86',
        # Feature-maximizing: ffmpeg-backed AVI/MP4 capture (needs the
        # ffmpeg libs from deps-prefix; harmlessly ignored if the flag is
        # unknown to this version's configure).
        '--enable-avcodec',
        # SDL2 from our deps-prefix:
        f'--with-sdl2-prefix={prefix}',
        '--enable-sdl2',
    ]

    rc = subprocess.run(configure_args, env=env).returncode
    if rc != 0:
        print("\nERROR: configure failed.")
        sys.exit(1)

    # ── [4/4] per-arch override, post-configure ─────────────────────────────
    print()
    print("[4/4] Installing per-architecture dynamic core overrides"
          " (include/dosbox.h + config.h)...")
    apply_per_arch_override()

    print()
    print("=" * 60)
    print("Patches applied and configure succeeded.")
    print("Now run: make -j$(sysctl -n hw.logicalcpu)")
    print("=" * 60)


if __name__ == '__main__':
    main()
