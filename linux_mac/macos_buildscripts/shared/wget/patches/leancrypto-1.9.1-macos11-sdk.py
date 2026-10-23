#!/usr/bin/env python3
"""leancrypto 1.9.1: build against the macOS 11 SDK.

drng/src/seeded_rng_darwin.c includes <sys/random.h> first.  In the macOS
11.x SDKs that header is not self-contained: it uses __OSX_AVAILABLE() from
<Availability.h> and size_t without including either, so the declaration of
getentropy() fails to parse ("expected parameter declarator") and the call
becomes an undeclared function.  Newer SDKs fixed the header.  Including its
prerequisites first is harmless with every SDK.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import patchlib  # noqa: E402

OLD = """#include <sys/random.h>

#include "ext_headers_internal.h"
"""

NEW = """/* <sys/random.h> of the macOS 11 SDK needs these first (patched for the
 * wget2 macOS bundle build) */
#include <sys/types.h>
#include <Availability.h>
#include <sys/random.h>

#include "ext_headers_internal.h"
"""


def apply(src):
    patchlib.replace_once(os.path.join(src, "drng", "src", "seeded_rng_darwin.c"), OLD, NEW,
                          "seeded_rng_darwin.c: <sys/random.h> prerequisites")


if __name__ == "__main__":
    patchlib.main(apply)
