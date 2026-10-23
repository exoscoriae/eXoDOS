#!/usr/bin/env python3
"""libgcrypt 1.12.4: AArch64 assembly on macOS.

libgcrypt 1.12.3 (commit 9b684f4a, straight-line speculation hardening)
made CFI_ENDPROC() expand to "dsb sy; isb; .cfi_endproc".  Darwin's AArch64
assembler takes ';' as a comment character ('%%' separates statements), so
everything after the first ';' is silently dropped -- including
.cfi_endproc -- and every mpi/aarch64 file fails with "Unfinished frame!".
Upstream fixed this after 1.12.4 (commit 2175f33) with an assembler wrapper
and configure changes.  This patch instead gives the affected macros
Darwin's statement separator, on Apple only; the generated code is the same
as on other platforms (barrier after each return, proper unwind info).
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import patchlib  # noqa: E402

OLD = """/* 'ret' instruction replacement for straight-line speculation mitigation */
#define ret_spec_stop \\
	ret; SPEC_STOP;
"""

NEW = """/* 'ret' instruction replacement for straight-line speculation mitigation */
#define ret_spec_stop \\
	ret; SPEC_STOP;

#ifdef __APPLE__
/* Darwin's AArch64 assembler takes ';' as a comment character and '%%' as
 * the statement separator: everything after the first ';' of the macros
 * above would be dropped, '.cfi_endproc' included ("Unfinished frame!").
 * (patched for the wget2 macOS bundle build; fixed upstream after 1.12.4) */
# undef SPEC_STOP
# define SPEC_STOP dsb sy %% isb
# undef CFI_ENDPROC
# ifdef HAVE_GCC_ASM_CFI_DIRECTIVES
#  define CFI_ENDPROC() SPEC_STOP %% .cfi_endproc
# else
#  define CFI_ENDPROC() SPEC_STOP
# endif
# undef ret_spec_stop
# define ret_spec_stop ret %% SPEC_STOP
#endif
"""


def apply(src):
    patchlib.replace_once(os.path.join(src, "cipher", "asm-common-aarch64.h"), OLD, NEW,
                          "asm-common-aarch64.h: Darwin statement separators")


if __name__ == "__main__":
    patchlib.main(apply)
