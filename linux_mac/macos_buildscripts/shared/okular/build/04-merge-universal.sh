#!/usr/bin/env bash
#
# 04-merge-universal.sh — package each architecture into a self-contained app,
# then fuse them into ONE universal Okular.app with lipo.
#
# Steps:
#   1. `craft --package` each root -> a self-contained Okular.app (libs bundled
#      by macdeployqt) of that single architecture.
#   2. Copy the arm64 app as the universal base.
#   3. For every Mach-O file, lipo-create the arm64 + x86_64 slices in place.
#   4. Re-sign ad-hoc (lipo invalidates the existing signature).
#   5. Optionally roll a .dmg.
#
# The result has BOTH architectures and all libraries bundled inside the .app —
# no Brew, no MacPorts, no external dylibs.
# ---------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"

STAGE="$DIST_DIR/_stage"
APP_NAME="okular.app"
UNIVERSAL_APP="$DIST_DIR/Okular.app"

mkdir -p "$DIST_DIR" "$STAGE"

run_craft() {
  local root="$1"; shift
  ( set +u; scrub_brew_env; source "$root/craft/craftenv.sh"; craft "$@" )
}

# --- 1. Package each arch and extract its .app into the staging area ----------
extract_app_for() {
  local arch="$1" root dmg mnt out
  root="$(craft_root_for "$arch")"
  out="$STAGE/$arch"
  rm -rf "$out"; mkdir -p "$out"

  log "[$arch] Packaging self-contained app (macdeployqt bundles the libs)"
  # NOTE: do NOT die on nonzero exit. `craft --package` runs macdeployqt (which
  # produces the bundled archive app we actually use) and THEN an optional
  # dmgbuild step that rolls a .dmg into CraftRoot/tmp. That dmgbuild step can
  # fail on its own ("KShim: the child process was terminated") without affecting
  # the archive app — and we don't use that .dmg anyway (04 builds its own dmg in
  # step 5 if MAKE_DMG=1). So warn and proceed; the archive-app check below is the
  # real gate.
  run_craft "$root" --package "$OKULAR_BLUEPRINT" \
    || warn "[$arch] 'craft --package' returned nonzero (usually just the optional dmgbuild step). Proceeding to use the macdeployqt archive app."

  # CRITICAL: use the macdeployqt-BUNDLED app, not the install-tree app.
  # `craft --package` runs macdeployqt and writes the self-contained app (libs
  # copied into Contents/Frameworks + Contents/PlugIns, install names rewritten
  # to @rpath) under the blueprint's build/.../archive/ dir. The install tree at
  # $root/Applications/KDE/okular.app is NOT bundled — its okular binary still
  # links …/CraftRoot/lib/libKF6*.dylib by absolute path. Picking that one was
  # the cause of the audit's "external linkage" FAIL and the near-empty lipo walk.
  local archive_app="$root/build/$OKULAR_BLUEPRINT/archive/Applications/KDE/$APP_NAME"
  if [[ -d "$archive_app/Contents/Frameworks" ]]; then
    log "[$arch] Using macdeployqt-bundled archive app: $archive_app"
    /usr/bin/ditto "$archive_app" "$out/$APP_NAME"
    return
  fi
  warn "[$arch] bundled archive app not found (or has no Frameworks/) at $archive_app; falling back to the packaged .dmg"

  dmg="$(/usr/bin/find "$root/tmp" -maxdepth 2 -name '*.dmg' -type f 2>/dev/null | sort | tail -n1 || true)"
  [[ -n "$dmg" ]] || die "[$arch] No packaged .app or .dmg found under $root/tmp."
  log "[$arch] Mounting $dmg"
  mnt="$(/usr/bin/hdiutil attach "$dmg" -nobrowse -readonly | grep -o '/Volumes/.*' | head -n1)"
  [[ -n "$mnt" ]] || die "[$arch] Failed to mount $dmg"
  /usr/bin/ditto "$mnt/$APP_NAME" "$out/$APP_NAME" || { /usr/bin/hdiutil detach "$mnt" -quiet; die "[$arch] copy from dmg failed"; }
  /usr/bin/hdiutil detach "$mnt" -quiet
}

