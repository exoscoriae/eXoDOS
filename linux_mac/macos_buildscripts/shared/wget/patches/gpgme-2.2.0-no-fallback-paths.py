#!/usr/bin/env python3
"""gpgme 2.2.0: no hard-coded Homebrew/MacGPG2 search paths on macOS.

When gpgconf or gpg is not found in PATH, gpgme on Apple falls back to
/usr/local/bin, /usr/local/MacGPG2/bin and /opt/homebrew/bin.  wget.app
always uses its own GnuPG (it is put first in PATH and set as the engine);
with WGET_GNUPG=system, PATH alone decides.  The fallback could only ever
pick up a Homebrew or GPG Suite installation behind the user's back, so it
is removed.  Search order is otherwise unchanged.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import patchlib  # noqa: E402

OLD = """#ifdef __APPLE__
  /* On apple, especially when started through gpgme-json via
     the browser interface we should look into some additional
     fallback paths. */
"""

NEW = """#if 0 /* wget2 macOS bundle: never fall back to Homebrew or MacGPG2 */
  /* On apple, especially when started through gpgme-json via
     the browser interface we should look into some additional
     fallback paths. */
"""


def apply(src):
    patchlib.replace_once(os.path.join(src, "src", "posix-util.c"), OLD, NEW,
                          "posix-util.c: no Homebrew/MacGPG2 fallback paths")


if __name__ == "__main__":
    patchlib.main(apply)
