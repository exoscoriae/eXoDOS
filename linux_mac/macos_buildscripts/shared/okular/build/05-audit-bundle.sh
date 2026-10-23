#!/usr/bin/env bash
#
# 05-audit-bundle.sh [path-to-app] — prove the bundle is macOS-11-safe & portable.
#
# Checks every Mach-O file inside the .app for:
#   1. Architectures      — must contain BOTH arm64 and x86_64 (universal).
#   2. Deployment target  — LC_BUILD_VERSION / LC_VERSION_MIN_MACOSX must be <= 11.0.
#   3. External linkage   — no references to /opt/homebrew, /usr/local, /opt/local
#                           (Brew/MacPorts), or any absolute path outside the .app.
#                           Only system libs in /usr/lib + /System are allowed.
#   4. rpaths             — no Brew/MacPorts rpaths leaking in.
#
# Exit code is non-zero if any hard failure is found, so it can gate distribution.
# ---------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"

APP="${1:-$DIST_DIR/Okular.app}"
[[ -d "$APP" ]] || die "App not found: $APP"
MAX_MAJOR=11   # nothing may require newer than macOS 11

log "Auditing: $APP"
log "Policy: universal (arm64+x86_64), deployment target <= ${MAX_MAJOR}.x, no Brew/MacPorts, fully bundled."
echo

python3 - "$APP" "$MAX_MAJOR" <<'PY'
import os, re, subprocess, sys
app, max_major = sys.argv[1], int(sys.argv[2])

FORBIDDEN_PREFIXES = ("/opt/homebrew", "/usr/local", "/opt/local", "/Users/", "/tmp/")
ALLOWED_ABS_PREFIXES = ("/usr/lib/", "/System/")   # macOS-provided, present on every Mac

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

arch_fail, deploy_fail, link_fail = [], [], []

def minos_from_loadcmds(path):
    """Highest macOS deployment target (minos) declared across all slices, or None.

    Parse ONLY LC_BUILD_VERSION's 'minos' and LC_VERSION_MIN_MACOSX's 'version'.
    Do NOT scan the whole otool dump for /version/: every dylib also prints
    'current version X.Y.Z' and 'compatibility version X.Y' lines, whose 'version'
    token would otherwise be read as a (bogusly low) deployment target and MASK the
    real minos. Track the current load command and take the MAX (strictest) minos —
    if any slice requires newer than 11, that's a real failure.
    """
    out = subprocess.run(["otool", "-l", path], capture_output=True, text=True).stdout
    best = None
    mode = None
    for line in out.splitlines():
        s = line.strip()
        if s.startswith("cmd "):
            c = s.split()[1] if len(s.split()) > 1 else ""
            mode = {"LC_BUILD_VERSION": "build",
                    "LC_VERSION_MIN_MACOSX": "vmin"}.get(c)
            continue
        if mode == "build":
            m = re.match(r'minos\s+(\d+)\.(\d+)', s)
        elif mode == "vmin":
            m = re.match(r'version\s+(\d+)\.(\d+)', s)
        else:
            m = None
        if m:
            v = (int(m.group(1)), int(m.group(2)))
            best = v if best is None else max(best, v)
            mode = None
    return best

for p in machos:
    rel = os.path.relpath(p, app)
    archs = subprocess.run(["lipo", "-archs", p], capture_output=True, text=True).stdout.split()
    if not ("arm64" in archs and "x86_64" in archs):
        arch_fail.append((rel, " ".join(archs) or "?"))

    minos = minos_from_loadcmds(p)
    if minos and minos[0] > max_major:
        deploy_fail.append((rel, f"{minos[0]}.{minos[1]}"))

    # Linked dylibs / rpaths
    otool = subprocess.run(["otool", "-l", p], capture_output=True, text=True).stdout
    for m in re.finditer(r'(?:name|path)\s+(\S+)\s+\(offset', otool):
        ref = m.group(1)
        if ref.startswith(("@rpath", "@executable_path", "@loader_path")):
            continue
        if ref.startswith(ALLOWED_ABS_PREFIXES):
            continue
        if ref.startswith(FORBIDDEN_PREFIXES) or ref.startswith("/"):
            link_fail.append((rel, ref))

def report(title, rows, fmt):
    print(f"== {title}: {'PASS' if not rows else f'FAIL ({len(rows)})'} ==")
    for r in rows[:40]:
        print("   " + fmt(r))
    if len(rows) > 40:
        print(f"   ... and {len(rows)-40} more")
    print()

report("Universal (arm64+x86_64)", arch_fail, lambda r: f"{r[0]:60s} archs: {r[1]}")
report(f"Deployment target <= {max_major}.x", deploy_fail, lambda r: f"{r[0]:60s} minos: {r[1]}")
report("No external / Brew / MacPorts linkage", link_fail, lambda r: f"{r[0]:50s} -> {r[1]}")

hard = len(arch_fail) + len(deploy_fail) + len(link_fail)
if hard == 0:
    print("RESULT: PASS — universal, macOS 11-safe, fully self-contained.")
    sys.exit(0)
else:
    print(f"RESULT: FAIL — {hard} issue(s). See above. Do not distribute until resolved.")
    sys.exit(1)
PY
rc=$?

echo
log "Codesign validity:"
/usr/bin/codesign -vv --deep "$APP" 2>&1 | sed 's/^/   /' || true

exit $rc
