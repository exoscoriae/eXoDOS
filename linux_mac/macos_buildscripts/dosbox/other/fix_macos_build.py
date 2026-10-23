#!/usr/bin/env python3
"""
DOSBox ECE macOS Build Fix Script
===================================
Applies all macOS-specific source patches to a single ECE source directory,
then runs autogen.sh and configure.

Designed to run on CURRENT macOS versions (Sequoia/Tahoe and later) on both
Apple Silicon and Intel hosts. No Homebrew, no MacPorts: every library comes
from a local prefix built by build_deps.sh, and every build tool comes from
a local prefix built by bootstrap_tools.sh.

New in this revision (vs. the macOS 12 VM scripts):
  * The dynamic (recompiling) CPU core now WORKS on Apple Silicon:
      - configure.ac is patched so `arm64-apple-darwin` is recognized
        (stock DOSBox only knows `aarch64`, so C_TARGETCPU ended up UNKNOWN
        and every dynamic core was silently disabled).
      - config.h is post-processed with a per-architecture override block, so
        the x86_64 slice of the universal binary gets the classic dynamic
        core (core_dyn_x86) while the arm64 slice gets the portable
        recompiler (core_dynrec) with the ARMv8 backend.
      - core_dynrec is patched for Apple Silicon W^X: the code cache is
        allocated with mmap(MAP_JIT), toggled between writable and
        executable with pthread_jit_write_protect_np(), and the instruction
        cache is invalidated after code generation.
      - PAGESIZE_TEMP is 16384 on Apple Silicon (16 KiB kernel pages; the
        old 4096 value made mprotect fail with EINVAL).

Environment variables (all optional):
    DEPS_PREFIX       Where dependencies are installed (default: ../deps-prefix)
    MACOSX_DEPLOYMENT_TARGET   Minimum macOS version (default: 11.0)
    SDKROOT           Xcode SDK path (auto-detected via xcrun if unset)
    UNIVERSAL         If set to "1", builds universal (arm64 + x86_64)

Usage:
    Copy this script to your ECE source directory, then run:
        python3 fix_macos_build.py
"""

import os
import re
import sys
import subprocess


# ──────────────────────────────────────────────────────────────────────────────
# Patch helpers
# ──────────────────────────────────────────────────────────────────────────────

def patch(filename, old, new, description, required=False):
    """Apply an exact-string replacement patch to a file. Idempotent."""
    if not os.path.exists(filename):
        print(f"  SKIP  (not found):         {filename} — {description}")
        return False
    with open(filename, 'r') as f:
        content = f.read()
    if old not in content:
        if new in content:
            print(f"  SKIP  (already applied):   {filename} — {description}")
            return False
        if required:
            print(f"  FAIL  (pattern not found): {filename} — {description}")
            print( "        This ECE revision differs from the expected DOSBox")
            print( "        SVN source. Inspect the file and adjust the patch.")
            sys.exit(1)
        print(f"  WARN  (pattern not found): {filename} — {description}")
        return False
    idx = content.find(old)
    preceding = content[max(0, idx - 30):idx]
    if '#ifndef __APPLE__' in preceding:
        print(f"  SKIP  (already guarded):   {filename} — {description}")
        return False
    content = content.replace(old, new, 1)
    with open(filename, 'w') as f:
        f.write(content)
    print(f"  PATCH (applied):           {filename} — {description}")
    return True


def patch_re(filename, pattern, replacement, description, required=False):
    """Apply a regex substitution patch to a file. Idempotent via match check."""
    if not os.path.exists(filename):
        print(f"  SKIP  (not found):         {filename} — {description}")
        return False
    with open(filename, 'r') as f:
        content = f.read()
    new_content, count = re.subn(pattern, replacement, content, count=1, flags=re.MULTILINE)
    if count == 0:
        if required:
            print(f"  FAIL  (no match):          {filename} — {description}")
            sys.exit(1)
        print(f"  SKIP  (no match/patched):  {filename} — {description}")
        return False
    with open(filename, 'w') as f:
        f.write(new_content)
    print(f"  PATCH (applied):           {filename} — {description}")
    return True


def file_contains(filename, needle):
    if not os.path.exists(filename):
        return False
    with open(filename, 'r') as f:
        return needle in f.read()


# ──────────────────────────────────────────────────────────────────────────────
# Environment helpers
# ──────────────────────────────────────────────────────────────────────────────