for arch in "${ARCHES[@]}"; do
  extract_app_for "$arch"
done

ARM_APP="$STAGE/arm64/$APP_NAME"
X86_APP="$STAGE/x86_64/$APP_NAME"
[[ -d "$ARM_APP" ]] || die "Missing arm64 app at $ARM_APP"
[[ -d "$X86_APP" ]] || die "Missing x86_64 app at $X86_APP"

# --- 1b. Guarantee the stub AGL.framework is bundled --------------------------
# QtGui links @rpath/AGL.framework (empty stub from 02e). macdeployqt usually
# copies it, but ensure it's present in each arch app so the lipo step fuses it.
ensure_agl() {
  local app="$1" arch="$2" root fwdst fwsrc
  root="$(craft_root_for "$arch")"
  fwsrc="$root/lib/AGL.framework"
  fwdst="$app/Contents/Frameworks/AGL.framework"
  if [[ ! -e "$fwdst" && -e "$fwsrc" ]]; then
    mkdir -p "$app/Contents/Frameworks"
    /usr/bin/ditto "$fwsrc" "$fwdst"
    log "  injected AGL.framework into $arch app"
  fi
}
ensure_agl "$ARM_APP" arm64
ensure_agl "$X86_APP" x86_64

# --- 2. Base the universal app on the arm64 layout ----------------------------
log "Creating universal base from arm64 app"
rm -rf "$UNIVERSAL_APP"
/usr/bin/ditto "$ARM_APP" "$UNIVERSAL_APP"

# --- 3. lipo every Mach-O file ------------------------------------------------
log "Fusing Mach-O files (lipo arm64 + x86_64)"
python3 - "$UNIVERSAL_APP" "$X86_APP" <<'PY'
import os, subprocess, sys
uni, x86 = sys.argv[1], sys.argv[2]

def is_macho(path):
    if os.path.islink(path) or not os.path.isfile(path):
        return False
    try:
        with open(path, "rb") as f:
            magic = f.read(4)
    except OSError:
        return False
    # Mach-O (thin LE/BE) or already-fat
    return magic in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe",
                     b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce",
                     b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca")

fused = missing = skipped = 0
for dirpath, _, files in os.walk(uni):
    for name in files:
        upath = os.path.join(dirpath, name)
        if not is_macho(upath):
            continue
        rel = os.path.relpath(upath, uni)
        xpath = os.path.join(x86, rel)
        if not os.path.isfile(xpath):
            print(f"  [missing x86_64] {rel}")
            missing += 1
            continue
        # If the universal file already contains x86_64, skip.
        info = subprocess.run(["lipo", "-archs", upath], capture_output=True, text=True)
        if "x86_64" in info.stdout.split():
            skipped += 1
            continue
        r = subprocess.run(["lipo", "-create", upath, xpath, "-output", upath],
                           capture_output=True, text=True)
        if r.returncode != 0:
            print(f"  [lipo FAILED] {rel}: {r.stderr.strip()}")
            missing += 1
        else:
            fused += 1
print(f"\nFused: {fused}   already-universal: {skipped}   problems: {missing}")
if missing:
    print("Some files lack an x86_64 counterpart or failed to fuse. The app may "
          "still run on arm64 but is NOT fully universal. Review the lines above.")
PY

