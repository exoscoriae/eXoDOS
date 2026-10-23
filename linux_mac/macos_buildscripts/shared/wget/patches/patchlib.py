"""Small helper for anchored, idempotent source patches.

Every patch is an exact-text replacement that must match exactly once in a
pristine tree.  If the replacement text is already present the step is
skipped, so re-running a patcher on an already patched tree is harmless.
Anything else (anchor missing, anchor ambiguous) aborts loudly instead of
silently producing a half-patched tree.
"""

import os
import sys


class PatchError(Exception):
    pass


def _read(path):
    with open(path, "r", encoding="utf-8", newline="") as f:
        return f.read()


def _write(path, text):
    tmp = path + ".patch-tmp"
    with open(tmp, "w", encoding="utf-8", newline="") as f:
        f.write(text)
    os.replace(tmp, path)


def replace_once(path, old, new, label):
    """Replace OLD by NEW exactly once in PATH (idempotent)."""
    text = _read(path)
    if new and new in text:
        print("  [skip] %s: already applied" % label)
        return
    count = text.count(old)
    if count != 1:
        raise PatchError("%s: anchor found %d times in %s (expected 1)" % (label, count, path))
    _write(path, text.replace(old, new, 1))
    print("  [ok]   %s" % label)


def replace_between(path, start, end, new, label, include_end=False):
    """Replace the text from START up to (not including, unless include_end) END."""
    text = _read(path)
    if new in text:
        print("  [skip] %s: already applied" % label)
        return
    if text.count(start) != 1:
        raise PatchError("%s: start anchor found %d times in %s" % (label, text.count(start), path))
    i = text.index(start)
    j = text.find(end, i)
    if j < 0:
        raise PatchError("%s: end anchor not found after start in %s" % (label, path))
    # only the first occurrence of END after START is used
    if include_end:
        j += len(end)
    _write(path, text[:i] + new + text[j:])
    print("  [ok]   %s" % label)


def require(path, needle, label):
    if needle not in _read(path):
        raise PatchError("%s: expected text not found in %s" % (label, path))


def main(apply_fn):
    if len(sys.argv) != 2 or not os.path.isdir(sys.argv[1]):
        sys.stderr.write("usage: %s SOURCE_DIR\n" % sys.argv[0])
        sys.exit(2)
    try:
        apply_fn(os.path.abspath(sys.argv[1]))
    except PatchError as e:
        sys.stderr.write("PATCH FAILED: %s\n" % e)
        sys.exit(1)
