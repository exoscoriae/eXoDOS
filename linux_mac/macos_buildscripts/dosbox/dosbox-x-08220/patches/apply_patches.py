#!/usr/bin/env python3
"""
Source patches for DOSBox-X 0.82.20 -> portable macOS 11+ universal build.

Applied as exact/regex string substitutions rather than context diffs so that
line-ending or trailing-whitespace differences in the tarball can never cause
a silent mis-apply.  Every substitution is verified; the script aborts with a
clear message if anything does not match exactly once.

Usage: python3 apply_patches.py /path/to/dosbox-x-source-tree
"""

import re
import sys
import os

def die(msg):
    sys.stderr.write("PATCH FAILED: %s\n" % msg)
    sys.exit(1)

def edit(path, subs, regex_subs=()):
    if not os.path.isfile(path):
        die("file not found: %s" % path)
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
        text = f.read()
    orig = text
    for old, new, in subs:
        n = text.count(old)
        if n != 1:
            die("expected exactly 1 occurrence in %s, found %d:\n---\n%s\n---" % (path, n, old))
        text = text.replace(old, new)
    for pat, new, in regex_subs:
        text, n = re.subn(pat, new, text, flags=re.DOTALL)
        if n != 1:
            die("regex matched %d times (expected 1) in %s:\n---\n%s\n---" % (n, path, pat))
    if text == orig:
        die("no changes made to %s" % path)
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(text)
    print("patched: %s" % path)

root = sys.argv[1] if len(sys.argv) > 1 else "."

# ---------------------------------------------------------------------------
# Patch 1: src/cpu/core_dynrec/cache.h
#
#   The 2019 code allocates the dynamic-recompiler code cache with malloc()
#   and flips it executable with mprotect(), assuming a 4096-byte page.
#   On Apple Silicon (arm64 macOS):
#     * the kernel page size is 16384 bytes, so 4096-aligned mprotect fails,
#     * PROT_WRITE|PROT_EXEC mappings require mmap(MAP_JIT),
#     * mprotect(PROT_EXEC) on malloc'd heap memory is refused outright.
#   Fix: 16K-safe PAGESIZE_TEMP on Apple, mmap-based RWX/MAP_JIT allocation,
#   pthread_jit_write_protect_np(0) (no-op without the hardened runtime, but
#   correct with it), and an explicit i-cache invalidate for the startup
#   link-block stubs which are written outside the normal block-close path
#   (dyn_closeblock -> cache_block_closing already flushes normal blocks).
# ---------------------------------------------------------------------------

cache_h = os.path.join(root, "src/cpu/core_dynrec/cache.h")