def resolve_deps_prefix():
    """Locate the deps prefix directory. Fail early if missing."""
    prefix = os.environ.get('DEPS_PREFIX')
    if not prefix:
        parent = os.path.dirname(os.path.abspath(os.getcwd()))
        prefix = os.path.join(parent, 'deps-prefix')
    prefix = os.path.abspath(prefix)
    if not os.path.isdir(os.path.join(prefix, 'lib')):
        print(f"ERROR: dependency prefix not found at {prefix}")
        print("       Run build_deps.sh from the script directory first, or")
        print("       set DEPS_PREFIX to an alternate location.")
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
    """Construct universal + minimum-OS build flags."""
    macos_min = os.environ.get('MACOSX_DEPLOYMENT_TARGET', '11.0')
    universal = os.environ.get('UNIVERSAL', '1') == '1'

    arch_flags = ''
    if universal:
        arch_flags = '-arch arm64 -arch x86_64'

    ver_flag = f'-mmacosx-version-min={macos_min}'

    # -Wno-implicit-function-declaration / -Wno-implicit-int: recent clang
    # (Xcode 15+) treats these as hard errors by default, which breaks the
    # old C sources in the bundled codec sub-builds. Downgrade to warnings.
    c_compat = ('-Wno-error=implicit-function-declaration '
                '-Wno-implicit-function-declaration -Wno-implicit-int')

    cppflags = f'-I{prefix}/include {ver_flag}'
    cflags   = f'{arch_flags} {ver_flag} -O2 {c_compat} -I{prefix}/include'
    # ECE sources use C++11/14 features throughout. Newer clang defaults to
    # C++17+, in which some legacy constructs (e.g. `register`) are gone,
    # while very old defaults miss brace-init patterns ECE uses. gnu++14 is
    # the sweet spot for r4301/r4358/r4482.
    cxxflags = f'{arch_flags} {ver_flag} -O2 -std=gnu++14 -I{prefix}/include'
    # Two rpaths:
    #   1. {prefix}/lib — so autoconf AC_TRY_RUN test programs can resolve
    #      @rpath/libSDL-1.2.0.dylib (sdl12-compat) and its SDL2 dependency
    #      at configure time. Stripped when the binary is bundled.
    #   2. @executable_path/../Frameworks — the final .app layout.
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
# Apple Silicon dynamic core (core_dynrec) W^X support
# ──────────────────────────────────────────────────────────────────────────────

JIT_HELPERS = (
    '/* --- Apple Silicon W^X support (added by fix_macos_build.py) -----------\n'
    ' * macOS on arm64 enforces strict W^X: a page can never be writable and\n'
    ' * executable at the same time for the executing thread. JIT code caches\n'
    ' * must be allocated with mmap(MAP_JIT) and toggled between writable and\n'
    ' * executable states with pthread_jit_write_protect_np(). After writing\n'
    ' * code, the instruction cache must be invalidated before executing it.\n'
    ' * On every other platform these helpers compile to nothing. */\n'
    '#if defined(__APPLE__) && defined(__aarch64__)\n'
    '#include <pthread.h>\n'
    '#include <sys/mman.h>\n'
    '#include <libkern/OSCacheControl.h>\n'
    '#define DOSBOX_APPLE_JIT 1\n'
    'static INLINE void cache_jit_writable(void)   { pthread_jit_write_protect_np(0); }\n'
    'static INLINE void cache_jit_executable(void) { pthread_jit_write_protect_np(1); }\n'
    'static INLINE void cache_flush_icache(void *start, size_t len) { sys_icache_invalidate(start, len); }\n'
    '#else\n'
    'static INLINE void cache_jit_writable(void)   {}\n'
    'static INLINE void cache_jit_executable(void) {}\n'
    'static INLINE void cache_flush_icache(void *start, size_t len) { (void)start; (void)len; }\n'
    '#endif\n'
)

CONFIG_H_OVERRIDE = """
/* ---- per-architecture dynamic core selection (fix_macos_build.py) ----------
 * A universal (arm64 + x86_64) build shares one config.h between both
 * slices, but the correct dynamic core differs per architecture:
 *   x86_64 slice -> classic dynamic core (core_dyn_x86) + x86 assembly FPU
 *   arm64  slice -> portable recompiler (core_dynrec), ARMv8 backend
 * Stock ./configure can only pick ONE setting (and on arm64-apple hosts it
 * historically picked NONE, because config.guess reports "arm64" while
 * configure.ac only knew "aarch64"). The block below re-derives all
 * CPU-specific settings from the compiler's target macros, which are always
 * correct per slice. */
#undef C_DYNAMIC_X86
#undef C_DYNREC
#undef C_TARGETCPU
#undef C_UNALIGNED_MEMORY
#undef C_FPU_X86
#if defined(__x86_64__)
#define C_TARGETCPU X86_64
#define C_DYNAMIC_X86 1
#define C_FPU_X86 1
#define C_UNALIGNED_MEMORY 1
#elif defined(__aarch64__)
#define C_TARGETCPU ARMV8LE
#define C_DYNREC 1
#define C_UNALIGNED_MEMORY 1
#endif
/* ---- end per-architecture overrides ---------------------------------------- */
"""