# --- 3b. Scrub stray build-tree LC_RPATHs -------------------------------------
# Some libs (ffmpeg's libav*, webp's libwebp*) are compiled with an absolute
# LC_RPATH into their CraftRoot build tree (…/CraftRoot-<arch>/lib or
# …/build/libs/webp/work/build). macdeployqt rewrites the real dependencies to
# @rpath/… but does NOT delete these leftover absolute rpaths, so 05 flags them
# as external linkage. They're dead paths on a fresh Mac — the actual deps still
# resolve through the main executable's @executable_path/../Frameworks rpath.
# Delete every absolute rpath that isn't a system location, and add @loader_path/.
# so each lib can always resolve its siblings in Contents/Frameworks directly.
# Generic by design: catches any similarly-tainted lib, not just ffmpeg/webp.
log "Scrubbing stray build-tree rpaths from bundled Mach-O files"
python3 - "$UNIVERSAL_APP" <<'PY'
import os, re, subprocess, sys, tempfile
app = sys.argv[1]

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

def archs_of(path):
    r = subprocess.run(["lipo", "-archs", path], capture_output=True, text=True)
    return r.stdout.split() if r.returncode == 0 else []

def rpaths(path):
    out = subprocess.run(["otool", "-l", path], capture_output=True, text=True).stdout
    return re.findall(r'(?m)^\s*path\s+(.+?)\s+\(offset', out)

def is_bad(r):
    return r.startswith("/") and not r.startswith(("/usr/lib", "/System"))

def scrub_thin(path):
    """Delete stray rpaths and ensure @loader_path/. on a single-arch Mach-O."""
    rps = rpaths(path)
    if "@loader_path/." not in rps:
        subprocess.run(["install_name_tool", "-add_rpath", "@loader_path/.", path],
                       capture_output=True)
    for r in set(rps):
        if is_bad(r):
            subprocess.run(["install_name_tool", "-delete_rpath", r, path],
                           capture_output=True)

# A fused binary carries a SEPARATE rpath per slice (…/CraftRoot-arm64/lib in the
# arm64 slice, …/CraftRoot-x86_64/lib in the x86_64 slice). install_name_tool
# -delete_rpath applies to EVERY slice at once and fails the whole op if any slice
# lacks that exact path — so deleting on the fat file is a silent no-op. The robust
# fix: thin each arch, scrub its own rpaths, then re-fuse with lipo.
scrubbed = 0
for dp, _, files in os.walk(app):
    for n in files:
        p = os.path.join(dp, n)
        if os.path.islink(p) or not is_macho(p):
            continue
        if not any(is_bad(r) for r in rpaths(p)):
            continue
        archs = archs_of(p)
        if len(archs) <= 1:
            scrub_thin(p)
            scrubbed += 1
            continue
        tmpd = tempfile.mkdtemp()
        thins, ok = [], True
        for a in archs:
            t = os.path.join(tmpd, a)
            r = subprocess.run(["lipo", p, "-thin", a, "-output", t],
                               capture_output=True, text=True)
            if r.returncode != 0:
                print(f"  [thin FAILED] {os.path.relpath(p, app)} {a}: {r.stderr.strip()}")
                ok = False
                break
            scrub_thin(t)
            thins.append(t)
        if ok:
            subprocess.run(["lipo", "-create", *thins, "-output", p], capture_output=True)
            scrubbed += 1
        for t in thins:
            try: os.remove(t)
            except OSError: pass
        try: os.rmdir(tmpd)
        except OSError: pass
print(f"Scrubbed stray rpaths in {scrubbed} file(s).")
PY

# --- 3c. Retarget any minos>11 Mach-O down to 11.0 ----------------------------
# Some bundled libs (low-level C libs Craft pulled from its macOS-13 binary cache:
# icu/openssl/gettext/libffi/sqlite/expat/zlib/liblzma/libunistring/libb2/libbzip2/
# libxml2) declare LC_BUILD_VERSION minos 13.0 even though their compiled code uses
# only long-standing libSystem symbols. Rewrite the label to 11.0 so the SHIPPED
# bundle is uniformly macOS-11-targeted. We fix it HERE (on the final universal
# app) rather than in CraftRoot because this is exactly what 05 audits and what the
# user runs — independent of where the lib originally came from. A fat file carries
# a SEPARATE build-version per slice, so thin -> vtool -> re-fuse (same shape as 3b).
# 06-symbol-availability.sh proves none of these import a symbol newer than macOS
# 11, which is what makes relabelling legitimate rather than cosmetic.
log "Retargeting any minos>11 Mach-O in the bundle to 11.0 (vtool)"
python3 - "$UNIVERSAL_APP" <<'PY'
import os, re, subprocess, sys, tempfile
app = sys.argv[1]

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

