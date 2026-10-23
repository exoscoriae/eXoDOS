"""
dynrec_apple_silicon.py — shared Apple Silicon dynamic-core patch machinery
for DOSBox-SVN-family forks (ECE / GridC / Gunstick).

Extracted from fix_macos_build.py (the ECE fix script), where this exact
code produced verified-working per-slice dynamic cores. Provides:

  patch(), patch_re(), file_contains()   — idempotent patch primitives
  JIT_HELPERS                            — W^X helper functions source text
  patch_dynrec_apple_silicon()           — cache.h/core_dynrec.cpp W^X,
                                           MAP_JIT and 16 KiB page patches
  make_override(fpu_x86=...)             — per-arch config override text
  apply_per_arch_override(override)      — inject into include/dosbox.h
                                           (primary) + config.h (secondary)
"""

import os
import re
import sys

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


def make_override(dyn_x86=True, fpu_x86=True):
    """Return the per-arch override block.

    dyn_x86=True  -> x86_64 slice gets the classic dynamic core
                     (core_dyn_x86). ONLY safe when the base has the
                     64-bit dyn_x86 backend (ECE r4301+ does). GridC and
                     Gunstick unconditionally include the 32-bit-only
                     risc_x86.h in core_dyn_x86.cpp, so they MUST use
                     dyn_x86=False.
    dyn_x86=False -> x86_64 slice uses the portable recompiler
                     (core_dynrec) with its risc_x64 backend instead.

    fpu_x86=True  -> x86_64 slice also gets the x86 assembly FPU
                     (safe on ECE; the old forks' asm FPU is 32-bit-only).
    """
    if dyn_x86:
        x86_core_comment = 'classic dynamic core (core_dyn_x86)'
        x86_core_defs = '#define C_DYNAMIC_X86 1\n'
        if fpu_x86:
            x86_core_comment += ' + x86 assembly FPU'
            x86_core_defs += '#define C_FPU_X86 1\n'
    else:
        x86_core_comment = 'portable recompiler (core_dynrec), x64 backend'
        x86_core_defs = '#define C_DYNREC 1\n'

    return f"""
/* ---- per-architecture dynamic core selection (dynrec_apple_silicon) --------
 * A universal (arm64 + x86_64) build shares one config.h between both
 * slices, but the correct dynamic core differs per architecture:
 *   x86_64 slice -> {x86_core_comment}
 *   arm64  slice -> portable recompiler (core_dynrec), ARMv8 backend
 * configure runs once (on the arm64 host) and cannot get this right, so
 * re-derive every CPU-specific setting from the compiler's target macros,
 * which are always correct per slice. */
#undef C_DYNAMIC_X86
#undef C_DYNREC
#undef C_TARGETCPU
#undef C_UNALIGNED_MEMORY
#undef C_FPU_X86
#if defined(__x86_64__)
#define C_TARGETCPU X86_64
{x86_core_defs}#define C_UNALIGNED_MEMORY 1
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



def apply_per_arch_override(override_text):
    """Install the override in include/dosbox.h (primary; survives config.h
    regeneration by automake remake rules) and config.h (secondary)."""
    dosbox_h = os.path.join('include', 'dosbox.h')
    if file_contains(dosbox_h, 'per-architecture dynamic core selection'):
        print("  SKIP  include/dosbox.h override already present")
    else:
        patch(
            dosbox_h,
            '#include "config.h"',
            '#include "config.h"\n' + override_text,
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
            f.write(override_text)
        print("  PATCH config.h — appended per-architecture dynamic core overrides")