def patch_dynrec_apple_silicon():
    """All source patches needed for a working dynrec core on Apple Silicon.

    r4301/r4358 keep the dynrec code cache in src/cpu/core_dynrec/cache.h.
    Around SVN r4461 upstream merged the cache handling of BOTH dynamic
    cores into the shared src/cpu/dyn_cache.h (r4482 uses this layout).
    The code itself is unchanged, so the same patches apply — only the
    file location differs.
    """
    core_cpp = 'src/cpu/core_dynrec.cpp'
    if os.path.exists('src/cpu/core_dynrec/cache.h'):
        cache_h = 'src/cpu/core_dynrec/cache.h'
    elif os.path.exists('src/cpu/dyn_cache.h'):
        cache_h = 'src/cpu/dyn_cache.h'
    else:
        print("  FAIL: neither src/cpu/core_dynrec/cache.h nor "
              "src/cpu/dyn_cache.h exists — cannot patch the dynrec cache.")
        sys.exit(1)
    print(f"  (dynrec cache file: {cache_h})")

    # (a) 16 KiB pages on Apple Silicon --------------------------------------
    if not file_contains(cache_h, 'PAGESIZE_TEMP 16384'):
        ok = patch(
            cache_h,
            '#if (C_HAVE_MPROTECT)\n'
            '#define PAGESIZE_TEMP PAGESIZE\n'
            '#else \n'
            '#define PAGESIZE_TEMP 4096\n'
            '#endif',
            '#if defined(__APPLE__) && defined(__aarch64__)\n'
            '/* Apple Silicon: 16 KiB kernel pages; the code cache is MAP_JIT mmap\'d */\n'
            '#define PAGESIZE_TEMP 16384\n'
            '#elif (C_HAVE_MPROTECT)\n'
            '#define PAGESIZE_TEMP PAGESIZE\n'
            '#else \n'
            '#define PAGESIZE_TEMP 4096\n'
            '#endif',
            'Use 16 KiB pages for the dynrec cache on Apple Silicon'
        )
        if not ok:
            # tolerate whitespace variations
            patch_re(
                cache_h,
                r'#if \(C_HAVE_MPROTECT\)\s*\n#define PAGESIZE_TEMP PAGESIZE\s*\n#else\s*\n#define PAGESIZE_TEMP 4096\s*\n#endif',
                '#if defined(__APPLE__) && defined(__aarch64__)\n'
                '#define PAGESIZE_TEMP 16384\n'
                '#elif (C_HAVE_MPROTECT)\n'
                '#define PAGESIZE_TEMP PAGESIZE\n'
                '#else\n'
                '#define PAGESIZE_TEMP 4096\n'
                '#endif',
                'Use 16 KiB pages for the dynrec cache on Apple Silicon (regex)',
                required=True
            )

    # (b) inject the W^X helper functions ------------------------------------
    if not file_contains(cache_h, 'DOSBOX_APPLE_JIT'):
        patch(
            cache_h,
            'static bool cache_initialized = false;',
            JIT_HELPERS + '\nstatic bool cache_initialized = false;',
            'Add Apple Silicon W^X JIT helpers',
            required=True
        )

    # (c) allocate the code cache with mmap(MAP_JIT) on Apple Silicon --------
    if not file_contains(cache_h, 'MAP_PRIVATE|MAP_ANON|MAP_JIT'):
        ok = patch(
            cache_h,
            '#else\n'
            '\t\t\tcache_code_start_ptr=(Bit8u*)malloc(CACHE_TOTAL+CACHE_MAXSIZE+PAGESIZE_TEMP-1+PAGESIZE_TEMP);\n'
            '#endif',
            '#elif defined(__APPLE__) && defined(__aarch64__)\n'
            '\t\t\t/* W^X: executable memory must be mmap\'d with MAP_JIT on Apple Silicon.\n'
            '\t\t\t   malloc\'d memory can NEVER be made executable there. */\n'
            '\t\t\tcache_code_start_ptr=(Bit8u*)mmap(NULL,CACHE_TOTAL+CACHE_MAXSIZE+PAGESIZE_TEMP-1+PAGESIZE_TEMP,\n'
            '\t\t\t\tPROT_READ|PROT_WRITE|PROT_EXEC,MAP_PRIVATE|MAP_ANON|MAP_JIT,-1,0);\n'
            '\t\t\tif (cache_code_start_ptr==(Bit8u*)MAP_FAILED) cache_code_start_ptr=NULL;\n'
            '#else\n'
            '\t\t\tcache_code_start_ptr=(Bit8u*)malloc(CACHE_TOTAL+CACHE_MAXSIZE+PAGESIZE_TEMP-1+PAGESIZE_TEMP);\n'
            '#endif',
            'Allocate the dynrec cache with mmap(MAP_JIT) on Apple Silicon'
        )
        if not ok:
            patch_re(
                cache_h,
                r'#else\s*\n(\s*)cache_code_start_ptr\s*=\s*\(Bit8u\s*\*\)\s*malloc\(CACHE_TOTAL\+CACHE_MAXSIZE\+PAGESIZE_TEMP-1\+PAGESIZE_TEMP\);\s*\n#endif',
                '#elif defined(__APPLE__) && defined(__aarch64__)\n'
                r'\1cache_code_start_ptr=(Bit8u*)mmap(NULL,CACHE_TOTAL+CACHE_MAXSIZE+PAGESIZE_TEMP-1+PAGESIZE_TEMP,'
                '\n'
                r'\1	PROT_READ|PROT_WRITE|PROT_EXEC,MAP_PRIVATE|MAP_ANON|MAP_JIT,-1,0);'
                '\n'
                r'\1if (cache_code_start_ptr==(Bit8u*)MAP_FAILED) cache_code_start_ptr=NULL;'
                '\n#else\n'
                r'\1cache_code_start_ptr=(Bit8u*)malloc(CACHE_TOTAL+CACHE_MAXSIZE+PAGESIZE_TEMP-1+PAGESIZE_TEMP);'
                '\n#endif',
                'Allocate the dynrec cache with mmap(MAP_JIT) on Apple Silicon (regex)',
                required=True
            )

    # (d) skip the mprotect() call on Apple Silicon (MAP_JIT already RWX,
    #     and mprotect on JIT regions is not permitted) ----------------------
    if not file_contains(cache_h, 'C_HAVE_MPROTECT) && !(defined(__APPLE__)'):
        patch_re(
            cache_h,
            r'#if \(C_HAVE_MPROTECT\)(\s*\n\s*if\s*\(mprotect\(cache_code_link_blocks)',
            r'#if (C_HAVE_MPROTECT) && !(defined(__APPLE__) && defined(__aarch64__))\1',
            'Skip mprotect on the MAP_JIT cache (Apple Silicon)',
            required=True
        )

    # (e) open the cache for writing while cache_init generates the link
    #     blocks + run-code stub, then flush icache and re-protect -----------
    if not file_contains(cache_h, 'cache_jit_writable();\t// W^X'):
        patch(
            cache_h,
            '\t\t// setup the default blocks for block linkage returns\n'
            '\t\tcache.pos=&cache_code_link_blocks[0];',
            '\t\tcache_jit_writable();\t// W^X: open the JIT cache for writing\n'
            '\t\t// setup the default blocks for block linkage returns\n'
            '\t\tcache.pos=&cache_code_link_blocks[0];',
            'Enable JIT writes before generating the linkage stubs'
        ) or patch_re(
            cache_h,
            r'^([ \t]*)(// setup the default blocks for block linkage returns\n'
            r'[ \t]*cache\.pos=&cache_code_link_blocks\[0\];)',
            r'\1cache_jit_writable();\t// W^X: open the JIT cache for writing\n\1\2',
            'Enable JIT writes before generating the linkage stubs (regex)',
            required=True
        )
    if not file_contains(cache_h, 'cache_jit_executable();\t// W^X'):
        patch(
            cache_h,
            '\t\tdyn_run_code();\n'
            '\n'
            '\t\tcache.free_pages=0;',
            '\t\tdyn_run_code();\n'
            '\t\tcache_flush_icache(cache_code_link_blocks,PAGESIZE_TEMP);\n'
            '\t\tcache_jit_executable();\t// W^X: linkage stubs written, back to executable\n'
            '\n'
            '\t\tcache.free_pages=0;',
            'Flush icache + re-protect after generating the linkage stubs'
        ) or patch_re(
            cache_h,
            r'(\n(\s*)dyn_run_code\(\);\n)',
            r'\1\2cache_flush_icache(cache_code_link_blocks,PAGESIZE_TEMP);\n'
            r'\2cache_jit_executable();\t// W^X: linkage stubs written, back to executable\n',
            'Flush icache + re-protect after generating the linkage stubs (regex)',
            required=True
        )

    # (f) wrap runtime block translation (the only other place that writes
    #     into the executable cache) -----------------------------------------
    if not file_contains(core_cpp, 'cache_jit_writable();'):
        patch_re(
            core_cpp,
            r'^([ \t]*)block=CreateCacheBlock\(chandler,ip_point,32\);',
            r'\1cache_jit_writable();\t// W^X: block translation writes generated code\n'
            r'\1block=CreateCacheBlock(chandler,ip_point,32);\n'
            r'\1cache_jit_executable();\t// W^X: back to executable before running it',
            'Toggle W^X around dynrec block translation',
            required=True
        )


