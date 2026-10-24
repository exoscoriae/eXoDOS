#!/usr/bin/env python3
"""
Apple Silicon W^X fix for the DOSBox-X 0.82.20 dynrec core.

On arm64 macOS, MAP_JIT memory is per-thread EITHER writable OR executable
(pthread_jit_write_protect_np switches the mode). The initial kit patch left
the emulation thread permanently in WRITE mode, so the first attempt to
EXECUTE a generated block raised SIGBUS (observed: crash the moment a game
enters protected mode and the dynamic core kicks in; fine under Rosetta).

Fix: leave JIT pages executable by default; enable write only while the
recompiler is emitting code:
  - cache_openblock()  -> write mode   (start of block generation)
  - dyn_closeblock()   -> exec mode    (after the icache flush)
  - cache_init()       -> exec mode    (after the startup stubs are written)

Idempotent: skips if the marker is already present.
Run against a *prepared* tree (kit patch 1 must already be applied).

Usage: python3 apply_wx_fix.py /path/to/tree   -> prints CHANGED or UNCHANGED
"""

import os
import sys

def die(msg):
    sys.stderr.write("WX PATCH FAILED: %s\n" % msg)
    sys.exit(1)

def edit(path, subs):
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
        text = f.read()
    for old, new in subs:
        n = text.count(old)
        if n != 1:
            die("expected exactly 1 occurrence in %s, found %d:\n---\n%s\n---" % (path, n, old))
        text = text.replace(old, new)
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(text)
    print("patched: %s" % path, file=sys.stderr)

root = sys.argv[1] if len(sys.argv) > 1 else "."
cache_h = os.path.join(root, "src/cpu/core_dynrec/cache.h")
decoder_basic_h = os.path.join(root, "src/cpu/core_dynrec/decoder_basic.h")

for p in (cache_h, decoder_basic_h):
    if not os.path.isfile(p):
        die("file not found: %s" % p)

with open(cache_h, "r", encoding="utf-8", errors="surrogateescape") as f:
    content = f.read()

if "dosbox_jit_write_enable" in content:
    print("UNCHANGED")
    sys.exit(0)

if "sys_icache_invalidate" not in content:
    die("cache.h does not look prepared (kit patch 1 missing?)")

# 1. helpers, right before the forward declaration (after the __APPLE__ includes)
edit(cache_h, [(
    "class CodePageHandlerDynRec;\t// forward",

    "#if defined(__APPLE__) && defined(__aarch64__)\n"
    "/* Apple Silicon W^X: a thread has either WRITE or EXECUTE access to\n"
    " * MAP_JIT memory, toggled per-thread. Default to executable; enable\n"
    " * write only while the recompiler is emitting code. */\n"
    "static INLINE void dosbox_jit_write_enable(void) { pthread_jit_write_protect_np(0); }\n"
    "static INLINE void dosbox_jit_exec_enable(void)  { pthread_jit_write_protect_np(1); }\n"
    "#else\n"
    "static INLINE void dosbox_jit_write_enable(void) { }\n"
    "static INLINE void dosbox_jit_exec_enable(void)  { }\n"
    "#endif\n"
    "\n"
    "class CodePageHandlerDynRec;\t// forward"
)])

# 2. write mode at the start of block generation
edit(cache_h, [(
    "static CacheBlockDynRec * cache_openblock(void) {\n"
    "\tCacheBlockDynRec * block=cache.block.active;",

    "static CacheBlockDynRec * cache_openblock(void) {\n"
    "\tdosbox_jit_write_enable();\n"
    "\tCacheBlockDynRec * block=cache.block.active;"
)])

# 3. exec mode once the startup stubs are written+flushed (cache_init)
edit(cache_h, [(
    "\t\tsys_icache_invalidate(cache_code_link_blocks, PAGESIZE_TEMP);\n"
    "#endif",

    "\t\tsys_icache_invalidate(cache_code_link_blocks, PAGESIZE_TEMP);\n"
    "#endif\n"
    "\t\tdosbox_jit_exec_enable();"
)])

# 4. exec mode after a block is closed+flushed (before it can be executed)
edit(decoder_basic_h, [(
    "\tdyn_fill_blocks();\n"
    "\tcache_block_before_close();\n"
    "\tcache_closeblock();\n"
    "\tcache_block_closing(decode.block->cache.start,decode.block->cache.size);\n"
    "}",

    "\tdyn_fill_blocks();\n"
    "\tcache_block_before_close();\n"
    "\tcache_closeblock();\n"
    "\tcache_block_closing(decode.block->cache.start,decode.block->cache.size);\n"
    "\tdosbox_jit_exec_enable();\n"
    "}"
)])

print("CHANGED")