def archs_of(path):
    r = subprocess.run(["lipo", "-archs", path], capture_output=True, text=True)
    return r.stdout.split() if r.returncode == 0 else []

def minos(path):
    out = subprocess.run(["otool", "-l", path], capture_output=True, text=True).stdout
    best, mode = None, None
    for line in out.splitlines():
        s = line.strip()
        if s.startswith("cmd "):
            c = s.split()[1] if len(s.split()) > 1 else ""
            mode = {"LC_BUILD_VERSION": "b", "LC_VERSION_MIN_MACOSX": "v"}.get(c)
            continue
        m = re.match(r'minos\s+(\d+)\.(\d+)', s) if mode == "b" else \
            (re.match(r'version\s+(\d+)\.(\d+)', s) if mode == "v" else None)
        if m:
            v = (int(m.group(1)), int(m.group(2)))
            best = v if best is None else max(best, v)
            mode = None
    return best

def retarget_thin(path):
    tmp = path + ".vt"
    r = subprocess.run(["vtool", "-set-build-version", "macos", "11.0", "11.0",
                        "-replace", "-output", tmp, path],
                       capture_output=True, text=True)
    if r.returncode == 0 and os.path.exists(tmp):
        os.replace(tmp, path)
        return True
    if os.path.exists(tmp):
        os.remove(tmp)
    return False

done = problems = 0
for dp, _, files in os.walk(app):
    if ".dSYM" in dp:            # debug containers — not loadable, never retarget
        continue
    for n in files:
        p = os.path.join(dp, n)
        if os.path.islink(p) or not is_macho(p):
            continue
        mo = minos(p)
        if not (mo and mo[0] > 11):
            continue
        rel = os.path.relpath(p, app)
        archs = archs_of(p)
        if len(archs) <= 1:
            if retarget_thin(p):
                done += 1
            else:
                problems += 1
                print(f"  [vtool FAILED] {rel}")
            continue
        tmpd = tempfile.mkdtemp()
        thins, ok = [], True
        for a in archs:
            t = os.path.join(tmpd, a)
            r = subprocess.run(["lipo", p, "-thin", a, "-output", t],
                               capture_output=True, text=True)
            if r.returncode != 0:
                print(f"  [thin FAILED] {rel} {a}: {r.stderr.strip()}")
                ok = False
                break
            retarget_thin(t)
            thins.append(t)
        if ok:
            subprocess.run(["lipo", "-create", *thins, "-output", p], capture_output=True)
            done += 1
        else:
            problems += 1
        for t in thins:
            try: os.remove(t)
            except OSError: pass
        try: os.rmdir(tmpd)
        except OSError: pass
print(f"Retargeted {done} Mach-O to minos 11.0   problems: {problems}")
PY

# --- 3d. Drop unused ICU tool/test libs (libicutu, libicutest) ----------------
# ICU's data-tools util (libicutu) and unit-test framework (libicutest) are
# DEV-ONLY libs. Okular links libicuuc/libicui18n/libicudata — never these two —
# but macdeployqt sweeps them in anyway. They also import libc++ fstream symbols
# (std::__1::basic_ofstream/ifstream/filebuf …) that do NOT exist in macOS 11's
# libc++, so 06 (correctly) flags them. Since nothing in the bundle loads them,
# remove them: it deletes the only macOS-11-incompatible code and shrinks the app.
# Self-guarding: a target is removed ONLY if nothing OUTSIDE the target set still
# links it (referrers that are themselves being removed don't count — the two form
# a closed island), so this can never create a dangling dependency.
log "Dropping unused ICU tool/test libs (libicutu, libicutest) if unreferenced"
python3 - "$UNIVERSAL_APP" <<'PY'
import os, re, subprocess, sys
app = sys.argv[1]
targets = ("libicutu", "libicutest")