def apply_per_arch_override():
    """Install the per-architecture dynamic core override in BOTH places.

    Primary: include/dosbox.h, immediately after '#include "config.h"'.
    Every CPU-related translation unit includes dosbox.h, and dosbox.h is
    a plain source file that nothing ever regenerates.

    Secondary: appended to config.h. This copy does NOT reliably survive:
    automake's remake rules may re-run config.status during `make` (any
    autotools output that looks stale triggers it), which rewrites config.h
    from the config.h.in template and silently drops anything appended —
    disabling every dynamic core again. That failure mode is exactly why
    the dosbox.h injection above is the copy that counts.
    """
    dosbox_h = os.path.join('include', 'dosbox.h')
    if file_contains(dosbox_h, 'per-architecture dynamic core selection'):
        print("  SKIP  include/dosbox.h override already present")
    else:
        patch(
            dosbox_h,
            '#include "config.h"',
            '#include "config.h"\n' + CONFIG_H_OVERRIDE,
            'Inject per-arch core override (survives config.h regeneration)',
            required=True
        )

    if not os.path.exists('config.h'):
        print("ERROR: config.h not found after configure — cannot apply the")
        print("       per-architecture dynamic core overrides.")
        sys.exit(1)
    if file_contains('config.h', 'per-architecture dynamic core selection'):
        print("  SKIP  config.h override already present")
    else:
        with open('config.h', 'a') as f:
            f.write(CONFIG_H_OVERRIDE)
        print("  PATCH config.h — appended per-architecture dynamic core overrides")