edit(cache_h,
    subs=[
        # 1a. platform includes
        ("class CodePageHandlerDynRec;\t// forward",
         "#if defined(__APPLE__)\n"
         "#include <sys/mman.h>\n"
         "#include <pthread.h>\n"
         "#include <unistd.h>\n"
         "#include <libkern/OSCacheControl.h>\n"
         "#endif\n"
         "\n"
         "class CodePageHandlerDynRec;\t// forward"),

        # 1c. i-cache coherency for the startup stubs (BR_Link1/BR_Link2/run_code)
        ("\t\tcache.pos=&cache_code_link_blocks[64];\n"
         "\t\t*(void**)(&core_dynrec.runcode) = (void*)cache.pos;\n"
         "//\t\tlink_blocks[1].cache.start=cache.pos;\n"
         "\t\tdyn_run_code();",
         "\t\tcache.pos=&cache_code_link_blocks[64];\n"
         "\t\t*(void**)(&core_dynrec.runcode) = (void*)cache.pos;\n"
         "//\t\tlink_blocks[1].cache.start=cache.pos;\n"
         "\t\tdyn_run_code();\n"
         "#if defined(__APPLE__) && defined(__aarch64__)\n"
         "\t\t/* these stubs were written outside the normal block-close path;\n"
         "\t\t * make the instruction cache coherent before they are executed */\n"
         "\t\tsys_icache_invalidate(cache_code_link_blocks, PAGESIZE_TEMP);\n"
         "#endif"),
    ],
    regex_subs=[
        # 1b. PAGESIZE_TEMP: must be a multiple of the 16K Apple Silicon page
        (r"/\* Define temporary pagesize so the MPROTECT case and the regular case share as much code as possible \*/\n"
         r"#if \(C_HAVE_MPROTECT\)\n"
         r"#define PAGESIZE_TEMP PAGESIZE\n"
         r"#else[ \t]*\n"
         r"#define PAGESIZE_TEMP 4096\n"
         r"#endif",
         "/* Define temporary pagesize so the MPROTECT case and the regular case share as much code as possible */\n"
         "#if defined(__APPLE__)\n"
         "/* Apple Silicon kernel page size is 16KB. 16K is a multiple of 4K, so this\n"
         " * value is correct for the x86_64 slice of a universal binary as well. */\n"
         "#define PAGESIZE_TEMP 16384\n"
         "#elif (C_HAVE_MPROTECT)\n"
         "#define PAGESIZE_TEMP PAGESIZE\n"
         "#else\n"
         "#define PAGESIZE_TEMP 4096\n"
         "#endif"),

        # 1d. the allocation itself
        (r"\t\t\t// allocate the code cache memory\n"
         r"#if defined \(WIN32\)\n"
         r"\t\t\tcache_code_start_ptr=\(Bit8u\*\)VirtualAlloc\(0,CACHE_TOTAL\+CACHE_MAXSIZE\+PAGESIZE_TEMP-1\+PAGESIZE_TEMP,\n"
         r"\t\t\t\tMEM_COMMIT,PAGE_EXECUTE_READWRITE\);\n"
         r"\t\t\tif \(!cache_code_start_ptr\)\n"
         r"\t\t\t\tcache_code_start_ptr=\(Bit8u\*\)malloc\(CACHE_TOTAL\+CACHE_MAXSIZE\+PAGESIZE_TEMP-1\+PAGESIZE_TEMP\);\n"
         r"#else\n"
         r"\t\t\tcache_code_start_ptr=\(Bit8u\*\)malloc\(CACHE_TOTAL\+CACHE_MAXSIZE\+PAGESIZE_TEMP-1\+PAGESIZE_TEMP\);\n"
         r"#endif\n"
         r"\t\t\tif\(!cache_code_start_ptr\) E_Exit\(\"Allocating dynamic cache failed\"\);",
         "\t\t\t// allocate the code cache memory\n"
         "#if defined (WIN32)\n"
         "\t\t\tcache_code_start_ptr=(Bit8u*)VirtualAlloc(0,CACHE_TOTAL+CACHE_MAXSIZE+PAGESIZE_TEMP-1+PAGESIZE_TEMP,\n"
         "\t\t\t\tMEM_COMMIT,PAGE_EXECUTE_READWRITE);\n"
         "\t\t\tif (!cache_code_start_ptr)\n"
         "\t\t\t\tcache_code_start_ptr=(Bit8u*)malloc(CACHE_TOTAL+CACHE_MAXSIZE+PAGESIZE_TEMP-1+PAGESIZE_TEMP);\n"
         "#elif defined(__APPLE__)\n"
         "\t\t\t/* macOS: PROT_EXEC cannot be applied to malloc()'d heap memory.\n"
         "\t\t\t * On Apple Silicon, W+X mappings additionally require MAP_JIT and\n"
         "\t\t\t * the kernel page size is 16KB. */\n"
         "\t\t\t{\n"
         "\t\t\t\tint db_mmap_flags = MAP_PRIVATE|MAP_ANON;\n"
         "#if defined(__aarch64__) && defined(MAP_JIT)\n"
         "\t\t\t\tdb_mmap_flags |= MAP_JIT;\n"
         "#endif\n"
         "\t\t\t\tvoid *db_jit_p = mmap(NULL,CACHE_TOTAL+CACHE_MAXSIZE+PAGESIZE_TEMP-1+PAGESIZE_TEMP,\n"
         "\t\t\t\t\tPROT_READ|PROT_WRITE|PROT_EXEC,db_mmap_flags,-1,0);\n"
         "\t\t\t\tcache_code_start_ptr=(db_jit_p==MAP_FAILED)?NULL:(Bit8u*)db_jit_p;\n"
         "\t\t\t}\n"
         "#if defined(__aarch64__)\n"
         "\t\t\t/* allow this thread to write to MAP_JIT memory. This is a no-op\n"
         "\t\t\t * unless the hardened runtime + JIT entitlement are in effect,\n"
         "\t\t\t * but calling it keeps the code correct in both configurations. */\n"
         "\t\t\tpthread_jit_write_protect_np(0);\n"
         "#endif\n"
         "#else\n"
         "\t\t\tcache_code_start_ptr=(Bit8u*)malloc(CACHE_TOTAL+CACHE_MAXSIZE+PAGESIZE_TEMP-1+PAGESIZE_TEMP);\n"
         "#endif\n"
         "\t\t\tif(!cache_code_start_ptr) E_Exit(\"Allocating dynamic cache failed\");"),

        # 1e. skip the now-unnecessary (and on arm64: failing) mprotect on Apple
        (r"#if \(C_HAVE_MPROTECT\)\n"
         r"\t\t\tif\(mprotect\(cache_code_link_blocks,CACHE_TOTAL\+CACHE_MAXSIZE\+PAGESIZE_TEMP,PROT_WRITE\|PROT_READ\|PROT_EXEC\)\)",
         "#if (C_HAVE_MPROTECT) && !defined(__APPLE__)\n"
         "\t\t\tif(mprotect(cache_code_link_blocks,CACHE_TOTAL+CACHE_MAXSIZE+PAGESIZE_TEMP,PROT_WRITE|PROT_READ|PROT_EXEC))"),
    ])

# ---------------------------------------------------------------------------
# Patch 2: configure.ac
#   2a. Enable MT-32 (munt) emulation on aarch64/arm64 -- the x86-only
#       restriction was a 2019-era assumption about slow ARM boards and does
#       not apply to Apple Silicon (the munt core is portable C++).
#   2b. Drop the hardcoded -I/usr/local/include on Darwin so a Homebrew or
#       MacPorts installation on the *build* machine can never leak headers
#       into this build.
# ---------------------------------------------------------------------------

configure_ac = os.path.join(root, "configure.ac")

edit(configure_ac,
    subs=[
        # 2a
        ("    i?86)\n"
         "      AC_MSG_RESULT(yes)\n"
         "      AC_DEFINE(C_MT32,1)\n"
         "      ;;\n"
         "    *)\n"
         "      enable_mt32=no",
         "    i?86)\n"
         "      AC_MSG_RESULT(yes)\n"
         "      AC_DEFINE(C_MT32,1)\n"
         "      ;;\n"
         "    aarch64 | arm64)\n"
         "      AC_MSG_RESULT(yes)\n"
         "      AC_DEFINE(C_MT32,1)\n"
         "      ;;\n"
         "    *)\n"
         "      enable_mt32=no"),
        # 2b
        ("       CFLAGS=\"$CFLAGS -I/usr/local/include\"\n"
         "       CPPFLAGS=\"$CPPFLAGS -I/usr/local/include\"",
         "       dnl (portable build kit) do NOT add -I/usr/local/include here:\n"
         "       dnl it can leak Homebrew headers into what must be a self-contained build.\n"
         "       :"),
    ])

print("All patches applied successfully.")
