#!/usr/bin/env bash
#
# 06-symbol-availability.sh [path-to-app] — the check 05 CANNOT do: prove no
# bundled Mach-O imports a SYSTEM symbol that postdates macOS 11.
#
# Why this exists
# ---------------
# 05 verifies the DECLARED deployment target (minos<=11), the architectures, the
# linkage, and the signature. None of that proves runtime symbol availability.
# Everything in this bundle was compiled on a newer macOS against a newer SDK.
# Building with -mmacosx-version-min=11.0 is Apple's supported back-deploy path,
# but it only protects APIs the SOURCE guards with @available. If any dependency
# UNCONDITIONALLY calls a symbol introduced after 11.0, the binary links fine on
# the build host, passes 05, then fails to bind at launch on a real macOS 11 box
# (strong import of an absent symbol => dyld aborts the process).
#
# Method
# ------
# A strong undefined symbol is safe on macOS 11 iff it is satisfied by either
#   (a) the macOS 11 SDK's exported symbols, or
#   (b) a library bundled INSIDE the .app.
# So we:
#   1. build the symbol set the macOS 11 SDK declares (from its .tbd stubs),
#   2. build the symbol set every bundled Mach-O EXPORTS (defined globals),
#   3. for every bundled Mach-O, list STRONG (non-weak) undefined imports and
#      flag any name in NEITHER set.
# Weak-imported symbols are skipped: dyld tolerates their absence and the code is
# expected to @available-guard them.
#
# Requirements
# ------------
# Needs a macOS 11.x SDK to compare against (the build host only ships the current
# SDK). Point MACOS11_SDK at a MacOSX11.*.sdk directory — copied from an older
# Xcode that still bundled it, or any extracted 11.x SDK. The script also probes
# the usual SDK locations. Without an 11 SDK it cannot do the per-symbol check and
# instead lists the system libraries the bundle links, for a manual eyeball.
#
# This is a STANDALONE post-audit step (not part of build-all): it is read-only,
# needs no rebuild, and depends on an external SDK. Run it after 05 passes.
# ---------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"

APP="${1:-$DIST_DIR/Okular.app}"
[[ -d "$APP" ]] || die "App not found: $APP"

# --- Locate a macOS 11 SDK ----------------------------------------------------
SDK="${MACOS11_SDK:-}"
if [[ -z "$SDK" ]]; then
  for c in \
    /Library/Developer/CommandLineTools/SDKs/MacOSX11*.sdk \
    /Applications/Xcode*.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX11*.sdk \
    "$HOME"/SDKs/MacOSX11*.sdk \
    "$HOME"/Downloads/MacOSX11*.sdk; do
    [[ -d "$c" ]] && { SDK="$c"; break; }
  done
fi

log "Auditing symbol availability for: $APP"
if [[ -n "$SDK" ]]; then
  log "macOS 11 SDK: $SDK"
else
  warn "No macOS 11 SDK found. Set MACOS11_SDK=/path/to/MacOSX11.x.sdk for the real per-symbol check."
fi
echo

python3 - "$APP" "${SDK:-}" <<'PY'
import os, re, subprocess, sys

app = sys.argv[1]
sdk = sys.argv[2] if len(sys.argv) > 2 else ""

def is_macho(path):
    if os.path.islink(path) or not os.path.isfile(path):
        return False
    try:
        with open(path, "rb") as f: magic = f.read(4)
    except OSError:
        return False
    return magic in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe",
                     b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce",
                     b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca")

machos = []
for dp, _, files in os.walk(app):
    for n in files:
        p = os.path.join(dp, n)
        if is_macho(p): machos.append(p)
print(f"Found {len(machos)} Mach-O files.\n")

_arch_cache = {}
def archs(path):
    if path not in _arch_cache:
        r = subprocess.run(["lipo", "-archs", path], capture_output=True, text=True)
        _arch_cache[path] = r.stdout.split() if r.returncode == 0 else []
    return _arch_cache[path] or [None]

# --- (1) symbols every bundled library EXPORTS (defined globals) --------------
def defined_globals(path):
    syms = set()
    for a in archs(path):
        cmd = ["nm", "-g"] + (["-arch", a] if a else []) + [path]
        out = subprocess.run(cmd, capture_output=True, text=True).stdout
        for line in out.splitlines():
            parts = line.split()
            if not parts:
                continue
            # undefined entries: "U _sym" or "<addr> U _sym" -> skip
            if parts[0] == "U" or (len(parts) >= 2 and parts[1] == "U"):
                continue
            sym = parts[-1]
            if sym.startswith("_"):
                syms.add(sym)
    return syms

print("Indexing symbols exported by bundled libraries ...")
bundled = set()
for p in machos:
    bundled |= defined_globals(p)
print(f"  {len(bundled)} distinct bundled-exported symbols.\n")