def is_macho(p):
    if os.path.islink(p) or not os.path.isfile(p): return False
    try:
        with open(p, "rb") as f: m = f.read(4)
    except OSError: return False
    return m in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf",
                 b"\xfe\xed\xfa\xce", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca")

def load_refs(p):
    out = subprocess.run(["otool", "-L", p], capture_output=True, text=True).stdout.splitlines()
    return [m.group(1) for line in out[1:]
            for m in [re.match(r'\s+(\S+)\s+\(', line)] if m]

# A referrer counts as "external" only if it is NOT itself one of the targets.
external = {t: [] for t in targets}
for dp, _, files in os.walk(app):
    for n in files:
        p = os.path.join(dp, n)
        if os.path.islink(p) or not is_macho(p):
            continue
        base = os.path.basename(p)
        if any(base.startswith(t) for t in targets):
            continue  # referrer is part of the island being removed
        for ref in load_refs(p):
            rb = os.path.basename(ref)
            for t in targets:
                if rb.startswith(t):
                    external[t].append(os.path.relpath(p, app))

removed = 0
fwdir = os.path.join(app, "Contents", "Frameworks")
for t in targets:
    if external[t]:
        print(f"   KEEP {t}: still referenced by {len(external[t])} non-target file(s): "
              + ", ".join(external[t][:5]))
        continue
    if not os.path.isdir(fwdir):
        continue
    for n in sorted(os.listdir(fwdir)):
        if n.startswith(t):
            fp = os.path.join(fwdir, n)
            try:
                os.remove(fp); removed += 1
                print(f"   removed Contents/Frameworks/{n}")
            except OSError as e:
                print(f"   [skip] {n}: {e}")
print(f"Removed {removed} file(s).")
PY

# --- 4. Re-sign (lipo invalidates signatures) ---------------------------------
log "Ad-hoc re-signing the universal app (replace '-' with your Developer ID to distribute)"
SIGN_ID="${SIGN_ID:--}"
/usr/bin/codesign --force --deep --sign "$SIGN_ID" \
  --options runtime --timestamp=none "$UNIVERSAL_APP" \
  || warn "codesign reported issues — inspect with: codesign -vvv --deep \"$UNIVERSAL_APP\""

log "Universal app ready: $UNIVERSAL_APP"
log "Verify architectures:  lipo -info \"$UNIVERSAL_APP/Contents/MacOS/okular\""
log "Next: ./05-audit-bundle.sh   (full macOS-11 / portability audit)"

# --- 5. Optional DMG ----------------------------------------------------------
if [[ "${MAKE_DMG:-0}" == "1" ]]; then
  DMG_OUT="$DIST_DIR/Okular-$OKULAR_VERSION-universal-macos11.dmg"
  log "Building DMG: $DMG_OUT"
  rm -f "$DMG_OUT"
  TMP_DMG_DIR="$STAGE/dmg"; rm -rf "$TMP_DMG_DIR"; mkdir -p "$TMP_DMG_DIR"
  /usr/bin/ditto "$UNIVERSAL_APP" "$TMP_DMG_DIR/Okular.app"
  ln -s /Applications "$TMP_DMG_DIR/Applications"
  /usr/bin/hdiutil create -volname "Okular $OKULAR_VERSION" -srcfolder "$TMP_DMG_DIR" \
    -ov -format UDZO "$DMG_OUT"
  log "DMG ready: $DMG_OUT"
fi