# ──────────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────────

def main():
    if not os.path.exists('configure.ac') or not os.path.exists('src'):
        print("ERROR: run this script from an ECE source directory "
              "(e.g., cd ece-r4358)")
        sys.exit(1)

    prefix = resolve_deps_prefix()
    env_updates, macos_min, universal = build_flags(prefix)

    print("=== DOSBox ECE macOS Build Fix ===")
    print(f"  Source directory:  {os.getcwd()}")
    print(f"  Deps prefix:       {prefix}")
    print(f"  Target macOS:      {macos_min}")
    print(f"  Universal build:   {'yes (arm64 + x86_64)' if universal else 'no'}")
    print()

    # ────────────────────────────────────────────────────────────────────────
    # [1] Rename VERSION -> VERSION.txt
    #     macOS case-insensitive FS otherwise serves it as the C++20 <version>
    #     header when `-I../..` is on the include path.
    # ────────────────────────────────────────────────────────────────────────
    print("[1/10] Renaming VERSION file...")
    if os.path.exists('VERSION') and not os.path.exists('VERSION.txt'):
        os.rename('VERSION', 'VERSION.txt')
        print("  DONE: VERSION -> VERSION.txt")
    elif os.path.exists('VERSION.txt'):
        print("  SKIP: already renamed")
    else:
        print("  SKIP: no VERSION file")
    print()

    # ────────────────────────────────────────────────────────────────────────
    # [2] glide.cpp — macOS window handle fallback
    # ────────────────────────────────────────────────────────────────────────
    print("[2/10] Patching src/hardware/glide.cpp...")
    patch(
        'src/hardware/glide.cpp',
        '#if defined (WIN32)\n\thwnd = (HostPt)wmi.window;\n#else\n\thwnd = (HostPt)wmi.info.x11.window;\n#endif',
        '#if defined (WIN32)\n\thwnd = (HostPt)wmi.window;\n#elif defined(SDL_VIDEO_DRIVER_X11)\n\thwnd = (HostPt)wmi.info.x11.window;\n#else\n\thwnd = NULL;\n#endif',
        'Add macOS/non-X11 fallback for hwnd'
    )
    print()

    # ────────────────────────────────────────────────────────────────────────
    # [3] voodoo_vogl.h — OpenGL type and symbol conflicts
    # ────────────────────────────────────────────────────────────────────────
    print("[3/10] Patching src/hardware/voodoo_vogl.h...")

    MACOS_TYPEDEFS = (
        '#ifdef __APPLE__\n'
        '/* On macOS, GL_VERSION_2_0 is pre-defined by system headers, causing SDL_opengl.h\n'
        ' * to skip its typedef block for core GL 2.0 proc types. Define them manually. */\n'
        '#ifndef PFNGLDELETEPROGRAMPROC\n'
        'typedef void (APIENTRYP PFNGLDELETEPROGRAMPROC)(GLuint program);\n'
        '#endif\n'
        '#ifndef PFNGLBLENDFUNCSEPARATEPROC\n'
        'typedef void (APIENTRYP PFNGLBLENDFUNCSEPARATEPROC)(GLenum sfactorRGB, GLenum dfactorRGB, GLenum sfactorAlpha, GLenum dfactorAlpha);\n'
        '#endif\n'
        '#ifndef PFNGLVERTEXATTRIB1FPROC\n'
        'typedef void (APIENTRYP PFNGLVERTEXATTRIB1FPROC)(GLuint index, GLfloat x);\n'
        '#endif\n'
        '#endif\n'
    )

    patch(
        'src/hardware/voodoo_vogl.h',
        '#ifndef _WIN32\n\t#define GL_ARB_multitexture\n\t#include <GL/gl.h>\n\t#undef GL_ARB_multitexture',
        '#if !defined(_WIN32) && !defined(__APPLE__)\n\t#define GL_ARB_multitexture\n\t#include <GL/gl.h>\n\t#undef GL_ARB_multitexture',
        'Skip GL/gl.h include on macOS (SDL_opengl.h handles it)'
    )

    for old_anchor, new_anchor in [
        (
            '#include "SDL_opengl.h"\n\ntypedef Bit32s INT32;\n\n/* opengl extensions */',
            '#include "SDL_opengl.h"\n\n' + MACOS_TYPEDEFS + '\ntypedef Bit32s INT32;\n\n/* opengl extensions */'
        ),
        (
            '#include "SDL.h"\n#include "SDL_opengl.h"\n\n\n/* opengl extensions */',
            '#include "SDL.h"\n#include "SDL_opengl.h"\n\n' + MACOS_TYPEDEFS + '\n/* opengl extensions */'
        ),
    ]:
        if patch('src/hardware/voodoo_vogl.h', old_anchor, new_anchor, 'Add macOS GL proc typedefs'):
            break

    patch(
        'src/hardware/voodoo_vogl.h',
        'extern PFNGLUSEPROGRAMOBJECTARBPROC glUseProgramObjectARB;\nextern PFNGLDELETEPROGRAMPROC glDeleteProgram;\nextern PFNGLUNIFORM1IARBPROC glUniform1iARB;',
        'extern PFNGLUSEPROGRAMOBJECTARBPROC glUseProgramObjectARB;\n#ifndef __APPLE__\n/* On macOS glDeleteProgram is a real GL function, not a function pointer variable */\nextern PFNGLDELETEPROGRAMPROC glDeleteProgram;\n#endif\nextern PFNGLUNIFORM1IARBPROC glUniform1iARB;',
        'Guard glDeleteProgram extern on macOS'
    )

    patch(
        'src/hardware/voodoo_vogl.h',
        'extern PFNGLGETINFOLOGARBPROC glGetInfoLogARB;\nextern PFNGLBLENDFUNCSEPARATEPROC glBlendFuncSeparate;\nextern PFNGLGENERATEMIPMAPEXTPROC glGenerateMipmap;',
        'extern PFNGLGETINFOLOGARBPROC glGetInfoLogARB;\n#ifndef __APPLE__\n/* On macOS glBlendFuncSeparate is a real GL function, not a function pointer variable */\nextern PFNGLBLENDFUNCSEPARATEPROC glBlendFuncSeparate;\n#endif\nextern PFNGLGENERATEMIPMAPEXTPROC glGenerateMipmap;',
        'Guard glBlendFuncSeparate extern on macOS'
    )
    print()

    # ────────────────────────────────────────────────────────────────────────
    # [4] voodoo_vogl.cpp — function-pointer variable defs and dynamic loads
    # ────────────────────────────────────────────────────────────────────────
    print("[4/10] Patching src/hardware/voodoo_vogl.cpp...")

    patch(
        'src/hardware/voodoo_vogl.cpp',
        'PFNGLUSEPROGRAMOBJECTARBPROC glUseProgramObjectARB = NULL;\nPFNGLDELETEPROGRAMPROC glDeleteProgram = NULL;\nPFNGLUNIFORM1IARBPROC glUniform1iARB = NULL;',
        'PFNGLUSEPROGRAMOBJECTARBPROC glUseProgramObjectARB = NULL;\n#ifndef __APPLE__\nPFNGLDELETEPROGRAMPROC glDeleteProgram = NULL;\n#endif\nPFNGLUNIFORM1IARBPROC glUniform1iARB = NULL;',
        'Guard glDeleteProgram variable definition on macOS'
    )

    patch(
        'src/hardware/voodoo_vogl.cpp',
        'PFNGLGETINFOLOGARBPROC glGetInfoLogARB = NULL;\nPFNGLBLENDFUNCSEPARATEPROC glBlendFuncSeparate = NULL;\nPFNGLGENERATEMIPMAPEXTPROC glGenerateMipmap = NULL;',
        'PFNGLGETINFOLOGARBPROC glGetInfoLogARB = NULL;\n#ifndef __APPLE__\nPFNGLBLENDFUNCSEPARATEPROC glBlendFuncSeparate = NULL;\n#endif\nPFNGLGENERATEMIPMAPEXTPROC glGenerateMipmap = NULL;',
        'Guard glBlendFuncSeparate variable definition on macOS'
    )

    patch(
        'src/hardware/voodoo_vogl.cpp',
        '\tglBlendFuncSeparate = (PFNGLBLENDFUNCSEPARATEPROC)SDL_GL_GetProcAddress("glBlendFuncSeparate");\n\tif (!glBlendFuncSeparate) {\n\t\tLOG_MSG("opengl: glBlendFuncSeparate extension not supported");\n\t\treturn false;\n\t}',
        '#ifndef __APPLE__\n\tglBlendFuncSeparate = (PFNGLBLENDFUNCSEPARATEPROC)SDL_GL_GetProcAddress("glBlendFuncSeparate");\n\tif (!glBlendFuncSeparate) {\n\t\tLOG_MSG("opengl: glBlendFuncSeparate extension not supported");\n\t\treturn false;\n\t}\n#endif',
        'Guard glBlendFuncSeparate dynamic load on macOS'
    )

    patch(
        'src/hardware/voodoo_vogl.cpp',
        '\t\t\t\tglDeleteProgram = (PFNGLDELETEPROGRAMPROC)SDL_GL_GetProcAddress("glDeleteProgram");\n\t\t\t\tif (!glDeleteProgram) LOG_MSG("opengl: glDeleteProgram extension not supported");',
        '#ifndef __APPLE__\n\t\t\t\tglDeleteProgram = (PFNGLDELETEPROGRAMPROC)SDL_GL_GetProcAddress("glDeleteProgram");\n\t\t\t\tif (!glDeleteProgram) LOG_MSG("opengl: glDeleteProgram extension not supported");\n#endif',
        'Guard glDeleteProgram dynamic load on macOS'
    )
    print()

    # ────────────────────────────────────────────────────────────────────────
    # [5] voodoo_data.h — shader handle type
    # ────────────────────────────────────────────────────────────────────────
    print("[5/10] Patching src/hardware/voodoo_data.h...")

    patch(
        'src/hardware/voodoo_data.h',
        '#ifndef DOSBOX_VOODOO_DATA_H\n#define DOSBOX_VOODOO_DATA_H',
        '#ifndef DOSBOX_VOODOO_DATA_H\n#define DOSBOX_VOODOO_DATA_H\n\n'
        '/* GLhandleARB is void* on macOS but unsigned int on other platforms.\n'
        ' * Use a pointer-sized type so shader handles can be stored safely. */\n'
        '#ifdef __APPLE__\ntypedef void* OGL_SHADER_HANDLE;\n'
        '#else\ntypedef unsigned int OGL_SHADER_HANDLE;\n#endif',
        'Add OGL_SHADER_HANDLE cross-platform typedef'
    )

    patch(
        'src/hardware/voodoo_data.h',
        '\tbool\t\t\t\tshader_ready;\n'
        '\tUINT32\t\t\t\tso_shader_program;\n'
        '\tUINT32\t\t\t\tso_vertex_shader;\n'
        '\tUINT32\t\t\t\tso_fragment_shader;',
        '\tbool\t\t\t\tshader_ready;\n'
        '\tOGL_SHADER_HANDLE\t\tso_shader_program;\n'
        '\tOGL_SHADER_HANDLE\t\tso_vertex_shader;\n'
        '\tOGL_SHADER_HANDLE\t\tso_fragment_shader;',
        'Change shader handle fields to OGL_SHADER_HANDLE'
    )
    print()

    # ────────────────────────────────────────────────────────────────────────
    # [6] voodoo_opengl.cpp — shader handle comparisons and cast
    # ────────────────────────────────────────────────────────────────────────
    print("[6/10] Patching src/hardware/voodoo_opengl.cpp...")

    patch_re(
        'src/hardware/voodoo_opengl.cpp',
        r'(\t+)if \(info->so_shader_program > 0\) \{\n'
        r'(\t+)if \(info->so_vertex_shader >= 0\) (glDetachObjectARB\(info->so_shader_program, info->so_vertex_shader\));\n'
        r'\2if \(info->so_fragment_shader >= 0\) (glDetachObjectARB\(info->so_shader_program, info->so_fragment_shader\));\n'
        r'\2if \(info->so_vertex_shader >= 0\) (glDeleteObjectARB\(info->so_vertex_shader\));\n'
        r'\2if \(info->so_fragment_shader >= 0\) (glDeleteObjectARB\(info->so_fragment_shader\));\n'
        r'\2glDeleteProgram\(info->so_shader_program\);',
        r'\1if (info->so_shader_program != (OGL_SHADER_HANDLE)0) {\n'
        r'\2if (info->so_vertex_shader != (OGL_SHADER_HANDLE)0) \3;\n'
        r'\2if (info->so_fragment_shader != (OGL_SHADER_HANDLE)0) \4;\n'
        r'\2if (info->so_vertex_shader != (OGL_SHADER_HANDLE)0) \5;\n'
        r'\2if (info->so_fragment_shader != (OGL_SHADER_HANDLE)0) \6;\n'
        r'\2glDeleteProgram((GLuint)(uintptr_t)info->so_shader_program);',
        'Fix pointer comparisons and glDeleteProgram cast for macOS'
    )
    print()

    # ────────────────────────────────────────────────────────────────────────
    # [7] src/libs/decoders/internal/Makefile — disable opus intrinsics/RTCD
    #     On a universal (arm64 + x86_64) build, opus' configure probes for
    #     SSE/AVX intrinsics, which are invalid on the arm64 slice.
    # ────────────────────────────────────────────────────────────────────────
    print("[7/10] Patching src/libs/decoders/internal/Makefile (opus sub-configure)...")
    patch(
        'src/libs/decoders/internal/Makefile',
        '--disable-shared --disable-extra-programs --disable-doc',
        '--disable-shared --disable-extra-programs --disable-doc '
        '--disable-intrinsics --disable-rtcd',
        'Disable opus SSE/AVX intrinsics + RTCD for universal build',
    )
    print()

    # ────────────────────────────────────────────────────────────────────────
    # [8] configure.ac — recognize arm64-apple-darwin
    #     macOS's config.guess reports host_cpu "arm64", but stock DOSBox
    #     configure.ac only matches "aarch64". The fall-through set
    #     C_TARGETCPU to UNKNOWN, which silently disabled EVERY dynamic core.
    #     This was the primary reason the dynamic core "did not work" on
    #     Apple Silicon. (config.h is additionally overridden per-arch after
    #     configure, so this patch mostly keeps configure's own report
    #     honest.)
    # ────────────────────────────────────────────────────────────────────────
    print("[8/10] Patching configure.ac (arm64 host detection)...")
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

    # ────────────────────────────────────────────────────────────────────────
    # [9] core_dynrec — Apple Silicon W^X / MAP_JIT / 16K page support
    # ────────────────────────────────────────────────────────────────────────
    print("[9/10] Patching core_dynrec for Apple Silicon (W^X, MAP_JIT, 16K pages)...")
    patch_dynrec_apple_silicon()
    print()

    # ────────────────────────────────────────────────────────────────────────
    # Run autogen.sh if needed
    # ────────────────────────────────────────────────────────────────────────
    needs_autogen = (
        not os.path.exists('configure') or
        os.path.getmtime('configure.ac') > os.path.getmtime('configure')
    )
    env = os.environ.copy()
    env.update(env_updates)

    # Scrub pollution vectors from the inherited environment.
    for var in (
        'PKG_CONFIG_PATH',      # replaced by PKG_CONFIG_LIBDIR above
        'CPATH', 'C_INCLUDE_PATH', 'CPLUS_INCLUDE_PATH',
        'OBJC_INCLUDE_PATH', 'OBJCPLUS_INCLUDE_PATH',
        'LIBRARY_PATH', 'DYLD_LIBRARY_PATH',
        'CMAKE_PREFIX_PATH', 'CMAKE_FRAMEWORK_PATH',
    ):
        env.pop(var, None)

    if needs_autogen:
        print("[*] Running ./autogen.sh (autoconf/automake/libtool required)...")
        if subprocess.run(['./autogen.sh'], env=env).returncode != 0:
            print("\nERROR: autogen.sh failed.")
            print("  Build the autotools first (no Homebrew/MacPorts needed):")
            print("      ./bootstrap_tools.sh")
            print("  and make sure tools-prefix/bin is on PATH (build_all_ece.sh")
            print("  does this automatically).")
            sys.exit(1)
        print()
    else:
        print("[*] configure is up to date, skipping autogen.sh")

    # ────────────────────────────────────────────────────────────────────────
    # Configure — point everything at our dependency prefix
    # ────────────────────────────────────────────────────────────────────────
    print("[*] Running ./configure (universal, macOS-min=%s)..." % macos_min)
    prefix = resolve_deps_prefix()

    configure_args = [
        './configure',
        f'--with-sdl-prefix={prefix}',
        f'CPPFLAGS={env_updates["CPPFLAGS"]}',
        f'CFLAGS={env_updates["CFLAGS"]}',
        f'CXXFLAGS={env_updates["CXXFLAGS"]}',
        f'LDFLAGS={env_updates["LDFLAGS"]}',
    ]

    sdl_config = os.path.join(prefix, 'bin', 'sdl-config')
    if os.path.exists(sdl_config):
        configure_args.insert(1, f'--with-sdl-exec-prefix={prefix}')

    env['PATH'] = prefix + os.sep + 'bin' + os.pathsep + env.get('PATH', '')

    # NOTE on the dynamic core flags: the definitive per-architecture core
    # selection happens in the config.h override appended AFTER configure
    # (see CONFIG_H_OVERRIDE). The flags below merely keep configure itself
    # from failing or from enabling something that cannot compile in a
    # universal build. Whatever configure decides for C_DYNAMIC_X86 /
    # C_DYNREC / C_TARGETCPU / C_FPU_X86 is overridden afterwards.
    for opt in (
        '--enable-core-inline',
        '--enable-dynamic-core',
        '--enable-dynrec',
        '--enable-fpu',
    ):
        configure_args.append(opt)

    rc = subprocess.run(configure_args, env=env).returncode
    if rc != 0:
        print("\nERROR: configure failed.")
        sys.exit(1)

    # ────────────────────────────────────────────────────────────────────────
    # [10] Post-configure: per-architecture dynamic core overrides
    # ────────────────────────────────────────────────────────────────────────
    print()
    print("[10/10] Installing per-architecture dynamic core overrides"
          " (include/dosbox.h + config.h)...")
    apply_per_arch_override()

    # Belt-and-suspenders re-apply of the opus intrinsics patch in case the
    # decoders Makefile is (re)generated by configure in some revision.
    decoders_mk = 'src/libs/decoders/internal/Makefile'
    if os.path.exists(decoders_mk):
        with open(decoders_mk, 'r') as f:
            content = f.read()
        new_content, n = re.subn(
            r'(--disable-extra-programs[\s\\]*--disable-doc)\b',
            r'\1 --disable-intrinsics --disable-rtcd',
            content,
            count=1,
        )
        if n > 0 and '--disable-intrinsics' not in content:
            with open(decoders_mk, 'w') as f:
                f.write(new_content)
            print(f"[*] Post-configure patch applied: {decoders_mk}")
        elif '--disable-intrinsics' in content:
            print(f"[*] {decoders_mk} already carries --disable-intrinsics (skip)")
        else:
            print(f"[!] WARN: could not locate opus configure flags in {decoders_mk}")
    else:
        print(f"[!] WARN: {decoders_mk} not found after configure")

    print()
    print("=" * 60)
    print("Patches applied and configure succeeded.")
    print("Now run: make -j$(sysctl -n hw.logicalcpu)")
    print("=" * 60)


if __name__ == '__main__':
    main()