# --- (2) symbols the macOS 11 SDK declares (from .tbd stubs) ------------------
def parse_tbd(text):
    syms = set()
    # Plain + weak symbols: in .tbd these are underscore-prefixed tokens. Harvest
    # every such token globally — .tbd metadata (targets, install-name, versions,
    # umbrellas, clients) is NOT underscore-prefixed, so this is a clean proxy and
    # is robust to flow ([ ... ]) vs block (- item) YAML styles.
    syms.update(re.findall(r'_[A-Za-z0-9_$.]+', text))
    # objc-classes / objc-ivars are listed as BARE names but imported as runtime
    # symbols, so expand them. Capture both flow and block list bodies for the key.
    # NB: a class listed under objc-classes also implies its exception type-info
    # symbol _OBJC_EHTYPE_$_<Class> (used by @catch). .tbd stubs frequently omit
    # that derived symbol even though the runtime provides it whenever the class
    # exists, so synthesize it here — otherwise long-standing system classes like
    # NSException are wrongly flagged as "newer than macOS 11".
    for key, prefixes in (("objc-classes", ("_OBJC_CLASS_$_", "_OBJC_METACLASS_$_", "_OBJC_EHTYPE_$_")),
                          ("objc-ivars",   ("_OBJC_IVAR_$_",))):
        for m in re.finditer(re.escape(key) + r'\s*:\s*\[(.*?)\]', text, re.S):
            for t in re.split(r'[,\s]+', m.group(1)):
                t = t.strip().strip("'\"")
                if t:
                    for pre in prefixes:
                        syms.add(pre + t)
        # block form: "<key>:\n   - Name\n   - Name2"
        bm = re.search(re.escape(key) + r'\s*:\s*\n((?:\s*-\s*\S+\s*\n)+)', text)
        if bm:
            for t in re.findall(r'-\s*(\S+)', bm.group(1)):
                t = t.strip().strip("'\"")
                if t:
                    for pre in prefixes:
                        syms.add(pre + t)
    return syms

sdk_syms = set()
if sdk and os.path.isdir(sdk):
    print("Indexing macOS 11 SDK symbols (.tbd stubs) ...")
    n_tbd = 0
    for dp, _, files in os.walk(sdk):
        for n in files:
            if n.endswith(".tbd"):
                n_tbd += 1
                try:
                    with open(os.path.join(dp, n), "r", errors="ignore") as f:
                        sdk_syms |= parse_tbd(f.read())
                except OSError:
                    pass
    print(f"  {n_tbd} .tbd files, {len(sdk_syms)} distinct SDK symbols.\n")

# --- Fallback when no SDK: list referenced system libraries -------------------
if not sdk_syms:
    libs = set()
    for p in machos:
        out = subprocess.run(["otool", "-L", p], capture_output=True, text=True).stdout
        for line in out.splitlines()[1:]:
            ref = line.strip().split(" ")[0]
            if ref.startswith(("/usr/lib", "/System")):
                libs.add(ref)
    print("No macOS 11 SDK available -> cannot verify per-symbol availability.")
    print("Distinct SYSTEM libraries the bundle links (eyeball for any that did not")
    print("exist on macOS 11):\n")
    for l in sorted(libs):
        print("   " + l)
    print("\nProvide MACOS11_SDK=/path/to/MacOSX11.x.sdk and re-run for the real check.")
    sys.exit(2)

# --- (3) strong undefined imports, flag those satisfied by neither set --------
def strong_undefined(path):
    found = set()
    for a in archs(path):
        cmd = ["nm", "-m", "-u"] + (["-arch", a] if a else []) + [path]
        out = subprocess.run(cmd, capture_output=True, text=True).stdout
        for line in out.splitlines():
            if "(undefined)" not in line:
                continue
            if "weak" in line:          # weak import -> dyld tolerates absence
                continue
            m = re.search(r'(_[A-Za-z0-9_$.]+)', line)
            if m:
                found.add(m.group(1))
    return found

print("Scanning strong undefined imports against (SDK 11 + bundled) ...\n")
allowed = sdk_syms | bundled
missing = {}
for p in machos:
    for sym in strong_undefined(p):
        if sym in allowed:
            continue
        missing.setdefault(os.path.relpath(p, app), set()).add(sym)

total = sum(len(v) for v in missing.values())
print(f"== System symbols absent from macOS 11 SDK and not bundled: "
      f"{'PASS' if total == 0 else f'FAIL ({total})'} ==\n")
for rel in sorted(missing):
    print(f"   {rel}")
    for s in sorted(missing[rel])[:30]:
        print(f"        {s}")
    if len(missing[rel]) > 30:
        print(f"        ... and {len(missing[rel]) - 30} more")

if total == 0:
    print("RESULT: PASS — no bundled binary imports a system symbol newer than macOS 11.")
    sys.exit(0)

print()
print("These are CANDIDATES: strong undefined symbols found in NEITHER the macOS 11")
print("SDK stubs NOR any bundled library. Some may be false positives (a private or")
print("re-exported symbol the .tbd scan didn't list). Investigate each: a genuinely")
print("newer-than-11 system symbol means a guaranteed crash on macOS 11; a bundled-")
print("but-missing symbol means a real bundling gap. Do not dismiss without checking.")
sys.exit(1)
PY
rc=$?
echo
exit $rc
