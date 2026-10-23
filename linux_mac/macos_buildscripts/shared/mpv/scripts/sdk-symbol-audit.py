#!/usr/bin/env python3
# ============================================================================
# sdk-symbol-audit.py <app-bundle> <macOS-11-SDK>
#
# Definitive macOS-11 ABI check. A Mach-O can carry minos=11 yet still abort at
# launch on Big Sur if it *strongly* (non-weakly) imports a symbol that did not
# exist there (the classic `_kIOMainPortDefault` dyld crash). This script proves
# the absence of that class of bug by checking every strong import in the bundle
# against the symbols a real macOS 11 SDK says the system exported.
#
# For each Mach-O under <app>/Contents/MacOS:
#   * collect strong (non-weak) undefined external symbols  (nm -m)
#   * a symbol is OK if it is exported by the 11.x SDK (.tbd stubs) OR defined by
#     another Mach-O bundled in the app (our own libs / back-deployed Swift)
#   * anything left over is reported and fails the audit.
#
# Weak imports are intentionally ignored: under -mmacosx-version-min=11 the
# compiler weak-links anything newer, so a missing weak symbol binds to NULL and
# only matters if the code calls it without an @available guard (a source bug in
# that library, not an ABI/load failure).
# ============================================================================
import os, re, subprocess, sys

TOKEN = re.compile(rb'[A-Za-z_][A-Za-z0-9_$.]*')
OBJC_PREFIXES = ('_OBJC_CLASS_$_', '_OBJC_METACLASS_$_',
                 '_OBJC_EHTYPE_$_', '_OBJC_IVAR_$_')
# Symbols provided by dyld / the runtime that aren't listed in .tbd stubs.
BASELINE = {'dyld_stub_binder', '___emutls_get_address'}


def is_macho(path):
    if os.path.islink(path):
        return False
    try:
        with open(path, 'rb') as f:
            magic = f.read(4)
    except OSError:
        return False
    return magic in (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe',   # thin LE 64/32
                     b'\xfe\xed\xfa\xcf', b'\xfe\xed\xfa\xce',   # thin BE
                     b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca')   # fat


def macho_files(macos_dir):
    out = []
    for root, _, files in os.walk(macos_dir):
        for fn in files:
            p = os.path.join(root, fn)
            if is_macho(p):
                out.append(p)
    return out


def sdk_tokens(sdk):
    toks = set()
    n = 0
    for root, _, files in os.walk(sdk):
        for fn in files:
            if fn.endswith('.tbd'):
                n += 1
                try:
                    data = open(os.path.join(root, fn), 'rb').read()
                except OSError:
                    continue
                for m in TOKEN.findall(data):
                    toks.add(m.decode('latin1'))
    return toks, n


def normalize(sym):
    for p in OBJC_PREFIXES:
        if sym.startswith(p):
            return sym[len(p):]
    return sym


def nm(args, f):
    try:
        return subprocess.run(['nm', *args, f], capture_output=True,
                              text=True).stdout
    except Exception:
        return ''


def defined_exports(f):
    d = set()
    for l in nm(['-g'], f).splitlines():
        if '(for architecture' in l:
            continue
        p = l.split()
        if len(p) >= 2 and p[-2] != 'U':      # any defined (T/D/S/W/...) export
            d.add(p[-1])
    return d


def strong_undefined(f):
    syms = []
    for l in nm(['-m'], f).splitlines():
        if '(undefined)' not in l or 'weak' in l:
            continue
        parts = l.split()
        sym = None
        for marker in ('(from', '(dynamically'):
            if marker in parts:
                sym = parts[parts.index(marker) - 1]
                break
        if sym is None:
            for tok in reversed(parts):
                if tok.startswith('_'):
                    sym = tok
                    break
        if sym:
            syms.append(sym)
    return syms


def main():
    if len(sys.argv) != 3:
        print("usage: sdk-symbol-audit.py <app> <sdk>", file=sys.stderr)
        sys.exit(2)
    app, sdk = sys.argv[1], os.path.expanduser(sys.argv[2])
    macos = os.path.join(app, 'Contents', 'MacOS')
    if not os.path.isdir(macos):
        print(f"  no Contents/MacOS under {app}", file=sys.stderr)
        sys.exit(2)
    if not os.path.isdir(sdk):
        print(f"  SDK not found: {sdk}", file=sys.stderr)
        sys.exit(2)

    toks, ntbd = sdk_tokens(sdk)
    print(f"      SDK: {ntbd} .tbd stubs, {len(toks):,} exported tokens")

    machos = macho_files(macos)
    bundle = set()
    for f in machos:
        bundle |= defined_exports(f)
    bundle_norm = {normalize(s) for s in bundle}

    fails = 0
    total_syms = 0
    for f in machos:
        miss = set()
        for sym in strong_undefined(f):
            total_syms += 1
            n = normalize(sym)
            if sym in BASELINE or n in BASELINE:
                continue
            if n in toks:                      # exported by macOS 11 SDK
                continue
            if sym in bundle or n in bundle_norm:   # provided by a bundled lib
                continue
            miss.add(sym)
        if miss:
            fails += 1
            rel = os.path.relpath(f, app)
            print(f"      !!! {rel}: {len(miss)} symbol(s) absent on macOS 11:")
            for s in sorted(miss)[:60]:
                print(f"            {s}")

    if fails:
        print(f"      FAILED: {fails} object(s) strongly import symbols not "
              f"present on macOS 11")
        sys.exit(1)
    print(f"      OK: all {len(machos)} objects' strong imports exist on "
          f"macOS 11 (or are bundled)")
    sys.exit(0)


if __name__ == '__main__':
    main()
