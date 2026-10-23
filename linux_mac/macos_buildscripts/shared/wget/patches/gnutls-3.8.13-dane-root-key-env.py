#!/usr/bin/env python3
"""GnuTLS 3.8.13 libdane: allow the DNSSEC root trust anchor file to be set at run time.

libgnutls-dane reads the DNSSEC root key from UNBOUND_ROOT_KEY_FILE, a path
fixed at configure time.  A relocatable application bundle cannot know that
path in advance, so GNUTLS_DANE_ROOT_KEY_FILE (if set and non-empty) takes
precedence.  The wget2 bundle sets it to
wget.app/Contents/Resources/dnssec/root-anchors.txt when --dane is used.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import patchlib  # noqa: E402


def apply(src):
    dane_c = os.path.join(src, "libdane", "dane.c")
    patchlib.require(dane_c, "#include <stdlib.h>", "stdlib include")
    patchlib.replace_once(
        dane_c,
        "\tif (!(flags & DANE_F_IGNORE_DNSSEC)) {\n"
        "\t\tif (ub_ctx_add_ta_file(ctx, (char *)UNBOUND_ROOT_KEY_FILE) !=\n"
        "\t\t    0) {\n",
        "\tif (!(flags & DANE_F_IGNORE_DNSSEC)) {\n"
        "\t\tconst char *ta_file = getenv(\"GNUTLS_DANE_ROOT_KEY_FILE\");\n"
        "\n"
        "\t\tif (ta_file == NULL || *ta_file == 0)\n"
        "\t\t\tta_file = UNBOUND_ROOT_KEY_FILE;\n"
        "\t\tif (ub_ctx_add_ta_file(ctx, (char *)ta_file) != 0) {\n",
        "GNUTLS_DANE_ROOT_KEY_FILE override",
    )


if __name__ == "__main__":
    patchlib.main(apply)
