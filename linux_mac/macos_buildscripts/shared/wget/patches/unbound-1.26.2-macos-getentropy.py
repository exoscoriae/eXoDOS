#!/usr/bin/env python3
"""unbound 1.26.2: declare getentropy() on macOS when built with nettle.

util/random.c's libnettle branch calls getentropy(), but on macOS (which has
arc4random) configure never checks for getentropy and config.h declares no
prototype.  The function is declared in <sys/random.h> (macOS 10.12+), which
random.c does not include, so current Apple clang stops with "call to
undeclared function 'getentropy'".  Still present upstream (master,
October 2026).
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import patchlib  # noqa: E402

OLD = """#elif defined(HAVE_NETTLE)
#include "yarrow.h"
#endif
"""

NEW = """#elif defined(HAVE_NETTLE)
#include "yarrow.h"
#ifdef __APPLE__
/* getentropy() is declared here (macOS 10.12+); config.h only declares it
 * when arc4random() is missing (patched for the wget2 macOS bundle build) */
#include <sys/types.h>
#include <sys/random.h>
#endif
#endif
"""


def apply(src):
    patchlib.replace_once(os.path.join(src, "util", "random.c"), OLD, NEW,
                          "random.c: getentropy() prototype on macOS")


if __name__ == "__main__":
    patchlib.main(apply)
