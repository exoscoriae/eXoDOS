#!/usr/bin/env bash
# lib/daum.sh -- fetch, adapt and build DOSBox SVN Daum.
#
# Three problems have to be solved before Daum runs natively on Apple Silicon:
#
#   1. No AArch64 code generator.  Daum's dynrec backends cover x86, x86_64,
#      32-bit ARM and MIPS.  We graft in DOSBox-X's risc_armv8le.h, which
#      implements the same gen_*/DRC_* interface and is GPLv2 like Daum.
#   2. W^X.  Apple Silicon refuses to map memory both writable and executable
#      unless the process is entitled for it.  The bundle is signed with
#      allow-unsigned-executable-memory, and the cache allocator asks for RWX
#      first, falling back to MAP_JIT with per-thread toggling.
#   3. 16 KB pages.  Daum aligns its code cache to a hardcoded 4096, which is
#      not a valid mprotect granularity on Apple Silicon.
#
# The edits below locate their targets by pattern rather than by line number,
# verify afterwards that each one actually applied, and abort with the
# surrounding source if not.  A silently-skipped patch here would produce a
# binary that builds cleanly and then corrupts memory at run time.
# shellcheck shell=bash

DAUM_SRC=""
DAUM_PATCH_FP=""

# Identity of the patch set: everything that decides what the prepared tree
# looks like.  Used to detect a tree prepared by an older version of this
# script -- see the note in daum_prepare().
daum_patch_fingerprint() {
  local f
  {
    printf 'DAUM_PROFILE=%s\n' "$DAUM_PROFILE"
    # Everything whose content decides what the prepared tree contains.
    #
    # risc_armv8le.h and fpu_instructions_softfloat.h were missing from this
    # list, and that is not cosmetic: the backend is copied in only
    # `if [[ ! -f "$backend" ]]`, so on a tree that already exists an edited
    # vendor/risc_armv8le.h was never copied AND the fingerprint did not change,
    # meaning the build succeeded while shipping the old code generator.  That
    # is the same failure the stamp exists to prevent, one directory over.
    #
    # $ARMV8LE_LOCAL rather than the vendored path, so a caller pointing
    # ARMV8LE_LOCAL at their own copy is fingerprinted too.  It is empty when
    # the file is fetched instead, and the download is content-pinned by
    # ARMV8LE_SHA256, so nothing is lost in that case.
    for f in "$SCRIPT_DIR/lib/daum.sh" \
             "$DBPROF_HEADER" \
             "$ARMV8LE_LOCAL" \
             "$SCRIPT_DIR/vendor/fpu_instructions_softfloat.h" \
             "$DBFPU_HEADER" \
             "$OPENGLHQ_DIR"/*; do
      [[ -n "$f" && -f "$f" ]] && sha256_of "$f"
    done
    # The SoftFloat and Bochs x87 sources are copied wholesale by
    # daum_install_softfloat(); hash the lot rather than naming files, because a
    # named list is what missed fpu_constant.h the first time.
    if [[ -d "$SOFTFLOAT_DIR" ]]; then
      find "$SOFTFLOAT_DIR" -type f \( -name '*.h' -o -name '*.cc' \) -print0 \
        | LC_ALL=C sort -z | xargs -0 /usr/bin/shasum -a 256 | awk '{print $1}'
    fi
  } | /usr/bin/shasum -a 256 | awk '{print $1}'
}

daum_prepare() {
  local archive root

  if [[ -n "$DAUM_LOCAL_ARCHIVE" ]]; then
    [[ -f "$DAUM_LOCAL_ARCHIVE" ]] \
      || die "DAUM_LOCAL_ARCHIVE is set but $DAUM_LOCAL_ARCHIVE does not exist"
    archive="$DAUM_LOCAL_ARCHIVE"
    say "using local Daum archive: $archive"

    # A local archive bypasses fetch(), so it bypasses fetch()'s checksum
    # handling too.  Verify it here or the one input nobody checks is the most
    # important one.
    if [[ -n "$DAUM_LOCAL_SHA256" ]]; then
      local got; got="$(sha256_of "$archive")"
      if [[ "$got" == "$DAUM_LOCAL_SHA256" ]]; then
        ok "local archive matches the known-good source tree"
      else
        die "local archive checksum mismatch
  expected $DAUM_LOCAL_SHA256
  got      $got

This is the archive lib/daum.sh's source edits were written and tested
against.  A different tree may still build, but the six patches are no
longer known to apply.  To proceed anyway:
    DAUM_LOCAL_SHA256= ./build-dosbox-daum.sh"
      fi
    fi
  else
    archive="$(fetch "$DAUM_URL" "dosbox-daum-${DAUM_VERSION}.tar.gz")"
  fi

  # Extract into a dedicated directory and then *locate* the tree, rather than
  # assuming the archive has a single top-level directory.  GitHub tarballs do;
  # a hand-rolled .7z of the source may put configure.ac at the root.
  root="$SOURCES/daum-${DAUM_VERSION}"

  # The source edits are applied IN PLACE and are not all idempotent (the
  # save-state widening asserts on an exact replacement count and fails on a
  # second pass), so daum_patch_sources() skips everything the moment it finds
  # its stamp.  A tree left over from an older lib/daum.sh therefore survives a
  # rebuild untouched, and the build succeeds while silently shipping the
  # previous patch set.
  #
  # That is not hypothetical.  It is exactly how openglhq came out of a build
  # copied into src/gui but never added to Makefile.am and never wired into
  # sdlmain.cpp -- with every other check still passing, because everything
  # else had been patched by the previous run.  --clean-daum did not help: its
  # glob was $SOURCES/dosbox-svn-daum-*, which has never matched the directory
  # this function actually extracts into.
  #
  # So: fingerprint the patch set and start from a clean tree when it changes.
  DAUM_PATCH_FP="$(daum_patch_fingerprint)"
  if [[ -f "$root/.daum-patched" ]] \
     && [[ "$(cat "$root/.daum-patched" 2>/dev/null)" != "$DAUM_PATCH_FP" ]]; then
    say "patch set changed since this tree was prepared -- re-extracting"
    rm -rf "$root"
  fi

  if [[ ! -d "$root" ]]; then
    mkdir -p "$root"
    tar -xf "$archive" -C "$root" \
      || die "could not extract $archive
macOS tar reads .tar.gz, .tar.xz, .zip and .7z; if this is something else,
unpack it yourself and point DAUM_LOCAL_ARCHIVE at a tarball."
  fi

  DAUM_SRC="$(find "$root" -maxdepth 3 -name configure.ac -print -quit 2>/dev/null)"
  DAUM_SRC="${DAUM_SRC%/configure.ac}"

  if [[ -z "$DAUM_SRC" || ! -f "$DAUM_SRC/configure.ac" ]]; then
    die "no DOSBox source tree found in $archive (no configure.ac)

Extracted contents:
$(find "$root" -maxdepth 2 | head -15 | sed 's/^/    /')

The usual cause is the GitHub *tag* tarball: the 20150125 tag in
ykhwong/dosbox-svn-daum points at a commit holding only LICENSE, so it
downloads and extracts cleanly but contains no source.  The default
DAUM_URL now uses the branch head instead.  To use a copy you already
have:  DAUM_LOCAL_ARCHIVE=/path/to/source.7z ./build-dosbox-daum.sh"
  fi
  ok "Daum source tree: $DAUM_SRC"
  daum_normalize_line_endings
  daum_restore_exec_bits

  # The AArch64 backend, dropped in beside Daum's own risc_*.h files.
  #
  # Copied whenever the vendored source differs from what is already in the
  # tree, not merely when the tree has none.  `if [[ ! -f ]]` meant an edit to
  # vendor/risc_armv8le.h never reached an existing tree -- and since the
  # fingerprint did not cover this file either, nothing forced a re-extract, so
  # the build shipped the previous code generator and said nothing.  Both halves
  # are fixed: the fingerprint now covers it (see daum_patch_fingerprint) and
  # the copy below is unconditional-on-difference.
  local backend="$DAUM_SRC/src/cpu/core_dynrec/risc_armv8le.h"
  if [[ -n "$ARMV8LE_LOCAL" && -f "$ARMV8LE_LOCAL" ]] \
     && ! cmp -s "$ARMV8LE_LOCAL" "$backend"; then
    rm -f "$backend"
  fi
  if [[ ! -f "$backend" ]]; then
    local src origin
    if [[ -n "$ARMV8LE_LOCAL" && -f "$ARMV8LE_LOCAL" ]]; then
      src="$ARMV8LE_LOCAL"; origin="vendor/$(basename "$ARMV8LE_LOCAL")"
    else
      src="$(fetch "$ARMV8LE_URL" "risc_armv8le.h")"
      origin="${DOSBOXX_REPO}@${DOSBOXX_COMMIT}"
    fi
    # The AArch64 code generator is the single most important input to this
    # build; a silent change upstream would be miscompiled guest code, not a
    # build failure.  Verify the content regardless of where it came from.
    if [[ -n "$ARMV8LE_SHA256" ]]; then
      local got; got="$(sha256_of "$src")"
      [[ "$got" == "$ARMV8LE_SHA256" ]] || die "risc_armv8le.h checksum mismatch
  expected $ARMV8LE_SHA256
  got      $got
  source   $src"
    else
      warn "risc_armv8le.h is unverified; pin it with"
      warn "    ARMV8LE_SHA256=$(sha256_of "$src")"
    fi
    cp -f "$src" "$backend"
    ok "installed risc_armv8le.h from $origin"
  fi

  daum_install_glide_sdk
  daum_install_openglhq
  daum_install_softfloat
  daum_install_fpu_profiler
  daum_build_fputest
  daum_install_profiler
  daum_patch_sources
}

# The end-to-end FPU acceptance test: a DOS .COM running the exact FILD/FBSTP
# sequence OLE2DISP.DLL uses to detect a reduced-precision FPU.  Assembled here
# because nasm is already part of the build toolchain; verify-bundle.sh then
# only needs the finished .COM, so it stays standalone.
daum_build_fputest() {
  local asm="$SCRIPT_DIR/vendor/fputest.asm"
  local out="$BUILD_ROOT/fputest.com"
  [[ -f "$asm" ]] || { warn "vendor/fputest.asm missing; skipping the FPU acceptance test"; return 0; }
  if ! "$TOOLS/bin/nasm" -f bin "$asm" -o "$out" 2>"$BUILD_ROOT/fputest.err"; then
    warn "could not assemble the FPU acceptance test:"
    sed 's/^/        /' "$BUILD_ROOT/fputest.err" | head -5 >&2
    return 0
  fi
  ok "assembled the FPU acceptance test ($(wc -c <"$out" | tr -d ' ') bytes)"
}

# Berkeley SoftFloat-3e plus Bochs' x87 transcendentals, which together give
# both slices identical 80-bit arithmetic.  See vendor/fpu_instructions_softfloat.h
# for why that matters (short version: Windows 3.1's OLE2DISP.DLL detects a
# reduced-precision FPU and aborts, so Win3.1 apps die on Apple Silicon).
#
# Layout is not free choice: Bochs' x87 files include "../softfloat3e/include/...",
# so the two directories have to stay siblings.  Hence src/softfloat/{softfloat3e,fpu}.
daum_install_softfloat() {
  local src="$SOFTFLOAT_DIR" dst="$DAUM_SRC/src/softfloat"
  [[ -d "$src/softfloat3e" ]] || die "$src/softfloat3e is missing (vendor/bochs-fpu)"

  rm -rf "$dst"; mkdir -p "$dst/fpu"
  cp -R "$src/softfloat3e" "$dst/softfloat3e"
  cp "$src"/x87/* "$dst/fpu/"
  cp "$SCRIPT_DIR/vendor/fpu_instructions_softfloat.h" "$DAUM_SRC/src/fpu/"

  # SoftFloat includes "config.h", and so does Daum -- and Daum's is on the
  # include path first.  Rename ours so the two cannot be confused.
  #
  # TWO shims, not one.  fpu.cpp reaches softfloat3e's shim (via
  # fpu_instructions_softfloat.h) at a point where Daum has already typedef'd
  # Bit64u as `unsigned long`, so that shim must not typedef them again.  The
  # x87 sources do need them and never see a Daum header, so they get their own.
  cp "$src/shim/sf3e_config.h" "$dst/softfloat3e/include/bochs_shim_config.h"
  # Sweep both trees rather than a fixed list: a hardcoded set of filenames is
  # exactly what silently misses a file when upstream adds one -- fpu_constant.h
  # was missed that way once already.
  cp "$src/shim/x87_config.h" "$dst/fpu/bochs_shim_config.h"
  # Both spellings appear: softfloat3e uses #include "config.h", the x87 layer
  # uses #include <config.h>.  Matching only the quoted form missed
  # fpu_constant.h entirely.
  local f n=0
  while IFS= read -r f; do
    sed -i.bak -e 's|#include "config\.h"|#include "bochs_shim_config.h"|' \
               -e 's|#include <config\.h>|#include "bochs_shim_config.h"|' "$f" && rm -f "$f.bak"
    n=$((n+1))
  done < <(grep -rlE '#include ("config\.h"|<config\.h>)' "$dst" 2>/dev/null)
  [[ $n -gt 0 ]] || die "no vendored file included config.h -- the layout changed, check before shipping"
  if grep -rqE '#include ("config\.h"|<config\.h>)' "$dst"; then
    die "a vendored source still includes config.h; it would pick up Daum's generated one"
  fi
  if grep -rq '#include "config.h"' "$dst/softfloat3e"; then
    die "a vendored SoftFloat header still includes \"config.h\"; it would pick up Daum's"
  fi

  ok "installed SoftFloat-3e ($(find "$dst" -name '*.cc' | wc -l | tr -d ' ') sources) into src/softfloat"
}

# The OpenGL-HQ scaler.  openglhq.cpp is new code; the four headers beside it
# are the ARB fragment programs and the edge-classification table lifted
# verbatim from openglhq.patch (GPL-2, same as DOSBox -- see
# vendor/openglhq/LICENSE-NOTICE.txt).  They land in src/gui/ next to
# sdlmain.cpp, which is where both the #include and the Makefile.am entry
# expect them.
daum_install_openglhq() {
  local dir="$OPENGLHQ_DIR" f
  [[ -d "$dir" ]] || die "$dir does not exist (vendor/openglhq is required)"
  for f in openglhq.cpp openglhq.h \
           SDL_openglhq_pass1.h SDL_openglhq_pass2.h \
           SDL_openglhq_pass3.h SDL_openglhq_table.h; do
    [[ -f "$dir/$f" ]] || die "vendor/openglhq/$f is missing"
    cp -f "$dir/$f" "$DAUM_SRC/src/gui/$f"
  done
  ok "installed the OpenGL-HQ scaler into src/gui"
}

# The main-loop profiler.  Header-only, so it needs no Makefile.am entry:
# src/Makefile.am and src/gui/Makefile.am both carry
# AM_CPPFLAGS = -I$(top_srcdir)/include, which is where this lands.
daum_install_profiler() {
  [[ "$DAUM_PROFILE" == "0" ]] && { say "profiler disabled (DAUM_PROFILE=0)"; return 0; }
  [[ -f "$DBPROF_HEADER" ]] \
    || die "DAUM_PROFILE is on but $DBPROF_HEADER does not exist
Build without it:  DAUM_PROFILE=0 ./build-dosbox-daum.sh"
  cp -f "$DBPROF_HEADER" "$DAUM_SRC/include/dbprof.h"
  ok "installed dbprof.h (runtime-gated on \$DOSBOX_PROF)"
}

# The FPU coverage histogram.  Unlike dbprof it is NOT tied to DAUM_PROFILE:
# it answers "which FPU paths did this workload execute", which is a question
# about correctness coverage rather than performance, and a build that cannot
# answer it cannot tell "the fix works" from "the fix was never reached".
#
# Lands in src/fpu/ rather than include/ because fpu_instructions_softfloat.h
# includes it as "dbfpu.h" and both consumers -- src/fpu/fpu.cpp and
# core_dynrec.cpp via dyn_fpu.h -- already have src/fpu on their include path
# through the softfloat header's own directory.
daum_install_fpu_profiler() {
  [[ -f "$DBFPU_HEADER" ]] || die "$DBFPU_HEADER does not exist (vendor/dbfpu.h)"
  cp -f "$DBFPU_HEADER" "$DAUM_SRC/src/fpu/dbfpu.h"
  ok "installed dbfpu.h (runtime-gated on \$DOSBOX_FPU_PROFILE)"
}

# include/glide.h does  #include "../openglide/sdk2_glide.h"  -- the 3Dfx Glide
# SDK headers, which ykhwong had checked out beside the tree and which are not
# part of the source archive.  glide.cpp is listed unconditionally in
# src/hardware/Makefile.am, so without them nothing in src/hardware compiles.
#
# Only the type and constant definitions are consumed: glide.h sets
# FX_GLIDE_NO_FUNC_PROTO before the include, so no prototypes are pulled in, and
# it pre-defines __3DFX_H__ after declaring its own Fx* types -- deliberately
# neutralising sdk2_3dfx.h so that FxU32 stays 32-bit to match the DOS guest.
# The file must still exist to be #included, hence all five are fetched.
daum_install_glide_sdk() {
  local dir="$DAUM_SRC/openglide" h
  [[ -f "$dir/sdk2_glide.h" ]] && return 0
  mkdir -p "$dir"
  for h in $GLIDE_SDK_HEADERS; do
    cp -f "$(fetch "${OPENGLIDE_RAW}/${h}" "$h")" "$dir/$h"
  done
  ok "installed Glide SDK headers from ${OPENGLIDE_REPO}@${OPENGLIDE_REF}"
}

# These headers carry values that cross the guest/host boundary: a DOS program
# passes Glide resolution and format codes straight through glide.cpp.  A wrong
# constant would not fail to compile, it would silently mis-render.  Assert the
# few that pin the ABI rather than trusting whatever the fetch returned.
daum_verify_glide_sdk() {
  local dir="$DAUM_SRC/openglide" bad=0
  grep -q 'define[[:space:]]\+GLIDE_NUM_TMU' "$dir/sdk2_glidesys.h" \
    || { warn "GLIDE_NUM_TMU not defined in sdk2_glidesys.h"; bad=1; }
  grep -q 'GR_RESOLUTION_640x480' "$dir/sdk2_sst1vid.h" \
    || { warn "GR_RESOLUTION_* codes missing from sdk2_sst1vid.h"; bad=1; }
  grep -q 'GrScreenResolution_t' "$dir/sdk2_sst1vid.h" \
    || { warn "GrScreenResolution_t missing from sdk2_sst1vid.h"; bad=1; }
  grep -q '__3DFX_H__' "$dir/sdk2_3dfx.h" \
    || { warn "sdk2_3dfx.h has no __3DFX_H__ guard; glide.h cannot neutralise it"; bad=1; }
  [[ $bad -eq 0 ]] && ok "Glide SDK headers present (required types and codes found)"
  return 0
}

# Daum was maintained on Windows and the whole tree uses CRLF line endings.
# That is harmless for the C/C++ sources -- clang does not care -- but fatal for
# the build system:
#
#   autogen.sh    the shebang becomes "#!/bin/sh\r" -> "bad interpreter"
#   configure.ac  autoconf emits a configure script that inherits the CRLF
#   Makefile.am   automake emits Makefile.in whose recipes end in \r
#   acinclude.m4  aclocal mangles the macro definitions
#
# Convert only the build system and anything with a shebang.  The sources are
# left alone: rewriting 408 files to fix a problem compilers do not have would
# be churn, and a literal \r inside a string constant would be a real risk.
daum_normalize_line_endings() {
  local converted
  converted="$(python3 - "$DAUM_SRC" <<'PY'
import os, sys
root = sys.argv[1]
names = {'configure.ac', 'configure.in', 'acinclude.m4', 'aclocal.m4',
         'Makefile.am', 'Makefile.in', 'autogen.sh'}
suffixes = ('.sh', '.m4', '.ac', '.in', '.pl')
n = 0
for dirpath, _, files in os.walk(root):
    for name in files:
        p = os.path.join(dirpath, name)
        want = name in names or name.endswith(suffixes)
        if not want:
            # Also catch scripts identified only by their shebang.
            try:
                with open(p, 'rb') as f:
                    want = f.read(2) == b'#!'
            except OSError:
                continue
        if not want:
            continue
        try:
            with open(p, 'rb') as f:
                data = f.read()
        except OSError:
            continue
        if b'\r\n' in data:
            with open(p, 'wb') as f:
                f.write(data.replace(b'\r\n', b'\n'))
            n += 1
print(n)
PY
)" || die "line-ending normalisation failed"

  if [[ "${converted:-0}" -gt 0 ]]; then
    ok "converted $converted build file(s) from CRLF to LF"
  fi
}

# .7z stores no POSIX permission bits, and neither do some .zip archives, so an
# extracted tree has every script non-executable.  The first casualty is
# ./autogen.sh -> "Permission denied"; the autotools aux scripts that automake
# copies in later would be the next.
#
# Restore the bit on anything carrying a shebang, plus the aux files that are
# executable by convention but may not have one.
daum_restore_exec_bits() {
  local f fixed=0

  while IFS= read -r -d '' f; do
    [[ -x "$f" ]] && continue
    # Read exactly two bytes; LC_ALL=C keeps this byte-oriented for binaries.
    # Piped into grep rather than compared via $(...): a command substitution
    # over a file whose first byte is NUL makes bash warn "ignored null byte in
    # input", and the tree contains plenty of binary files.
    if LC_ALL=C head -c2 "$f" 2>/dev/null | LC_ALL=C grep -aq '^#!'; then
      chmod +x "$f" && fixed=$((fixed+1))
    fi
  done < <(find "$DAUM_SRC" -type f -print0)

  for f in autogen.sh configure install-sh config.guess config.sub \
           depcomp missing compile ltmain.sh mkinstalldirs; do
    if [[ -f "$DAUM_SRC/$f" && ! -x "$DAUM_SRC/$f" ]]; then
      chmod +x "$DAUM_SRC/$f" && fixed=$((fixed+1))
    fi
  done

  if (( fixed > 0 )); then
    ok "restored the executable bit on $fixed script(s)"
  fi
  [[ -x "$DAUM_SRC/autogen.sh" ]] \
    || die "autogen.sh is still not executable at $DAUM_SRC"
}

daum_patch_sources() {
  # The stamp records WHICH patch set was applied, not merely that one was.  An
  # empty or mismatched stamp means this tree is stale; daum_prepare() will
  # already have deleted it, so reaching here with a mismatch means the tree
  # was hand-made and re-patching it is unsafe.
  local stamp="$DAUM_SRC/.daum-patched"
  if [[ -f "$stamp" ]]; then
    if [[ "$(cat "$stamp" 2>/dev/null)" == "$DAUM_PATCH_FP" ]]; then
      ok "sources already adapted"; return 0
    fi
    die "$DAUM_SRC was patched by a different version of this script.
The edits are applied in place and are not all idempotent, so it cannot be
re-patched.  Delete the tree and let the build re-extract it:
    rm -rf $DAUM_SRC"
  fi

  say "adapting Daum sources for macOS / AArch64"
  python3 - "$DAUM_SRC" <<'PYEOF' || die "source adaptation failed (see message above)"
# Written against the actual Daum 20150125 tree, not guessed.  Each edit
# asserts on the exact text it expects and aborts if the tree has moved.
import os, re, sys

root = sys.argv[1]
changed = []

# NOTE: these normalise line endings as a side effect, and that is deliberate.
#
# Daum's tree is CRLF throughout (shell.cpp: 49751 of 49751 lines).  Python's
# text mode reads with universal newlines and writes '\n', so every file this
# patcher touches comes out LF -- which is why a diff against upstream needs
# `--strip-trailing-cr` to be readable.
#
# Leaving it that way is the safer choice, not an oversight.  Preserving CRLF
# would mean newline='' on both ends, and then every '\n' in the replacement
# strings below would produce a MIXED-ending file: the inserted lines LF, the
# surrounding ones CRLF.  Normalising the whole file guarantees consistency, and
# no compiler cares either way.
def read(p):
    with open(p, 'r', errors='surrogateescape') as f: return f.read()

def write(p, s):
    with open(p, 'w', errors='surrogateescape') as f: f.write(s)
    changed.append(os.path.relpath(p, root))

def bail(msg, context=""):
    sys.stderr.write("\n  PATCH FAILURE: %s\n" % msg)
    if context:
        sys.stderr.write("  --- relevant source ---\n")
        for line in context.splitlines()[:40]:
            sys.stderr.write("    %s\n" % line)
    sys.exit(1)

def sub1(s, pattern, repl, what, flags=0):
    """Replace exactly one occurrence or abort."""
    new, n = re.subn(pattern, repl, s, count=1, flags=flags)
    if n != 1:
        bail("could not apply: %s" % what)
    return new

def subn(s, pattern, repl, expect, what, flags=0):
    """Replace exactly `expect` occurrences or abort."""
    new, n = re.subn(pattern, repl, s, flags=flags)
    if n != expect:
        bail("expected %d replacements, made %d: %s" % (expect, n, what))
    return new

# ================================================== core_dynrec.cpp
p = os.path.join(root, 'src', 'cpu', 'core_dynrec.cpp')
if not os.path.exists(p): bail("src/cpu/core_dynrec.cpp is missing")
s = read(p)

# (a) Host page size.  PAGESIZE_TEMP in cache.h resolves to this when
#     C_HAVE_MPROTECT is set, which it is on macOS.  16384 is a valid mprotect
#     granularity on both 4 KB and 16 KB systems; Apple Silicon requires it.
#     The 4096s in CACHE_MAXSIZE and DYN_PAGE_HASH are GUEST x86 page sizes and
#     must not be touched.
if '#define PAGESIZE 16384' not in s:
    s = sub1(s, r'#define PAGESIZE 4096', '#define PAGESIZE 16384',
             "raise host PAGESIZE to 16384 in core_dynrec.cpp")

# (b) Target-CPU constant.  Note POWERPC collides with ARMV4LE at 0x04 upstream;
#     0x06 is unused.
if 'ARMV8LE' not in s:
    s = sub1(s, r'(#define ARMV7LE\t*0x05\n)', r'\1#define ARMV8LE\t\t0x06\n',
             "add ARMV8LE constant")

# (c) Dispatch to the new backend.
if 'risc_armv8le.h' not in s:
    s = sub1(s,
             r'(#elif \(C_TARGETCPU == ARMV4LE\) \|\| \(C_TARGETCPU == ARMV7LE\)\n'
             r'#include "core_dynrec/risc_armv4le\.h"\n)',
             r'\1#elif C_TARGETCPU == ARMV8LE\n#include "core_dynrec/risc_armv8le.h"\n',
             "add ARMV8LE include branch")

# (d) W^X bracket.  This is the only place Daum enters generated code, which is
#     what makes the "keep the cache writable, flip to executable here" scheme
#     in cache.h workable.  On Apple Silicon a MAP_JIT page cannot be writable
#     and executable at once, and plain RWX mmap is refused outright even with
#     allow-unsigned-executable-memory -- that entitlement only relaxes W^X on
#     Intel.  Without this the dynrec dies the moment it runs a block.
if 'drc_jit_exec_begin' not in s:
    s = sub1(s,
             r'(\n\s*)(BlockReturn ret=core_dynrec\.runcode\(block->cache\.start\);)',
             r'\1drc_jit_exec_begin();'
             r'\1\2'
             r'\1drc_jit_write_begin();',
             "bracket the generated-code entry with the W^X toggle")
write(p, s)

# ================================================== cache.h
p = os.path.join(root, 'src', 'cpu', 'core_dynrec', 'cache.h')
if not os.path.exists(p): bail("src/cpu/core_dynrec/cache.h is missing")
s = read(p)

if 'drc_alloc_cache' not in s:
    helper = '''
/* --- macOS W^X ---------------------------------------------------------- *
 * Apple Silicon refuses PROT_WRITE|PROT_EXEC unless the process is entitled.
 * dosbox-daum.app is signed with allow-unsigned-executable-memory, which makes
 * a plain RWX mapping succeed, so that is what is tried first.  MAP_JIT is the
 * fallback -- for an unsigned or differently-signed copy of the binary, where
 * the plain mapping is refused.
 *
 * BOTH PATHS WORK, and which one you get is a property of the signature, not of
 * the hardware.  Said explicitly because the repo carried two comments claiming
 * opposite things -- this one used to end "cache_init below refuses to continue
 * if the fallback is ever taken", describing a design that the toggling scheme
 * immediately below replaced, and verify-bundle.sh asserted the reverse ("on
 * Apple Silicon this must be MAP_JIT: plain RWX mmap is refused there
 * regardless of entitlements").  Neither was checked, so neither had to be
 * right.  cache_init logs which mapping it got and the verifier now requires
 * the line to be present without prescribing which one it names.
 *
 * A MAP_JIT region is never simultaneously writable and executable: it needs
 * pthread_jit_write_protect_np() toggled around writes to generated code.  See
 * the note on drc_jit_write_begin below for how that is arranged without
 * bracketing every gen_* call site.                                          */
#if defined(__APPLE__)
#include <sys/mman.h>
#include <pthread.h>
static bool drc_cache_uses_map_jit = false;
static void *drc_alloc_cache(size_t size) {
	void *p = mmap(NULL, size, PROT_READ|PROT_WRITE|PROT_EXEC,
	               MAP_PRIVATE|MAP_ANON, -1, 0);
	if (p != MAP_FAILED) return p;
#ifdef MAP_JIT
	p = mmap(NULL, size, PROT_READ|PROT_WRITE|PROT_EXEC,
	         MAP_PRIVATE|MAP_ANON|MAP_JIT, -1, 0);
	if (p != MAP_FAILED) { drc_cache_uses_map_jit = true; return p; }
#endif
	return NULL;
}
/* A MAP_JIT region is never writable and executable at the same instant;
 * pthread_jit_write_protect_np() switches the calling thread between the two.
 * Daum's dynrec only ever writes to the cache from its run loop -- it compiles
 * a block or patches a link, returns, and only then enters generated code --
 * so instead of bracketing every gen_* writer we invert the default: the cache
 * stays writable, and core_dynrec.cpp flips it to executable around the single
 * call that enters a block (CPU_Core_Dynrec_Run).  The toggle is per-thread,
 * which is fine here: only the emulation thread touches the cache.           */
static INLINE void drc_jit_write_begin(void) {
#if defined(__aarch64__)
	if (drc_cache_uses_map_jit) pthread_jit_write_protect_np(0);
#endif
}
static INLINE void drc_jit_exec_begin(void) {
#if defined(__aarch64__)
	if (drc_cache_uses_map_jit) pthread_jit_write_protect_np(1);
#endif
}
#else
#define drc_alloc_cache(sz) malloc(sz)
static INLINE void drc_jit_write_begin(void) { }
static INLINE void drc_jit_exec_begin(void) { }
#endif
/* ------------------------------------------------------------------------ */

'''
    s = sub1(s, r'(static bool cache_initialized = false;\n)', helper.replace('\\', '\\\\') + r'\1',
             "insert the RWX cache allocator")

    # Replace ONLY the code-cache allocation.  cache_init also mallocs
    # cache_blocks, which is ordinary data and must not become executable.
    s = sub1(s,
             r'(#else\n\t\t\tcache_code_start_ptr=\(Bit8u\*\))malloc(\(CACHE_TOTAL\+CACHE_MAXSIZE\+PAGESIZE_TEMP-1\+PAGESIZE_TEMP\);)',
             r'\1drc_alloc_cache\2',
             "swap the code-cache malloc for the RWX allocator")

# drc_alloc_cache() already established the permissions, so the follow-up
# mprotect is redundant on the RWX path -- and on a MAP_JIT region the kernel
# refuses it outright, which is precisely the
#   "Setting excute permission on the code cache has failed"
# that made core=dynamic unusable.  Skip it on Apple, report which mapping we
# actually got, and stop if it is the one we cannot drive correctly.
if 'DRC: code cache' not in s:
    s = sub1(s,
             r'#if \(C_HAVE_MPROTECT\)\n'
             r'(\s*)if\(mprotect\(cache_code_link_blocks,'
             r'CACHE_TOTAL\+CACHE_MAXSIZE\+PAGESIZE_TEMP,'
             r'PROT_WRITE\|PROT_READ\|PROT_EXEC\)\)\n'
             r'\s*LOG_MSG\("Setting excute permission on the code cache has failed"\);\n'
             r'#endif\n',
             '#if defined(__APPLE__)\n'
             r'\1' 'LOG_MSG("DRC: code cache %s, %u-byte host pages",\n'
             r'\1' '\tdrc_cache_uses_map_jit ? "MAP_JIT (W^X toggled at block entry)"\n'
             r'\1' '\t                       : "mapped RWX", (unsigned)PAGESIZE_TEMP);\n'
             r'\1' 'drc_jit_write_begin();\t/* cache starts out writable */\n'
             '#elif (C_HAVE_MPROTECT)\n'
             r'\1' 'if(mprotect(cache_code_link_blocks,CACHE_TOTAL+CACHE_MAXSIZE+PAGESIZE_TEMP,PROT_WRITE|PROT_READ|PROT_EXEC))\n'
             r'\1' '\tLOG_MSG("Setting excute permission on the code cache has failed");\n'
             '#endif\n',
             "skip the redundant mprotect on macOS and report the mapping mode")
write(p, s)

# ================================================== configure.ac
p = os.path.join(root, 'configure.ac')
s = read(p)

# (a) Recognise arm64.  Upstream has no ARM case at all, so without this the
#     host falls into *) -> C_TARGETCPU UNKNOWN.
if 'ARMV8LE' not in s:
    s = sub1(s,
             r'(case "\$host_cpu" in\n)',
             r'''\1  aarch64 | arm64)
    AC_DEFINE(C_TARGETCPU,ARMV8LE)
    AC_MSG_RESULT(ARMv8 64-bit)
    c_targetcpu="armv8le"
    c_unalignedmemory=yes
    ;;
''',
             "add the aarch64 case to the host_cpu block")

# (a2) The setpriority probe never compiles.  configure.ac writes
#          int main(int argc,char * argv[]) {
#      inside AC_LANG_SOURCE([...]), but [ and ] are m4's quote characters, so
#      the brackets are stripped and the generated conftest.c declares
#          int main(int argc,char * argv) {
#      Modern clang rejects that outright -- "second parameter of 'main'
#      (argument array) must be of type 'char **'" -- so the test fails for a
#      reason unrelated to setpriority, and autoconf silently records "no".
#      The result is that C_SET_PRIORITY is never defined and the priority=
#      setting in [sdl] is quietly ignored on every modern compiler.
#
#      Dropping the parameters sidesteps m4 quoting entirely and tests exactly
#      the same thing.  (This is the only test program in configure.ac that
#      declares argv[], so it is the only probe affected.)
if 'int main(void) {' not in s:
    s = sub1(s, r'int main\(int argc,char \* argv\[\]\) \{(\s*)return setpriority',
             r'int main(void) {\1return setpriority',
             "fix the m4-mangled setpriority probe")

# (b) Let dynrec be enabled for it.  This is the one that actually matters:
#     upstream gates C_DYNREC on x86/x86_64 only, so --enable-dynrec alone
#     would still have produced an interpreter-only arm64 build.
if 'xarmv8le' not in s:
    s = sub1(s,
             r'(    if test x\$c_targetcpu = xx86_64 ; then\n'
             r'        AC_DEFINE\(C_DYNREC,1\)\n'
             r'        AC_MSG_RESULT\(yes\)\n)',
             r'''    if test x$c_targetcpu = xx86_64 -o x$c_targetcpu = xarmv8le ; then
        AC_DEFINE(C_DYNREC,1)
        AC_MSG_RESULT(yes)
''',
             "extend the dynrec gate to armv8le")
write(p, s)

# ================================================== sdlmain.cpp: openglhq
# Upstream openglhq is not a DOSBox renderer at all.  Daum selects it with
#   putenv("SDL_VIDEODRIVER=openglhq")
# because openglhq.patch patches SDL 1.2, not DOSBox: it adds a video driver to
# SDL's SDL_VideoDevice bootstrap that transparently intercepts any 2D program.
# sdl12-compat is an API shim over SDL2 with no driver model to plug into, so
# that route cannot be made to work here at any price.
#
# What survives the change of host is the part that does the actual work: three
# !!ARBfp1.0 fragment programs and a 4096-entry edge-classification table.
# src/gui/openglhq.cpp drives those directly from DOSBox's own OpenGL output
# path, so output=openglhq is a normal SCREEN_OPENGL window with a different
# GFX_EndUpdate.  Everything downstream -- fullscreen, menus, save states --
# keeps seeing SCREEN_OPENGL, which is what makes this small: none of Daum's
# SCREEN_OPENGLHQ special cases (all of them Windows-shaped) become reachable.
p = os.path.join(root, 'src', 'gui', 'sdlmain.cpp')
if not os.path.exists(p): bail("src/gui/sdlmain.cpp is missing")
s = read(p)
if 'OpenGLHQ_Active' not in s:
    s = sub1(s, r'(#include "render\.h"\n)', r'\1#include "openglhq.h"\n',
             "include openglhq.h in sdlmain.cpp")

    # (a) request flag, beside the other OpenGL state
    s = sub1(s, r'(\t\tbool pixel_buffer_object;\n)',
             r'\1\t\tbool hq;                     /* output=openglhq requested */\n',
             "add sdl.opengl.hq")

    # (a2) Clear the flag wherever plain OpenGL is selected, so switching away
    #      from openglhq actually switches away.  Four sites: the opengl and
    #      openglnb arms of the parser, and change_output cases 3 and 4.  Done
    #      BEFORE the openglhq arm is rewritten below, so this cannot match the
    #      code that patch generates -- and the exact count fails loudly if
    #      upstream ever grows a fifth.
    s = subn(s,
             r'(\t\tsdl\.desktop\.want_type=SCREEN_OPENGL;\n'
             r'\t\tsdl\.opengl\.bilinear=(?:true|false);\n)',
             r'\1\t\tsdl.opengl.hq=false;\n', 4,
             "clear sdl.opengl.hq wherever plain OpenGL is selected")

    # (a3) The one probe rung that does not depend on openglhq being chosen.
    #      Every other rung lives inside `case SCREEN_OPENGL:`, so if the output
    #      type is downgraded before the mode set -- or if no mode set ever
    #      happens -- the ladder simply stops after the parser line and the two
    #      cases are indistinguishable.  They need very different answers, so
    #      this sits at the top of GFX_SetSize where it fires regardless.
    #
    #      The enum values are printed alongside rather than translated to
    #      names here: a name table in a patch duplicates knowledge that lives
    #      in sdlmain.cpp, and would go quietly wrong if the enum were ever
    #      reordered.  Taking the numbers from the enum itself cannot.
    s = sub1(s,
             r'(Bitu GFX_SetSize\(Bitu width,Bitu height,Bitu flags,double scalex,'
             r'double scaley,GFX_CallBack_t callback\) \{\n\tEndSplashScreen\(\);\n)',
             r'''\1#if C_OPENGL
\tdbg_gfx_setsize_seen++;
\tOpenGLHQ_ProbeLog("gfx-setsize %dx%d want=%d (opengl=%d surface=%d openglhq=%d)",
\t                  (int)width, (int)height, (int)sdl.desktop.want_type,
\t                  (int)SCREEN_OPENGL, (int)SCREEN_SURFACE, (int)SCREEN_OPENGLHQ);
#endif
''',
             "probe every GFX_SetSize, whichever output type it takes")

    # (a4) GUI_StartUp's OpenGL probe throws away the reason it failed.
    #
    #      Before any mode set, DOSBox does SDL_SetVideoMode(640,400,0,SDL_OPENGL)
    #      purely to find out whether GL works and to query the extensions.  If
    #      it returns NULL, want_type is permanently downgraded to SCREEN_SURFACE
    #      -- so this single line decides whether output=opengl and
    #      output=openglhq mean anything at all for the rest of the run.
    #
    #      SDL has just recorded exactly why, and the message drops it on the
    #      floor.  "Could not initialize OpenGL" is the same text whether the
    #      driver is missing, the pixel format was rejected, or the process
    #      cannot reach the window server, and those want different responses.
    s = sub1(s,
             r'(\tif \(sdl\.surface == NULL\) \{\n)'
             r'\t\tLOG_MSG\("Could not initialize OpenGL, switching back to surface"\);\n',
             r'''\1\t\tLOG_MSG("Could not initialize OpenGL, switching back to surface: %s", SDL_GetError());
\t\tOpenGLHQ_ProbeLog("gl-startup-probe failed: %s", SDL_GetError());
''',
             "report why the startup OpenGL probe failed")

    # (a5) Release openglhq's GL objects on the one path that destroys them.
    #
    #      SDL_SetVideoMode_Wrap has a SETMODE_SAVES short-circuit: if width,
    #      height, bpp and flags are all unchanged it returns the existing
    #      surface without calling SDL_SetVideoMode at all, so the GL context
    #      and every object in it survives.  DOSBox re-runs GFX_SetSize far
    #      more often than anything changes -- a measured session did it 18
    #      times, 13 of them changing nothing -- and openglhq used to tear
    #      everything down on each one at ~1.9 ms a time.
    #
    #      BEFORE the call, not after.  GL names only mean anything inside the
    #      context that issued them; once the context is replaced, our old
    #      texture name may belong to DOSBox's own texture in the new one, and
    #      deleting it would destroy that instead.  This is the last instant
    #      where the old context is still current, which is what makes it the
    #      right place rather than merely a convenient one.
    # The counter the fault-injection hook keys off.  File scope, because it is
    # written in GFX_SetSize and read in SDL_SetVideoMode_Wrap, and declared
    # ahead of the wrapper because that is the earlier of the two.
    s = sub1(s,
             r'(SDL_Surface\* SDL_SetVideoMode_Wrap\(int width,int height,int bpp,Bit32u flags\)\{\n)',
             r'''#if C_OPENGL
/* Bumped at the top of GFX_SetSize.  Lets the DOSBOX_FAIL_SETVIDEOMODE hook
   below distinguish a mode set on the guest-driven path from the two start-up
   GL probes, which DOSBox cannot recover from.  See lib/daum.sh. */
static int dbg_gfx_setsize_seen = 0;
#endif
\1''',
             "declare the GFX_SetSize entry counter used by the fault-injection hook")

    s = sub1(s,
             r'(\tSDL_Surface\* s = SDL_SetVideoMode\(width,height,bpp,flags\);\n)',
             r'''#if C_OPENGL
\tOpenGLHQ_ReleaseForContextChange();
#endif
\1''',
             "release openglhq's GL objects before the context is replaced")

    # (a2) Fault injection for the failure path.
    #
    # Everything above assumes SDL_SetVideoMode can fail here and that DOSBox
    # recovers.  That assumption had never been executed -- no test in this
    # project exercises any error path -- and the argument for why it is safe is
    # subtle enough to be worth testing rather than believing:
    #
    #   a failed mode set leaves i_width/i_height at the LAST SUCCESSFUL mode,
    #   because `if (s == NULL) return s;` runs before they are assigned.  Read
    #   alone that looks like a trap: a later identical GFX_SetSize would take
    #   the SETMODE_SAVES early return, skip SDL_SetVideoMode, and openglhq --
    #   already released on the way in -- would never be re-initialised.
    #
    #   It is not a trap, because the same failure sets sdl.surface to NULL at
    #   all 15 call sites, and `sdl.surface != NULL` is the FIRST term of the
    #   early-return guard.  i_* and sdl.surface therefore move together: the
    #   early return can only fire when i_* really does describe the surface
    #   being handed back.
    #
    # That is a static argument about an invariant spread over 15 call sites and
    # two functions.  DOSBOX_FAIL_SETVIDEOMODE=<n> makes the n'th mode set that
    # gets past the early return fail, so the argument can be executed instead.
    #
    # Shipped, not build-gated, and inert unless the variable is set -- the same
    # bargain SDL_OPENGLHQ_PROBE already makes, and verify-bundle.sh checks the
    # inertness of both rather than taking it on trust.  A hook that only exists
    # in a special build cannot test the binary anyone actually runs.
    # WHAT THIS SIMULATES, precisely: "SDL_SetVideoMode returned NULL", which is
    # the input the DOSBox state machine has to survive.  It does NOT simulate
    # "the window could not be created" -- the real call has already run and
    # succeeded by the time the hook discards its result.
    #
    # That is deliberate, and it is the difference between a test you can run and
    # one you cannot.  A faithful failure means letting sdl12-compat call
    # EndVidModeCreate() -- window destroyed, GL context destroyed -- and there
    # is no supported way to make that happen on demand without wedging the
    # display.  The invariant under test is entirely DOSBox-side (i_* vs
    # sdl.surface vs openglhq re-init), and discarding the result reproduces
    # exactly that input while leaving the display recoverable.
    #
    # Stated rather than left implicit, because a harness that quietly measures
    # something adjacent to the question is the failure mode this whole exercise
    # keeps turning up.
    s = sub1(s,
             r'(\tSDL_Surface\* s = SDL_SetVideoMode\(width,height,bpp,flags\);\n)',
             r'''\1\t/* DOSBOX_FAIL_SETVIDEOMODE=<n>: discard the result of the n'th OpenGL mode set
\t * ISSUED FROM GFX_SetSize, so the caller sees the NULL a real failure would
\t * produce.  Inert unless set.
\t *
\t * The selector went wrong twice, in the same way both times: any ordinal over
\t * "all mode sets" or "all GL mode sets" counts start-up calls that DOSBox
\t * cannot recover from, because it has no window yet.
\t *
\t *   n=2 over all calls   -> GUI_StartUp's initial 640x400 SDL_RESIZABLE window
\t *   n=2 over GL calls    -> the SECOND start-up GL probe; there are two,
\t *                           opengl_init() and GUI_StartUp(), both 640x400
\t *                           SDL_OPENGL, and whether both run depends on config
\t *
\t * So do not count by ordinal at all.  dbg_gfx_setsize_seen is bumped at the
\t * top of GFX_SetSize, and only mode sets issued after that point are eligible
\t * -- which is exactly the population the release/re-init cycle lives on, named
\t * directly instead of approximated by a number.  n=1 is now the first one. */
\t{
\t\tstatic int dbg_fail_at = -2;\t/* -2 = env not read yet, -1 = disabled */
\t\tstatic int dbg_gl_count = 0;
\t\tif (dbg_fail_at == -2) {
\t\t\tconst char *e = getenv("DOSBOX_FAIL_SETVIDEOMODE");
\t\t\tdbg_fail_at = (e && *e) ? atoi(e) : -1;
\t\t}
\t\tif (dbg_fail_at > 0 && dbg_gfx_setsize_seen > 0 && (flags & SDL_OPENGL)
\t\t    && ++dbg_gl_count == dbg_fail_at) {
\t\t\ts = NULL;
\t\t\tOpenGLHQ_ProbeLog("mode-set INJECTED-NULL at GFX_SetSize GL call %d (%dx%d flags=0x%x)",
\t\t\t                  dbg_gl_count, (int)width, (int)height, (unsigned)flags);
\t\t}
\t}
\tif (s == NULL)
\t\tOpenGLHQ_ProbeLog("mode-set returned NULL %dx%d bpp=%d flags=0x%x: %s",
\t\t                  (int)width, (int)height, (int)bpp, (unsigned)flags, SDL_GetError());
''',
             "add the mode-set fault-injection hook and a failure rung")

    # (b) output= parser.  Note this arm sits OUTSIDE the #if C_OPENGL that
    #     covers opengl/openglnb above it, so the body needs its own guard.
    s = sub1(s,
             r'\t\} else if \(output == "openglhq"\) \{\n'
             r'.*?'
             r'\t\tsdl\.desktop\.want_type=SCREEN_OPENGLHQ;\n\n'
             r'(\t\} else \{\n)',
             r'''\t} else if (output == "openglhq") {
#if C_OPENGL
\t\t/* A plain OpenGL window; openglhq.cpp supplies the shaders. */
\t\tsdl.desktop.want_type=SCREEN_OPENGL;
\t\tsdl.opengl.bilinear=false;   /* pass 3 does its own filtering */
\t\tsdl.opengl.hq=true;
\t\tOpenGLHQ_ProbeLog("conf output=openglhq accepted");
#else
\t\tLOG_MSG("SDL:output=openglhq needs OpenGL support; using surface");
\t\tsdl.desktop.want_type=SCREEN_SURFACE;
#endif
\1''',
             "route output=openglhq to the OpenGL path", re.S)

    # NOT DONE: forcing a hardware render scaler.
    #
    # Daum sets scaler=hardware2x whenever openglhq is active, on the reasoning
    # that openglhq is a MAGNIFYING scaler and wants the guest framebuffer, not
    # something RENDER already enlarged.  That reasoning is sound, but an
    # implementation here was tried and removed.  Recorded so it is not
    # reinvented:
    #
    #   * Daum's own two call sites are dead.  They use SetVal(), which opens
    #     `if (dos_kernel_disabled) return;`, and the kernel is down both during
    #     config parsing and during a pre-boot output switch.
    #   * hardware2x is SIZE 4.  RENDER_Reset only honours a hardware scaler
    #     when GFX_GetBestMode reported GFX_SCALING; otherwise it logs "Output
    #     does not support hardware scaling", clears the flag and KEEPS the
    #     size -- and size 4 without the flag selects ScaleNormal4x.  So the
    #     override can quadruple the frame.  Of the five hardware values only
    #     hardware2x collides; it is also Daum's default.
    #   * A guard on !render.scale.hardware self-retriggers: SetVal re-inits
    #     RENDER, RENDER_Reset clears the flag, the condition is true again.
    #     Measured 2.8 GB of log in 180 seconds.
    #
    # And after all of it, no observable benefit.  scaler=normal2x only engages
    # on dblw && dblh modes, and doublescan=true expands exactly those into the
    # full VGA raster BEFORE any scaler runs -- so on every game tested there
    # was nothing left to override.  Making it matter needs doublescan=false,
    # which breaks aspect correction on those same 200-line modes.
    #
    # If a case ever turns up where openglhq is visibly working on pre-scaled
    # pixels, revisit with hardware_none (size 1, degrades to ScaleNormal1x)
    # and a guard on the CONFIGURED property, never on the runtime flag.

    # (c) the runtime output switch (menu / change_output(6)) takes the same
    #     route rather than the SDL_VIDEODRIVER dance.
    s = sub1(s,
             r'(static void openglhq_init\(void\) \{\n)'
             r'.*?'
             r'\tsdl\.desktop\.want_type=SCREEN_OPENGLHQ;\n\}',
             r'''\1#if C_OPENGL
\tsdl.overlay=0;
\tsdl.desktop.want_type=SCREEN_OPENGL;
\tsdl.opengl.bilinear=false;
\tsdl.opengl.hq=true;
\tGFX_SetTitle(-1,-1,-1,false);
#endif
}''',
             "route the runtime openglhq switch to the OpenGL path", re.S)

    # (d) Keep the framebuffer in main memory.
    #
    #     This used to also call OpenGLHQ_Shutdown(), on the reasoning that
    #     GFX_SetupSurfaceScaled below replaces the GL context so this was the
    #     last moment to delete against the context that owns them.  The
    #     reasoning was sound and the premise was wrong: SETMODE_SAVES means
    #     GFX_SetupSurfaceScaled often replaces nothing, and 13 of 18 measured
    #     mode sets destroyed objects that were still perfectly valid.  The
    #     teardown moved to (a5), which fires only when the context really is
    #     about to go.
    s = sub1(s,
             r'(\t\t\} else if \(sdl\.opengl\.framebuf\) \{\n'
             r'\t\t\tfree\(sdl\.opengl\.framebuf\);\n'
             r'\t\t\}\n'
             r'\t\tsdl\.opengl\.framebuf=0;\n)',
             r'''\1\t\t/* openglhq uploads from main memory; the PBO path hands out a mapped GL
\t\t * buffer instead of sdl.opengl.framebuf, so the two are incompatible.
\t\t * DOSBox leaves PBO off unless -disable_vga_comp is given, so in practice
\t\t * this changes nothing. */
\t\tif (sdl.opengl.hq) sdl.opengl.pixel_buffer_object=false;
\t\t/* This side of GFX_SetupSurfaceScaled, so it is recorded even when the
\t\t * SDL video mode below fails and the whole arm is abandoned. */
\t\t/* scalex/scaley are what RENDER asked for, and they are what makes two
\t\t * mode sets of the SAME source produce different output geometry -- a
\t\t * 640x480 session was seen alternating 1067x960 and 1280x960, which is
\t\t * exactly the difference between scaley=1.2 and scaley=1.  Recording
\t\t * them turns that from a puzzle into a reading. */
\t\tOpenGLHQ_ProbeLog("gl-arm entered %dx%d hq=%d scale %.3fx%.3f flags=0x%x",
\t\t                  (int)width, (int)height, sdl.opengl.hq ? 1 : 0,
\t\t                  scalex, scaley, (unsigned)flags);
''',
             "shut openglhq down before the GL context is replaced")

    # (e) ...and bring it up once the new context and clip rect exist.  A
    #     failure here is not fatal: OpenGLHQ_Active() stays false and every
    #     dispatch below falls through to the stock display-list path.
    s = sub1(s,
             r'(\t\tglEndList\(\);\n)(\t\tsdl\.desktop\.type=SCREEN_OPENGL;\n)',
             r'''\1\t\tOpenGLHQ_ProbeLog("gl-context ready %dx%d clip %dx%d at %d,%d",
\t\t                  (int)width, (int)height,
\t\t                  (int)sdl.clip.w, (int)sdl.clip.h,
\t\t                  (int)sdl.clip.x, (int)sdl.clip.y);
\t\tif (sdl.opengl.hq &&
\t\t    !OpenGLHQ_Init((int)width, (int)height,
\t\t                   sdl.clip.x, sdl.clip.y, sdl.clip.w, sdl.clip.h))
\t\t\tLOG_MSG("SDL:OPENGL:openglhq unavailable for this mode, using plain opengl");
\2''',
             "initialise openglhq for the new mode")

    # (f) GFX_EndUpdate.  Same changed-line walk, different destination.
    s = sub1(s,
             r'(\t\t\tBitu y = 0, index = 0;\n)'
             r'\t\t\tglBindTexture\(GL_TEXTURE_2D, sdl\.opengl\.texture\);\n',
             r'\1\t\t\tif (!OpenGLHQ_Active()) glBindTexture(GL_TEXTURE_2D, sdl.opengl.texture);\n',
             "skip the stock texture bind when openglhq owns the upload")
    s = sub1(s,
             r'(\t\t\t\t\tBitu height = changedLines\[index\];\n)'
             r'\t\t\t\t\t(glTexSubImage2D\()',
             r'''\1\t\t\t\t\tif (OpenGLHQ_Active())
\t\t\t\t\t\tOpenGLHQ_UploadRows(pixels, (int)sdl.opengl.pitch,
\t\t\t\t\t\t                    (int)y, (int)height);
\t\t\t\t\telse
\t\t\t\t\t\t\2''',
             "route changed rows to openglhq's source texture")
    s = sub1(s,
             r'(\t\t\t\tindex\+\+;\n\t\t\t\}\n)'
             r'\t\t\tglCallList\(sdl\.opengl\.displaylist\);\n(\t\t\}\n)',
             r'''\1\t\t\tif (OpenGLHQ_Active()) OpenGLHQ_Render();
\t\t\telse glCallList(sdl.opengl.displaylist);
\2''',
             "run the three openglhq passes in place of the display list")

    # (g) Unrelated upstream bug, fixed while we are in this function: the PBO
    #     branch swaps and then falls through to the unconditional swap below
    #     it, so a PBO frame costs TWO SDL_GL_SwapBuffers calls.
    s = sub1(s,
             r'(\t\t\tglBindBufferARB\(GL_PIXEL_UNPACK_BUFFER_EXT, 0\);\n'
             r'\t\t\tglCallList\(sdl\.opengl\.displaylist\);\n)'
             r'\t\t\tSDL_GL_SwapBuffers\(\);\n',
             r'\1',
             "drop the duplicate swap on the PBO path")
    write(p, s)

# ================================================== FPU: soft-float on both slices
# Daum picks its FPU core in fpu.cpp on C_FPU_X86, which configure.ac sets only
# for x86/x86_64.  A universal build therefore gets 80-bit x87 on the Intel
# slice and 53-bit `double` on Apple Silicon -- and OLE2DISP.DLL in Windows 3.1
# tests for exactly that difference, aborting emulation when it finds it.
#
# Replace the choice outright.  Both slices now use SoftFloat-3e, so they agree
# bit-for-bit and save states carry across.  See
# vendor/fpu_instructions_softfloat.h for the full reasoning.
p = os.path.join(root, 'src', 'fpu', 'fpu.cpp')
if not os.path.exists(p): bail("src/fpu/fpu.cpp is missing")
s = read(p)

# FPU_FLDCW is the one counted op that does NOT live in the soft-float header --
# it is a plain non-static function here, which is exactly why one hook covers
# both CPU cores: core_dynrec/dyn_fpu.h emits
# `gen_call_function_R((void*)&FPU_FLDCW, ...)` and so calls this same symbol.
#
# It earns its place in the histogram because it is how the guest changes
# precision control and rounding mode -- the settings the whole 80-bit story
# rests on.  A workload that never touches it is running at whatever DOS left
# in the control word.
if 'DBFPU_HIT(DBF_FLDCW)' not in s:
    # The include has to come FIRST.  FPU_FLDCW is defined at fpu.cpp:33, well
    # above the `#include "fpu_instructions_softfloat.h"` at :49 that would
    # otherwise drag dbfpu.h in -- so hooking it without adding the include here
    # put a use 15 lines before the declaration, and the build died with
    #     error: use of undeclared identifier 'DBF_FLDCW'
    # Checking that an identifier is reachable in a file is not the same as
    # checking it is reachable at the line that uses it.
    s = sub1(s,
             r'(#include "fpu\.h"\n)',
             r'\1#include "dbfpu.h"\t/* coverage counters -- must precede FPU_FLDCW below */\n',
             "give fpu.cpp the FPU histogram header before its first use")
    s = sub1(s,
             r'(void FPU_FLDCW\(PhysPt addr\)\{\n)',
             r'\1\tDBFPU_HIT(DBF_FLDCW);\n',
             "count FPU_FLDCW for the coverage histogram")

if 'fpu_instructions_softfloat.h' not in s:
    s = sub1(s,
             r'#if C_FPU_X86\n'
             r'#include "fpu_instructions_x86\.h"\n'
             r'#else\n'
             r'#include "fpu_instructions\.h"\n'
             r'#endif\n',
             '/* Both architectures use the soft-float core: identical arithmetic on\n'
             ' * every slice, and 80-bit precision even where the host has no x87.\n'
             ' * C_FPU_X86 is deliberately ignored -- see the header. */\n'
             '#include "fpu_instructions_softfloat.h"\n',
             "select the soft-float FPU core on every architecture")
    write(p, s)

# THE DYNAMIC CORE HAS ITS OWN COPY OF THE FPU.
#
# Patching fpu.cpp is not enough, and this is the single most consequential
# thing in this file.  src/cpu/core_dynrec/dyn_fpu.h -- pulled in by
# core_dynrec.cpp through decoder.h -- carries its own copy of the same
# selection:
#
#     #if C_FPU_X86
#     #include "../../fpu/fpu_instructions_x86.h"
#     #else
#     #include "../../fpu/fpu_instructions.h"
#     #endif
#
# The entry points in both headers are `static`, so each translation unit gets
# its own set, and dyn_fpu.h emits calls to ITS copy via
# gen_call_function_R((void*)&FPU_FADD_EA, ...).  Fixing fpu.cpp therefore fixed
# the interpreter and left the recompiler on Daum's 53-bit `double` core --
# which is the core this build ships as its default, and the whole reason the
# AArch64 backend exists.
#
# It presented as an exact signature in verify-bundle.sh's new cross-core check:
#
#     core=normal   00999517642299539456 | 2 -1 | I0
#     core=dynamic  00999517642299539600 | 2 -1 | F0
#
# ...9600 is the double core's answer, recorded verbatim in
# vendor/bochs-fpu/test/README.md; F0 is a masked overflow returning a finite
# number, because the double core has no exception-mask handling at all.  So
# under core=dynamic the Windows 3.1 OLE fix did not apply, and neither did any
# of the rest of it.
#
# Nothing said so.  daum_audit_features() reported
# "FPU core = SoftFloat-3e (80-bit, identical on every slice)" by reading
# fpu.cpp, which was true about one of the two FPU cores in the tree.
#
# Safe to point at the same header: it defines nothing with external linkage, so
# two TUs including it do not clash, and dyn_fpu.h's own FPU_FDECSTP /
# FPU_FINCSTP / FPU_FNSTCW / FPU_FFREE appear in neither FPU header, so its
# pre-definitions do not collide either.  Both facts are pinned by
# vendor/bochs-fpu/test/tu2.cc, which links a second TU and takes the address of
# all 24 entry points the recompiler calls through.
#
# core_dyn_x86/dyn_fpu.h has the identical construct and is deliberately left
# alone: C_DYNAMIC_X86 is never defined here, so that file is not reachable.
p = os.path.join(root, 'src', 'cpu', 'core_dynrec', 'dyn_fpu.h')
if not os.path.exists(p): bail("src/cpu/core_dynrec/dyn_fpu.h is missing")
s = read(p)
if 'fpu_instructions_softfloat.h' not in s:
    s = sub1(s,
             r'#if C_FPU_X86\n'
             r'#include "\.\./\.\./fpu/fpu_instructions_x86\.h"\n'
             r'#else\n'
             r'#include "\.\./\.\./fpu/fpu_instructions\.h"\n'
             r'#endif\n',
             '/* The dynamic core must use the SAME FPU as the interpreter.  It used\n'
             ' * to select its own here, and got Daum\'s 53-bit double core while\n'
             ' * fpu.cpp got SoftFloat -- so core=dynamic and core=normal computed\n'
             ' * different answers.  C_FPU_X86 is ignored on both sides.\n'
             ' * Pinned by the core=normal/core=dynamic comparison in\n'
             ' * verify-bundle.sh, which fails outright if these two diverge. */\n'
             '#include "../../fpu/fpu_instructions_softfloat.h"\n',
             "give the dynamic recompiler the soft-float FPU core")
    write(p, s)

# ...and src/cpu now compiles a TU that includes the SoftFloat headers, so it
# needs the same include path src/fpu already has.  Without this the build fails
# outright rather than silently, but only after a full dependency build, so it
# is worth not finding out that way.
p = os.path.join(root, 'src', 'cpu', 'Makefile.am')
s = read(p)
if 'softfloat' not in s:
    s = sub1(s, r'AM_CPPFLAGS = -I\$\(top_srcdir\)/include\n',
             'AM_CPPFLAGS = -I$(top_srcdir)/include -I$(top_srcdir)/src/softfloat\n',
             "give src/cpu the SoftFloat include path (core_dynrec needs it)")
    write(p, s)

# src/fpu builds the glue; it needs to see src/softfloat for the SoftFloat headers.
p = os.path.join(root, 'src', 'fpu', 'Makefile.am')
s = read(p)
if 'softfloat' not in s:
    s = sub1(s, r'AM_CPPFLAGS = -I\$\(top_srcdir\)/include\n',
             'AM_CPPFLAGS = -I$(top_srcdir)/include -I$(top_srcdir)/src/softfloat\n',
             "give src/fpu the SoftFloat include path")
    s = sub1(s, r'(libfpu_a_SOURCES = fpu\.cpp fpu_instructions\.h \\\n)',
             r'\1                   fpu_instructions_softfloat.h \\\n',
             "add the soft-float core to src/fpu/Makefile.am")
    write(p, s)

# A convenience library for SoftFloat itself.  Generated rather than vendored so
# the file list cannot drift from what is actually installed.
sfdir = os.path.join(root, 'src', 'softfloat')
if os.path.isdir(sfdir):
    srcs = []
    for sub in ('softfloat3e', 'fpu'):
        d = os.path.join(sfdir, sub)
        for dirpath, _, files in os.walk(d):
            for f in sorted(files):
                if f.endswith('.cc'):
                    rel = os.path.relpath(os.path.join(dirpath, f), sfdir)
                    srcs.append(rel)
    if not srcs: bail("no SoftFloat sources found under src/softfloat")
    body = ("# Generated by lib/daum.sh from the vendored tree -- do not hand-edit.\n"
            "# subdir-objects: the sources live in softfloat3e/ and fpu/, and without\n"
            "# this automake puts every object in one directory and warns (fatally,\n"
            "# on automake 1.16+).\n"
            "AUTOMAKE_OPTIONS = subdir-objects\n"
            "AM_CPPFLAGS = -I$(top_srcdir)/include -I$(top_srcdir)/src/softfloat \\\n"
            "              -I$(top_srcdir)/src/softfloat/softfloat3e/include \\\n"
            "              -I$(top_srcdir)/src/softfloat/softfloat3e/8086-SSE \\\n"
            "              -I$(top_srcdir)/src/softfloat/fpu \\\n"
            # Bochs' x87 sources expect Bit8u..Bit64s to already exist -- in
            # Bochs they come from bochs.h, which we are not carrying.  Force
            # the shim in ahead of everything rather than patching upstream
            # headers.  Safe for the whole library: none of these translation
            # units ever include a Daum header, so the typedefs cannot clash.
            "              -include $(top_srcdir)/src/softfloat/fpu/bochs_shim_config.h\n\n"
            "noinst_LIBRARIES = libsoftfloat.a\n"
            "libsoftfloat_a_SOURCES = \\\n\t"
            + " \\\n\t".join(srcs) + "\n")
    write(os.path.join(sfdir, 'Makefile.am'), body)
    sys.stderr.write("  generated src/softfloat/Makefile.am (%d sources)\n" % len(srcs))

# link it, and build the directory
p = os.path.join(root, 'src', 'Makefile.am')
s = read(p)
if 'libsoftfloat' not in s:
    s = sub1(s, r'SUBDIRS = cpu debug dos fpu ',
             'SUBDIRS = cpu debug dos softfloat fpu ',
             "build src/softfloat before src/fpu")
    s = sub1(s, r'(dosbox_LDADD = cpu/libcpu\.a )',
             r'\1softfloat/libsoftfloat.a ',
             "link libsoftfloat into dosbox")
    write(p, s)

p = os.path.join(root, 'configure.ac')
s = read(p)
if 'src/softfloat/Makefile' not in s:
    s = sub1(s, r'(src/fpu/Makefile\n)', r'src/softfloat/Makefile\n\1',
             "add src/softfloat/Makefile to AC_CONFIG_FILES")
    write(p, s)

# ================================================== src/gui/Makefile.am
p = os.path.join(root, 'src', 'gui', 'Makefile.am')
if not os.path.exists(p): bail("src/gui/Makefile.am is missing")
s = read(p)
if 'openglhq.cpp' not in s:
    s = sub1(s, r'(libgui_a_SOURCES = sdlmain\.cpp )',
             r'\1openglhq.cpp openglhq.h \\\n\tSDL_openglhq_pass1.h SDL_openglhq_pass2.h \\\n\tSDL_openglhq_pass3.h SDL_openglhq_table.h ',
             "add openglhq.cpp to src/gui/Makefile.am")
    write(p, s)

# ================================================== 64-bit save-state casts
# Daum's save-state code stores pointers in Bit32u, because Daum only ever
# shipped as a 32-bit Windows binary.  On any 64-bit target clang rejects it:
#   error: cast from pointer to smaller type 'Bit32u' loses information
# This is not arm64-specific -- the x86_64 build hits it identically.
#
# Crucially, the SAVE FORMAT does not have to change.  What actually gets
# serialised is offsets and indices, not pointers:
#   dbopl/opl   wavebase_idx, cur_wform_idx -- Bit32u *offsets* from a table
#               base, which genuinely fit in 32 bits
#   memory      pagehandler_idx -- Bit8u indices
#   dma/pic     indices into const void* lookup tables
# Only the intermediate pointer arithmetic needs to widen, so save states stay
# byte-compatible with Daum on Windows.  Bitu is the right type: Daum's own
# acinclude.m4 defines it as Bit64u when SIZEOF_INT_P == 8.

def widen_region(s, start_pat, end_pat, expect, what):
    """Replace (Bit32u) with (Bitu) only between two anchors."""
    m = re.search(start_pat + r'.*?' + end_pat, s, re.S)
    if not m:
        bail("could not locate region for: %s" % what)
    region = m.group(0)
    new_region, n = re.subn(r'\(Bit32u\)', '(Bitu)', region)
    if n != expect:
        bail("expected %d casts in region, found %d: %s" % (expect, n, what))
    return s[:m.start()] + new_region + s[m.end():]

# --- memory.cpp: the page-handler lookup table -------------------------------
p = os.path.join(root, 'src', 'hardware', 'memory.cpp')
if os.path.exists(p):
    s = read(p)
    if 'Bitu Memory_PageHandler_table' not in s:
        s = sub1(s, r'Bit32u Memory_PageHandler_table\[\]',
                 'Bitu Memory_PageHandler_table[]',
                 "widen Memory_PageHandler_table to Bitu")
        s = widen_region(s, r'Bitu Memory_PageHandler_table\[\]', r'\n\};', 19,
                         "Memory_PageHandler_table initialiser")
        s = sub1(s, r'sizeof\(Memory_PageHandler_table\) / sizeof\(Bit32u\)',
                 'sizeof(Memory_PageHandler_table) / sizeof(Bitu)',
                 "fix the Memory_PageHandler_table element-count divisor")
        s = sub1(s, r'\(Bit32u\) memory\.phandlers\[lcv\]',
                 '(Bitu) memory.phandlers[lcv]',
                 "widen the page-handler comparison")
        write(p, s)

# --- dma.cpp: callback lookup ------------------------------------------------
p = os.path.join(root, 'src', 'hardware', 'dma.cpp')
if os.path.exists(p):
    s = read(p)
    if 'POD_State_Find_DMA_Callback( Bitu addr )' not in s:
        s = sub1(s, r'POD_State_Find_DMA_Callback\( Bit32u addr \)',
                 'POD_State_Find_DMA_Callback( Bitu addr )',
                 "widen POD_State_Find_DMA_Callback's parameter")
        s = sub1(s, r'Bit32u POD_State_Index_DMA_Callback',
                 'Bitu POD_State_Index_DMA_Callback',
                 "widen POD_State_Index_DMA_Callback's return type")
        # The table is const void*[], so sizeof(void*) is the correct divisor.
        s = sub1(s, r'sizeof\(dma_state_callback_table\) / sizeof\(Bit32u\)',
                 'sizeof(dma_state_callback_table) / sizeof(void *)',
                 "fix the dma_state_callback_table element-count divisor")
        s = subn(s, r'\(Bit32u\) dma_state_callback_table', '(Bitu) dma_state_callback_table', 2,
                 "widen dma_state_callback_table casts")
        s = subn(s, r'POD_State_Find_DMA_Callback\( \(Bit32u\) \(callback\) \)',
                 'POD_State_Find_DMA_Callback( (Bitu) (callback) )', 2,
                 "widen the POD_State_Find_DMA_Callback call sites")
        write(p, s)

# --- pic.cpp: event/timer lookup ---------------------------------------------
p = os.path.join(root, 'src', 'hardware', 'pic.cpp')
if os.path.exists(p):
    s = read(p)
    if 'Bitu pic_addr' not in s:
        s = sub1(s, r'Bit32u pic_addr;', 'Bitu pic_addr;',
                 "widen pic_addr")
        s = sub1(s, r'pic_addr = \(Bit32u\) pic_queue\.entries\[lcv\]\.next;',
                 'pic_addr = (Bitu) pic_queue.entries[lcv].next;',
                 "widen the pic_queue pointer read")
        s = sub1(s, r'pic_addr == \(Bit32u\) &pic_queue\.entries\[lcv2\]',
                 'pic_addr == (Bitu) &pic_queue.entries[lcv2]',
                 "widen the pic_queue pointer comparison")
        s = subn(s, r'sizeof\((pic_state_(?:event|timer)_table)\) / sizeof\(Bit32u\)',
                 r'sizeof(\1) / sizeof(void *)', 2,
                 "fix the pic_state_*_table element-count divisors")

        # The event/timer lookup helpers take and return pointer values.  All of
        # them are local to pic.cpp -- no header declares them -- so widening
        # the signatures is self-contained.  The two call sites that cast the
        # result back to a function pointer (PIC_EventHandler, TIMER_TickHandler)
        # then become valid pointer-width conversions.
        s = subn(s, r'Bit16u (PIC_State_Find(?:Event|Timer))\( Bit32u addr \)',
                 r'Bit16u \1( Bitu addr )', 2,
                 "widen the PIC_State_Find* parameters")
        s = subn(s, r'Bit32u (PIC_State_Index(?:Event|Timer))\( Bit16u index \)',
                 r'Bitu \1( Bit16u index )', 2,
                 "widen the PIC_State_Index* return types")

        # Every remaining (Bit32u) in this file is one of these pointer casts:
        # four on the lookup tables, two at the call sites.
        s = subn(s, r'\(Bit32u\)', '(Bitu)', 6,
                 "widen the remaining pic.cpp pointer casts")
        write(p, s)

# --- voodoo_opengl.cpp / voodoo_data.h: GLhandleARB is a pointer on macOS ----
# Apple declares GLhandleARB as void * where every other platform makes it an
# unsigned int.  Daum stores the three shader handles in UINT32 fields, which
# truncates on a 64-bit Mac.  The fields are never serialised -- they are pure
# runtime GL handles, cast straight back to GLhandleARB at every use -- so
# widening them to uintptr_t is safe and leaves the save format untouched.
# Note the existing "so_vertex_shader >= 0" tests stay tautologically true, as
# they already were with UINT32; that behaviour is unchanged.
p = os.path.join(root, 'src', 'hardware', 'voodoo_data.h')
if os.path.exists(p):
    s = read(p)
    if 'uintptr_t\t\t\tso_shader_program' not in s and 'uintptr_t so_shader_program' not in s:
        s = subn(s, r'UINT32(\s+)(so_shader_program|so_vertex_shader|so_fragment_shader);',
                 r'uintptr_t\1\2;', 3,
                 "widen the voodoo shader handle fields to pointer width")
        write(p, s)

p = os.path.join(root, 'src', 'hardware', 'voodoo_opengl.cpp')
if os.path.exists(p):
    s = read(p)
    if '(uintptr_t)m_hProgramObject' not in s:
        s = subn(s, r'\(UINT32\)(m_hProgramObject|m_hVertexShader|m_hFragmentShader)',
                 r'(uintptr_t)\1', 3,
                 "widen the voodoo shader handle casts")
        write(p, s)

# --- ide.cpp: std::min over mismatched integer types --------------------------
# multiple_sector_count is Bitu, sectcount is unsigned int.  Those are the same
# type in a 32-bit build, so std::min deduced fine for Daum; on a 64-bit target
# Bitu widens and template deduction fails.  Every other MIN() in this file
# already casts explicitly, so casting at the call site matches the file's own
# convention and avoids touching the macro (whose _MSC_VER branch is a ternary
# that would double-evaluate its arguments).
p = os.path.join(root, 'src', 'hardware', 'ide.cpp')
if os.path.exists(p):
    s = read(p)
    if 'MIN(ata->multiple_sector_count,(Bitu)sectcount)' not in s:
        s = subn(s, r'MIN\(ata->multiple_sector_count,sectcount\)',
                 'MIN(ata->multiple_sector_count,(Bitu)sectcount)', 5,
                 "make the ide.cpp MIN() operand types agree")
        write(p, s)

# --- midi_synth.h: FluidSynth 2.x const-qualified the log callback -----------
# fluid_log_function_t went from  void (*)(int, char *, void *)  in 1.x to
# void (*)(int, const char *, void *)  in 2.0.  Daum predates that.  The
# callback never mutates the message, so const-qualifying is behaviour-neutral;
# it is version-guarded so the file still builds against a 1.x FluidSynth.
p = os.path.join(root, 'src', 'gui', 'midi_synth.h')
if os.path.exists(p):
    s = read(p)
    if 'DOSBOX_FLUID_LOG_STR' not in s:
        s = sub1(s,
                 r'static void synth_log\(int level, char \*message, void \*data\) \{',
                 '#if defined(FLUIDSYNTH_VERSION_MAJOR) && FLUIDSYNTH_VERSION_MAJOR >= 2\n'
                 '#define DOSBOX_FLUID_LOG_STR const char *\n'
                 '#else\n'
                 '#define DOSBOX_FLUID_LOG_STR char *\n'
                 '#endif\n'
                 'static void synth_log(int level, DOSBOX_FLUID_LOG_STR message, void *data) {',
                 "const-qualify the fluidsynth log callback for the 2.x API")
        write(p, s)

# --- midi_synth.h: re-enable Daum's vendored FluidSynth internals ------------
# Daum declares new_fluid_midi_parser / fluid_midi_parser_parse /
# fluid_log_config extern "C", vendors complete copies of all three, then
# #if 0's the copies out -- because FluidSynth 1.x still exported them.  2.x
# does not, so the copies have to come back.  Everything they call is either
# vendored alongside (fluid_midi_event_length, line 126) or still public in 2.x
# (fluid_default_log_function, fluid_midi_event_set_sysex).
#
# There are exactly three "#if 0" blocks in this file and all three are these,
# so the count assertion below is what keeps this honest.
p = os.path.join(root, 'src', 'gui', 'midi_synth.h')
if os.path.exists(p):
    s = read(p)
    if 'DOSBOX_VENDORED_FLUID_INTERNALS' not in s:
        s = subn(s, r'#if 0\n',
                 '#if 1 /* DOSBOX_VENDORED_FLUID_INTERNALS: 2.x stopped exporting these */\n',
                 3, "re-enable the three vendored FluidSynth internals")

        # The vendored parser passes FALSE to fluid_midi_event_set_sysex.
        # FluidSynth 1.x got TRUE/FALSE from GLib via fluid_sys.h; 2.x dropped
        # the GLib dependency and its public headers define neither.  Daum
        # already keeps a small block of these shims, so this joins it.
        s = sub1(s, r'(#define FLUID_NEW\(_t\)\s+\(_t\*\)malloc\(sizeof\(_t\)\)\n)',
                 r'\1'
                 '/* 1.x inherited these from glib via fluid_sys.h; 2.x does not. */\n'
                 '#ifndef FALSE\n#define FALSE 0\n#endif\n'
                 '#ifndef TRUE\n#define TRUE 1\n#endif\n',
                 "define TRUE/FALSE for the vendored parser")

        # Daum's struct _fluid_midi_event_t is a verbatim copy of libfluidsynth's
        # PRIVATE layout, and parsed events are handed to
        # fluid_midi_router_handle_midi_event(), which reads them through the
        # library's own definition.  The two agree today, but nothing enforces
        # that -- and a mismatch would not crash, it would play wrong notes.
        # Probe it once at Open() using only public setters, and refuse to run
        # the soft synth rather than emit silently corrupt MIDI.
        probe = (
'\t\t/* Verify our copy of fluidsynth\'s private event layout still agrees\n'
'\t\t * with the library\'s, using only public setters to write it. */\n'
'\t\t{\n'
'\t\t\tfluid_midi_event_t *probe = new_fluid_midi_event();\n'
'\t\t\tbool layout_ok = false;\n'
'\t\t\tif (probe != NULL) {\n'
'\t\t\t\tfluid_midi_event_set_type(probe, 0x90);\n'
'\t\t\t\tfluid_midi_event_set_channel(probe, 5);\n'
'\t\t\t\tfluid_midi_event_set_key(probe, 64);\n'
'\t\t\t\tfluid_midi_event_set_velocity(probe, 100);\n'
'\t\t\t\tlayout_ok = (probe->type == 0x90 && probe->channel == 5 &&\n'
'\t\t\t\t             probe->param1 == 64 && probe->param2 == 100);\n'
'\t\t\t\tdelete_fluid_midi_event(probe);\n'
'\t\t\t}\n'
'\t\t\tif (!layout_ok) {\n'
'\t\t\t\tLOG_MSG("SYNTH: libfluidsynth event layout differs from the one DOSBox assumes -- disabling soft synth");\n'
'\t\t\t\tdelete_fluid_synth(synth_soft);\n'
'\t\t\t\tdelete_fluid_settings(settings);\n'
'\t\t\t\treturn false;\n'
'\t\t\t}\n'
'\t\t}\n\n')
        s = sub1(s, r'(\t\t/\* Allocate one event to store the input data \*/\n)',
                 probe + r'\1',
                 "insert the fluidsynth event-layout probe")
        write(p, s)

# --- src/debug: make the curses debugger safe inside an .app bundle ---------
# DEBUG_Init() calls initscr() unconditionally at startup.  With no controlling
# terminal -- which is exactly the case when the bundle is double-clicked in
# Finder -- ncurses prints "Error opening terminal" and calls exit(1).  So
# simply turning on --enable-debug would make the app unlaunchable for every
# normal user in exchange for a feature only reachable from a terminal.
#
# Gate the curses UI on actually having a terminal.  Launched from Terminal the
# debugger works as upstream intends; launched from Finder DOSBox runs normally
# and the debugger reports itself unavailable instead of killing the process.
p = os.path.join(root, 'src', 'debug', 'debug_gui.cpp')
if os.path.exists(p):
    s = read(p)
    if 'dbgui_started' not in s:
        s = sub1(s, r'(#include <curses\.h>\n)',
                 r'\1#include <unistd.h>\t/* isatty, for the tty check below */\n',
                 "include unistd.h in debug_gui.cpp")
        s = sub1(s,
                 r'void DBGUI_StartUp\(void\) \{\n\t/\* Start the main window \*/\n',
                 'static bool dbgui_started = false;\n'
                 'bool DBGUI_Available(void) { return dbgui_started; }\n\n'
                 'void DBGUI_StartUp(void) {\n'
                 '\t/* No terminal means no curses.  initscr() would exit(1) here,\n'
                 '\t * which inside an .app bundle looks like a launch failure. */\n'
                 '\tif (!isatty(0) || !isatty(1) || getenv("TERM") == NULL) {\n'
                 # NB: re.subn processes escapes in the replacement, so a C-level
                 # "\n" has to be written \\\\n here -- \\n would emit a real
                 # newline and produce an unterminated string literal.
                 '\t\tfprintf(stderr, "DEBUG: no controlling terminal -- debugger disabled.\\\\n"\n'
                 '\t\t                "DEBUG: run dosbox from a terminal to use it.\\\\n");\n'
                 '\t\tfflush(stderr);\n'
                 '\t\treturn;\n'
                 '\t}\n'
                 '\t/* Start the main window */\n',
                 "gate DBGUI_StartUp on having a tty")
        s = sub1(s, r'(\tMakeSubWindows\(\);\n)', r'\1\tdbgui_started = true;\n',
                 "record that the debugger UI came up")
        # vsnprintf returns the length it WOULD have written, and -1 on error.
        # Daum assigns that straight into a size_t and then indexes buf[len-1]
        # on a 512-byte stack buffer: any message over 510 chars writes past
        # the end, and -1 becomes SIZE_MAX.  This was unreachable while the
        # debugger was off, because nothing routed logging through here --
        # turning on C_DEBUG sends every LOG_MSG through it, which is why
        # enabling the debugger turned into a segfault during startup.
        s = sub1(s,
                 r'\tlen = vsnprintf\(buf,sizeof\(buf\)-2,format,msg\);',
                 '\tint written = vsnprintf(buf,sizeof(buf)-2,format,msg);',
                 "capture vsnprintf's return in an int")
        # The clamp is sizeof(buf)-3, not sizeof(buf)-2.
        #
        # vsnprintf(buf, N, ...) writes at most N-1 characters plus a NUL, so
        # with N = sizeof(buf)-2 a truncated message is sizeof(buf)-3 long.
        # Clamping to sizeof(buf)-2 makes buf[len-1] read the terminator rather
        # than the last character: the "is there already a newline?" test then
        # always says no, and the '\n' gets appended AFTER the NUL, where it is
        # never printed.  Truncated messages silently lost their line break.
        #
        # Off by exactly one, and only on messages over ~509 characters, which
        # is why it survived the bounds fix it was part of.
        s = sub1(s,
                 r'\t/\* Add newline if not present \*/\n',
                 '\tif (written < 0) len = 0;\n'
                 '\telse if ((size_t)written > sizeof(buf)-3) len = sizeof(buf)-3;\n'
                 '\telse len = (size_t)written;\n\n'
                 '\t/* Add newline if not present */\n',
                 "clamp the formatted length before indexing buf")

        # With C_DEBUG on, the plain-stderr branch of DEBUG_ShowMsg is compiled
        # out and messages go only to the curses log pane.  Without that pane
        # they would vanish, taking ordinary DOSBox logging with them.
        s = sub1(s,
                 r'(\tif \(debuglog != NULL\) \{\n\t\tfprintf\(debuglog,"%s",buf\);\n'
                 r'\t\tfflush\(debuglog\);\n\t\}\n)',
                 r'\1'
                 '\tif (!dbgui_started) {\t/* no debugger pane: fall back to stderr */\n'
                 '\t\tfprintf(stderr,"%s",buf);\n'
                 '\t\tfflush(stderr);\n'
                 '\t\treturn;\n'
                 '\t}\n',
                 "send log messages to stderr when the debugger UI is absent")
        write(p, s)

# Upstream already has the idea of "a debug build that does not grab the
# console", but only wires it on Windows -- the help text even says
# "debug+win32 only".  Honour -noconsole everywhere, so there is an explicit
# way to run from a terminal without the debugger taking the screen, alongside
# the automatic no-tty detection.
p = os.path.join(root, 'src', 'gui', 'sdlmain.cpp')
if os.path.exists(p):
    s = read(p)
    if 'noconsole on any platform' not in s:
        s = sub1(s,
                 r'(#if defined\(WIN32\)\n'
                 r'\tif \(control->cmdline->FindExist\("-noconsole"\)\) \{\n'
                 r'\t\tShowWindow\( GetConsoleWindow\(\), SW_HIDE \);\n'
                 r'\t\tDestroyWindow\(GetConsoleWindow\(\)\);\n'
                 r'\t\} else\n)'
                 r'#endif\n',
                 r'\1'
                 '#else\t/* honour -noconsole on any platform, not just win32 */\n'
                 '\tif (control->cmdline->FindExist("-noconsole")) {\n'
                 '\t\t/* nothing to hide: just skip the curses debugger */\n'
                 '\t} else\n'
                 '#endif\n',
                 "honour -noconsole outside win32")
        s = sub1(s,
                 r'-noconsole                              '
                 r"Don't show console \(debug\+win32 only\)",
                 "-noconsole                              "
                 "Don't show console / debugger",
                 "correct the -noconsole help text")
        write(p, s)

# Every log group defaults to enabled.  Upstream can afford that because a
# debug build is a deliberate, separate build; here C_DEBUG is always on, and
# with it every LOG() in DOSBox stops being a no-op struct and starts
# formatting a string and writing it to stderr.  Booting a game emits
# thousands -- SBLASTER IRQs, every file open, every VGA mode change -- which
# is slow enough to be mistaken for the emulator hanging.
#
# Default them off so a debug build performs like a normal one.  "Nothing is
# lost" was the original claim here, on the grounds that LOG_ERROR bypasses the
# enable check.  Half right, and worth writing down exactly, because the half
# that was wrong is a diagnostic channel:
#
#     debug_gui.cpp:78
#     if ((d_severity!=LOG_ERROR) && (!loggrp[d_type].enabled)) return;
#
# Only LOG_ERROR bypasses it.  Counting call sites in the tree:
#
#     LOG_NORMAL   251   trace chatter -- this is the noise, keep it gated
#     LOG_WARN     142   "something is wrong but I carried on" -- was lost
#     LOG_ERROR    231   always printed, gated or not
#
# 142 warnings went silent by default, and warnings are exactly what you want
# when a game misbehaves and nothing has crashed.  Reverting the group default
# would bring back the 251 as well, which is the thing that made the emulator
# look hung.
#
# So gate on severity instead: LOG_NORMAL obeys the group, LOG_WARN and
# LOG_ERROR always print.  The performance goal is met by the same edit that
# keeps the diagnostics.
p = os.path.join(root, 'src', 'debug', 'debug_gui.cpp')
if os.path.exists(p):
    s = read(p)
    if 'DOSBOX_QUIET_LOG_DEFAULT' not in s:
        s = sub1(s,
                 r'\t\tProp_bool\* Pbool = sect->Add_bool\(buf,Property::Changeable::Always,true\);\n'
                 r'\t\tPbool->Set_help\("Enable/Disable logging of this type\."\);\n',
                 '\t\t/* DOSBOX_QUIET_LOG_DEFAULT: off unless asked for -- see lib/daum.sh */\n'
                 '\t\tProp_bool* Pbool = sect->Add_bool(buf,Property::Changeable::Always,false);\n'
                 '\t\tPbool->Set_help("Enable/Disable logging of this type.");\n',
                 "default the log groups to off")
        s = sub1(s,
                 r'\tif \(\(d_severity!=LOG_ERROR\) && \(!loggrp\[d_type\]\.enabled\)\) return;',
                 '\t/* DOSBOX_QUIET_LOG_DEFAULT: the groups default to off (see lib/daum.sh),\n'
                 '\t * so only the trace severity may be gated by them.  Warnings and errors\n'
                 '\t * print regardless -- silencing 142 LOG_WARN sites to make a debug build\n'
                 '\t * quiet was throwing away the diagnostics along with the noise. */\n'
                 '\tif ((d_severity==LOG_NORMAL) && (!loggrp[d_type].enabled)) return;',
                 "let LOG_WARN through even when its group is off")
        write(p, s)

p = os.path.join(root, 'src', 'debug', 'debug_inc.h')
if os.path.exists(p):
    s = read(p)
    if 'DBGUI_Available' not in s:
        s = sub1(s, r'(void DBGUI_StartUp\(void\);\n)',
                 r'\1bool DBGUI_Available(void);\n',
                 "declare DBGUI_Available")
        write(p, s)

p = os.path.join(root, 'src', 'debug', 'debug.cpp')
if os.path.exists(p):
    s = read(p)
    if 'DBGUI_Available' not in s:
        # Alt-Pause must not drop into a debugger that was never initialised:
        # dbg.win_* are NULL and every curses call would fault.
        # DEBUG_Init() paints the debugger panes once at startup, before anything
        # has enabled the debugger:
        #   DEBUG_Init -> DEBUG_DrawScreen -> DrawCode -> wprintw(NULL, ...)
        # With the UI skipped, dbg.win_* are NULL and ncurses dereferences one at
        # offset 0x80.  Every curses call in debug.cpp lives in DrawData/DrawCode/
        # DrawRegisters/DrawVariables, and the only paths to those are through
        # DEBUG_DrawScreen or the debugger's own command loop -- which cannot run
        # unless DEBUG_Enable succeeded.  So this one guard covers all of them.
        s = sub1(s,
                 r'void DEBUG_DrawScreen\(void\) \{\n',
                 'void DEBUG_DrawScreen(void) {\n'
                 '\tif (!DBGUI_Available()) return;\t/* panes were never created */\n',
                 "skip drawing when the debugger UI does not exist")
        s = sub1(s,
                 r'void DEBUG_Enable\(bool pressed\) \{\n\tif \(!pressed\)\n\t\treturn;\n',
                 'void DEBUG_Enable(bool pressed) {\n'
                 '\tif (!pressed)\n\t\treturn;\n'
                 '\tif (!DBGUI_Available()) {\n'
                 '\t\tLOG_MSG("DEBUG: debugger unavailable -- no controlling terminal");\n'
                 '\t\treturn;\n'
                 '\t}\n',
                 "refuse to enter the debugger when its UI never started")
        s = sub1(s,
                 r'\tCDebugVar::DeleteAll\(\);\n\tcurs_set\(old_cursor_state\);\n\tendwin\(\);\n'
                 r'\t#ifndef WIN32\n\ttcsetattr\(0, TCSANOW,&consolesettings\);\n',
                 '\tCDebugVar::DeleteAll();\n'
                 '\tif (!DBGUI_Available()) return;\t/* nothing to tear down */\n'
                 '\tcurs_set(old_cursor_state);\n\tendwin();\n'
                 '\t#ifndef WIN32\n\ttcsetattr(0, TCSANOW,&consolesettings);\n',
                 "skip the curses teardown when it was never set up")
        write(p, s)

# --- dbopl.cpp / opl.cpp: waveform base offsets ------------------------------
# These compute an offset from a table base and store it in a Bit32u.  Widening
# only the casts keeps the stored offset 32-bit, so the save format is
# unchanged, while the arithmetic itself becomes pointer-safe.
p = os.path.join(root, 'src', 'hardware', 'dbopl.cpp')
if os.path.exists(p):
    s = read(p)
    if '(Bitu) &WaveTable' not in s:
        s = sub1(s,
                 r'wavebase_idx\[lcv1\]\[lcv2\] = \(Bit32u\) chip\.chan\[lcv1\]\.op\[lcv2\]\.waveBase - \(Bit32u\) &WaveTable;',
                 'wavebase_idx[lcv1][lcv2] = (Bit32u)((Bitu) chip.chan[lcv1].op[lcv2].waveBase - (Bitu) &WaveTable);',
                 "widen the dbopl waveBase offset computation")
        s = sub1(s,
                 r'\(Bit16s \*\) \(\(Bit32u\) wavebase_idx\[lcv1\]\[lcv2\] \+ \(Bit32u\) &WaveTable\)',
                 '(Bit16s *) ((Bitu) &WaveTable + wavebase_idx[lcv1][lcv2])',
                 "widen the dbopl waveBase restore")
        write(p, s)

p = os.path.join(root, 'src', 'hardware', 'opl.cpp')
if os.path.exists(p):
    s = read(p)
    if '(Bitu) &wavtable' not in s:
        s = sub1(s,
                 r'cur_wform_idx\[lcv\] = \(\(Bit32u\) \(op\[lcv\]\.cur_wform\)\) - \(\(Bit32u\) &wavtable\);',
                 'cur_wform_idx[lcv] = (Bit32u)(((Bitu) (op[lcv].cur_wform)) - ((Bitu) &wavtable));',
                 "widen the opl cur_wform offset computation")
        s = sub1(s,
                 r'op\[lcv\]\.cur_wform = \(Bit16s \*\) \(\(Bit32u\) &wavtable \+ cur_wform_idx\[lcv\]\);',
                 'op[lcv].cur_wform = (Bit16s *) ((Bitu) &wavtable + cur_wform_idx[lcv]);',
                 "widen the opl cur_wform restore")
        write(p, s)

# ================================================== nullmodem.cpp
# Another pointer compared against an integer with an ordered operator --
# clientsocket is a TCPClientSocket*.  A sweep of the tree found this to be the
# only other instance; the many other `> 0` comparisons in serialport/parport
# (initbps, bytesWritten, cmdpos, neededParam, porthandle, ...) are all on
# genuine integers.
p = os.path.join(root, 'src', 'hardware', 'serialport', 'nullmodem.cpp')
if os.path.exists(p):
    s = read(p)
    if 'clientsocket > 0' in s:
        s = sub1(s, r'setCD\(clientsocket > 0\)', 'setCD(clientsocket != NULL)',
                 "fix pointer-vs-int comparison in nullmodem.cpp")
        write(p, s)

# ================================================== mmath.h: x86 intrinsics
# mmath.h includes <x86intrin.h>/<emmintrin.h> guarded only on compiler
# version, never on architecture, so on arm64 clang it lands in the
# __GNUC_PREREQ(4,1) branch and pulls in emmintrin.h ->
#   error: "This header is only meant to be used on x86 and x64 architecture"
# render.cpp does this correctly -- both its includes and its _mm_* uses sit
# behind #if defined(__SSE__) -- so only mmath.h needs the guard.
p = os.path.join(root, 'src', 'gui', 'mmath.h')
if os.path.exists(p):
    s = read(p)
    if '__x86_64__) || defined(__i386__)' not in s:
        # The block is tab-indented, so match leading whitespace rather than
        # assuming column 0, and span it non-greedily to its closing #endif.
        s = sub1(s,
                 r'([ \t]*#if __GNUC_PREREQ\(4, 4\).*?'
                 r'#include <emmintrin\.h>\n[ \t]*#endif\n)',
                 '#if defined(__x86_64__) || defined(__i386__)\n'
                 r'\1'
                 '#endif /* x86 only -- these headers reject non-x86 targets */\n',
                 "guard mmath.h's x86 intrinsics on architecture",
                 flags=re.S)

        # Guarding the includes is not enough: Herumi's fmath, vendored here for
        # munt's MT-32 tables, also *uses* SSE unconditionally.  Three of those
        # functions are dead code in Daum -- nothing calls expd_v(), exp_ps() or
        # log_ps() -- so they can be compiled out entirely.  fmath::exp() has a
        # portable scalar path behind its own #if, and fmath::log() (reached via
        # LOG2F(), which Tables.cpp does call) is already scalar.
        s = sub1(s, r'(namespace fmath \{)',
                 '/* SSE availability, added for the macOS/arm64 build. */\n'
                 '#if defined(__x86_64__) || defined(__i386__)\n'
                 '#define FMATH_USE_SSE 1\n'
                 '#else\n'
                 '#define FMATH_USE_SSE 0\n'
                 '#endif\n\n'
                 r'\1',
                 "add the FMATH_USE_SSE switch")

        # exp(): take the existing scalar #else branch on non-x86.
        s = sub1(s, r'(const ExpVar<>& expVar = C<>::expVar;\s*\n\s*)#if 1',
                 r'\1#if FMATH_USE_SSE',
                 "switch fmath::exp to its scalar path on non-x86")

        # expd_v() + exp_ps(): SSE-only and unused.
        s = sub1(s, r'(inline void expd_v\(double \*px, int n\))',
                 '#if FMATH_USE_SSE\n' + r'\1',
                 "open the SSE-only block before expd_v()")
        s = sub1(s, r'(inline float log\(float x\))',
                 '#endif /* FMATH_USE_SSE */\n' + r'\1',
                 "close the SSE-only block before log()")

        # log_ps(): SSE-only and unused.
        #
        # The close has to go BEFORE the `#ifndef __CYGWIN__` that precedes
        # log2(), not between it and log2().  Anchoring on `inline float log2`
        # put the #endif inside the CYGWIN guard, where it closed that instead
        # and left the file's pre-existing #endif to close #if FMATH_USE_SSE:
        #
        #     #ifndef __CYGWIN__          <- opened
        #     // cygwin defines log2()...
        #     #endif /* FMATH_USE_SSE */  <- closed __CYGWIN__, not the SSE block
        #     inline float log2(float x)  <- now inside #if FMATH_USE_SSE
        #     #endif                      <- now closes #if FMATH_USE_SSE
        #
        # The file still balanced, so it compiled, and fmath::log2 simply did
        # not exist on arm64 while it did on x86_64.  Nothing in Daum calls it,
        # so nothing broke -- but the two slices got different APIs out of a
        # shared header, which is the class of thing this build exists to stop.
        s = sub1(s, r'(inline __m128 log_ps\(__m128 x\))',
                 '#if FMATH_USE_SSE\n' + r'\1',
                 "open the SSE-only block before log_ps()")
        s = sub1(s, r'(#ifndef __CYGWIN__\n// cygwin defines log2\(\))',
                 '#endif /* FMATH_USE_SSE */\n' + r'\1',
                 "close the SSE-only block before the __CYGWIN__ guard on log2()")
        write(p, s)

# ================================================== sdlmain.cpp: portability
p = os.path.join(root, 'src', 'gui', 'sdlmain.cpp')
if os.path.exists(p):
    s = read(p)

    # (a) `strstr(...) > 0` -- ordered comparison of a pointer against an int.
    #     Six sites.  clang rejects it; the intent is plainly "was it found".
    if re.search(r'strstr\([^()]*\)\s*>\s*0', s):
        s = subn(s, r'(strstr\([^()]*\))\s*>\s*0', r'\1 != NULL', 6,
                 "replace `strstr(...) > 0` with `!= NULL`")

    # (b) SDL_GetDesktopMode() is NOT part of stock SDL 1.2.  It is added by
    #     openglhq.patch, which also patches each platform's mode query
    #     (SDL_QuartzVideo.m, SDL_x11modes.c, SDL_dibvideo.c, SDL_dx5video.c).
    #     Daum needs it for fullscreen sizing whether or not the openglhq video
    #     driver is used, so Daum's dependency on the patched SDL is broader
    #     than just that driver.
    #
    #     Ask SDL_GetVideoInfo() first.  That is SDL 1.2's documented way to get
    #     the DESKTOP mode, and sdl12-compat fills current_w/current_h straight
    #     from SDL20_GetDesktopDisplayMode() (SDL12_compat.c:2487), so it is
    #     exactly the right answer.
    #
    #     SDL_ListModes() is the fallback, and it is NOT the same question: it
    #     returns the available fullscreen modes largest-first, and the largest
    #     supported mode is not necessarily the desktop mode -- on a multi-head
    #     or scaled-Retina setup those differ.  Using it alone was a latent
    #     wrong answer for fullscreen sizing.
    #
    #     In practice GUI_StartUp already fills sdl.desktop.full.* from
    #     SDL_GetVideoInfo() a few lines above the first call site, so this shim
    #     only decides anything when that returned NULL.  Getting it right
    #     anyway costs four lines and removes the need to reason about which
    #     path ran.
    if 'DOSBOX_HAVE_SDL_GETDESKTOPMODE' not in s:
        shim = '''
/* Not part of stock SDL 1.2 -- added by openglhq.patch, which this build does
   not apply.  See lib/daum.sh. */
#define DOSBOX_HAVE_SDL_GETDESKTOPMODE 1
static void SDL_GetDesktopMode(int *w, int *h)
{
\t/* The desktop mode, which is the question being asked. */
\tconst SDL_VideoInfo *vi = SDL_GetVideoInfo();
\tif (vi && vi->current_w > 0 && vi->current_h > 0) {
\t\tif (w) *w = vi->current_w;
\t\tif (h) *h = vi->current_h;
\t\treturn;
\t}
\t/* Fallback: the LARGEST fullscreen mode, which is a different thing and
\t   only a reasonable guess.  Reached only if SDL has no video info at all. */
\tSDL_Rect **modes = SDL_ListModes(NULL, SDL_FULLSCREEN);
\tif (modes && modes != (SDL_Rect **)-1 && modes[0]) {
\t\tif (w) *w = modes[0]->w;
\t\tif (h) *h = modes[0]->h;
\t}
\t/* else: leave the caller's defaults in place */
}
'''
        s = sub1(s, r'(#include "SDL_video\.h"\n)', r'\1' + shim,
                 "insert the SDL_GetDesktopMode shim")

    # (b2) Daum assigns the WIDTH to sdl.desktop.full.height.
    #
    #     src/gui/sdlmain.cpp, GUI_StartUp:
    #         if (!sdl.desktop.full.width)  sdl.desktop.full.width  = width;
    #         if (!sdl.desktop.full.height) sdl.desktop.full.height = width;
    #                                                                ^^^^^
    #     Upstream -- it is at line 2299 of the pristine 20150125 tree, and the
    #     other call site in res_init() has it right.  Reachable when
    #     fullresolution is left at 0x0 AND SDL_GetVideoInfo() returned nothing,
    #     which is the same condition that makes the shim above matter: you get
    #     a square fullscreen resolution.  Narrow, but it is one character and
    #     there is no reading under which assigning the width to the height is
    #     what was meant.
    if 'sdl.desktop.full.height=width;' in s:
        s = sub1(s,
                 r'(\tif \(!sdl\.desktop\.full\.height\) \{\n\t\tsdl\.desktop\.full\.height=)width(;\n\t\})',
                 r'\1height\2',
                 "fix full.height being assigned the width")
    write(p, s)

# ================================================== Intel TBB shim
# Daum parallelises the xBRZ scaler with Intel TBB.  That is a problem twice
# over: <tbb/task_scheduler_init.h> was deleted in oneTBB 2021, and the last
# TBB that still had it predates Apple Silicon.
#
# Disabling it is not an option either -- scaler=="xbrz" is registered ONLY
# inside #if (xBRZ_w_TBB) in render.cpp, and there is no serial fallback, so
# undefining it would delete the xBRZ scaler outright.
#
# The API surface actually used is three names.  Supply them as a header-only
# shim in include/ (already on the compiler's include path), so every xBRZ code
# path compiles unmodified.  parallel_for really does run in parallel via
# std::thread; task_group runs inline, which keeps the nested
# task_group->parallel_for case from oversubscribing the CPU.
tbbdir = os.path.join(root, 'include', 'tbb')
if not os.path.isdir(tbbdir):
    os.makedirs(tbbdir)

    with open(os.path.join(tbbdir, 'blocked_range.h'), 'w') as f:
        f.write('''/* Minimal tbb::blocked_range replacement -- see lib/daum.sh */
#ifndef DOSBOX_TBB_SHIM_BLOCKED_RANGE_H
#define DOSBOX_TBB_SHIM_BLOCKED_RANGE_H
#include <cstddef>
namespace tbb {
template <typename T>
class blocked_range {
public:
\ttypedef T value_type;
\tblocked_range(T b, T e, std::size_t grain = 1)
\t\t: b_(b), e_(e), g_(grain ? grain : 1) {}
\tT begin() const { return b_; }
\tT end() const { return e_; }
\tstd::size_t grainsize() const { return g_; }
\tbool empty() const { return !(b_ < e_); }
private:
\tT b_, e_;
\tstd::size_t g_;
};
}
#endif
''')

    with open(os.path.join(tbbdir, 'parallel_for.h'), 'w') as f:
        f.write('''/* Minimal tbb::parallel_for replacement -- see lib/daum.sh */
#ifndef DOSBOX_TBB_SHIM_PARALLEL_FOR_H
#define DOSBOX_TBB_SHIM_PARALLEL_FOR_H
#include <tbb/blocked_range.h>
#include <algorithm>
#include <thread>
#include <vector>
namespace tbb {
template <typename Range, typename Body>
void parallel_for(const Range& range, const Body& body) {
\ttypedef typename Range::value_type T;
\tconst T first = range.begin();
\tconst T last = range.end();
\tif (!(first < last)) return;

\tconst long long total = (long long)last - (long long)first;
\tconst long long grain = (long long)range.grainsize();
\tconst long long chunks = (total + grain - 1) / grain;

\tunsigned hw = std::thread::hardware_concurrency();
\tif (hw == 0) hw = 1;
\tlong long n = chunks < (long long)hw ? chunks : (long long)hw;
\tif (n <= 1) { body(range); return; }

\tconst long long per = (total + n - 1) / n;
\tstd::vector<std::thread> workers;
\tworkers.reserve((std::size_t)(n - 1));

\tfor (long long i = 1; i < n; ++i) {
\t\tconst long long s = (long long)first + per * i;
\t\tif (s >= (long long)last) break;
\t\tconst long long e = std::min(s + per, (long long)last);
\t\tworkers.push_back(std::thread([&body, &range, s, e]() {
\t\t\tbody(Range((T)s, (T)e, range.grainsize()));
\t\t}));
\t}

\t/* The calling thread takes the first chunk. */
\tbody(Range(first, (T)std::min((long long)first + per, (long long)last),
\t           range.grainsize()));

\tfor (std::size_t i = 0; i < workers.size(); ++i) workers[i].join();
}
}
#endif
''')

    with open(os.path.join(tbbdir, 'task_group.h'), 'w') as f:
        f.write('''/* Minimal tbb::task_group replacement -- see lib/daum.sh */
#ifndef DOSBOX_TBB_SHIM_TASK_GROUP_H
#define DOSBOX_TBB_SHIM_TASK_GROUP_H
namespace tbb {
class task_group {
public:
\t/* Run inline.  Daum only ever nests parallel_for inside these tasks, and
\t   that is where the real parallelism is; spawning here as well would
\t   oversubscribe the machine. */
\ttemplate <typename F> void run(const F& f) { f(); }
\tvoid wait() {}
};
}
#endif
''')

    with open(os.path.join(tbbdir, 'task_scheduler_init.h'), 'w') as f:
        f.write('''/* Minimal tbb::task_scheduler_init replacement -- see lib/daum.sh.
   Daum only includes this header; it never instantiates the class. */
#ifndef DOSBOX_TBB_SHIM_TASK_SCHEDULER_INIT_H
#define DOSBOX_TBB_SHIM_TASK_SCHEDULER_INIT_H
namespace tbb {
class task_scheduler_init {
public:
\tstatic const int automatic = -1;
\texplicit task_scheduler_init(int = automatic) {}
\tvoid initialize(int = automatic) {}
\tvoid terminate() {}
};
}
#endif
''')
    changed.append('include/tbb/ (shim)')

# ================================================== drive_physfs.cpp
# `return false` from a function declared `void *`.  GCC of the era accepted
# this because it treated the literal as a null pointer constant; clang does
# not, and it is not valid C++ -- `false` is a boolean literal, not an integer
# literal, so it is not a null pointer constant.  Only this one site is in a
# pointer-returning function; the other `return false`s are in bool methods.
p = os.path.join(root, 'src', 'dos', 'drive_physfs.cpp')
if os.path.exists(p):
    s = read(p)
    if 'return NULL; /* was: false */' not in s:
        s = sub1(s,
                 r'(if \(!PHYSFS_isDirectory\(myname\)\) return )false(;)',
                 r'\1NULL; /* was: false */\2'.replace(';\\2', '\\2'),
                 "fix `return false` from void* opendir()")
        s = s.replace('return NULL; /* was: false */;', 'return NULL; /* was: false */')

    # physfsFile::Write falls off the end of a `bool` function.
    #
    #     if (*size==0) {
    #         if (PHYSFS_tell(fhandle) == 0) {
    #             PHYSFS_close(PHYSFS_openWrite(pname));   /* <- no return */
    #         } else { ...; return false; }
    #     } else { ...; return true; }
    #     }   <- falls off the end
    #
    # Undefined behaviour, and reachable: it is the truncate-to-zero path, which
    # is what DOS does when a program opens an existing file for writing with
    # O_TRUNC on a PhysFS-mounted archive.  The caller reads whatever happened to
    # be in the return register and decides the write failed or succeeded on
    # that basis.
    #
    # Found in the build log, not by reading: clang has been saying
    #   drive_physfs.cpp:589: non-void function does not return a value in all
    #   control paths [-Wreturn-type]
    # on every build.  It is one line in 1372 warnings that nobody reads, in the
    # same file this script was already editing eleven lines further up.
    #
    # The truncate succeeded, so the answer is true -- matching the sibling
    # branch, which returns true after a successful write.
    if 'DOSBOX_PHYSFS_TRUNCATE_RETURN' not in s:
        s = sub1(s,
                 r'(\t\t\t//LOG_MSG\("Truncate %s \(%s\)",name,PHYSFS_getLastError\(\)\);\n)',
                 r'\1\t\t\t*size = 0;\n'
                 '\t\t\treturn true;\t/* DOSBOX_PHYSFS_TRUNCATE_RETURN: was falling off the end */\n',
                 "return a value from physfsFile::Write's truncate path")
    write(p, s)

# ================================================== shell.cpp: startup banner
# Daum prints two lines above the welcome box:
#
#     DOSBox SVN-Daum [ykhwong.x-y.net]
#     UPDATED: JAN 24, 2015
#
# The first stays exactly as it is.  This is ykhwong's work under the GPL and
# the attribution should remain visible; what is misleading is the second line,
# which dates the binary to 2015 when it now carries an AArch64 backend, a
# soft-float FPU, an HQ scaler and the rest of audit/FINDINGS.md.
#
# Only the text between the colour codes is replaced -- \033[33m ... \033[37m --
# so the banner keeps its formatting and the edit cannot disturb the box drawing
# below it.  shell.cpp is CRLF throughout (49751 of 49751 lines) and
# daum_normalize_line_endings() deliberately leaves .cpp alone, so this is a
# plain substring substitution with no line-ending exposure at all.
p = os.path.join(root, 'src', 'shell', 'shell.cpp')
if os.path.exists(p):
    s = read(p)
    if 'UPDATED: JAN 24, 2015' in s:
        notice = os.environ.get('DAUM_BANNER_NOTICE', 'Retro eXo modified')
        # It lands inside a C string literal, so anything that would terminate
        # or escape one has to be neutralised.  Non-ASCII is dropped rather than
        # emitted raw: the DOS shell renders CP437, not UTF-8, and a stray byte
        # would corrupt the line rather than fail loudly.
        notice = notice.replace('\\', '\\\\').replace('"', '\\"')
        notice = ''.join(c for c in notice if 32 <= ord(c) < 127)
        if not notice:
            bail("DAUM_BANNER_NOTICE has no printable ASCII left after escaping")
        s = sub1(s, r'UPDATED: JAN 24, 2015', lambda m: notice,
                 "replace the 2015 banner date with the modification notice")
        write(p, s)

# ================================================== cdrom_image.cpp
# Sound_GetDuration() does not exist in SDL_sound 1.0.3, the last release of
# the 1.x line -- Daum was built against a later snapshot.  Rather than chase
# an unreleased SDL_sound, compute the value directly.
#
# The original is  floor(duration_ms * 176.4 + 0.5), and 176.4 is exactly the
# bytes-per-millisecond of the format the constructor asks for
# (44100 Hz x 2 channels x 16 bit = 176400 B/s).  getLength() therefore returns
# a BYTE count, so decoding the stream and counting bytes gives the same answer
# with no rounding and no dependency on the missing API.
#
# Chunked decoding, not Sound_DecodeAll(): the latter allocates the entire
# decoded track, about 50 MB for five minutes of CD audio.
#
# Two things beyond the original replacement, both found in the 2026-07-29 audit:
#
#  1. Sound_Rewind's return was ignored.  SDL_sound.h is explicit that "if this
#     function fails, the state of the sample is undefined" -- it fails when the
#     underlying RWops is not seekable.  Ignoring it meant every subsequent
#     read() served undefined data with no diagnostic, on a code path that only
#     triggers for unusual media.  Now checked, and the failure is reported the
#     way the rest of the function reports failure: -1.
#
#  2. The scan ran with the constructor's 2352-byte buffer, so a full CD image
#     needs on the order of 300,000 Sound_Decode() calls.  The scan does not
#     care about chunk size -- only the total -- so it now uses a much larger
#     buffer and restores the sector-sized one afterwards, cutting the call
#     count by ~100x for identical output.
#
#     lastCount has to be restored with it.  read() only calls
#     Sound_SetBufferSize when `lastCount != count`, so leaving lastCount at
#     2352 while the buffer was actually 256 KB would make the next read()
#     skip the resize, decode a quarter-megabyte, and copy 2352 bytes of it --
#     advancing the stream ~100 sectors per read.  Silent audio corruption, and
#     exactly the kind of bookkeeping mismatch that does not show up until
#     someone plays a CD track.
#
#     The wall-clock cost on real media has NOT been measured -- it cannot be
#     from the audit sandbox -- so the scan times itself and says so when it is
#     slow enough to notice.  LOG_WARN rather than LOG_NORMAL: post-audit,
#     warnings print whatever the [log] group defaults are, and a multi-second
#     IMGMOUNT is something the user is entitled to an explanation for.
p = os.path.join(root, 'src', 'dos', 'cdrom_image.cpp')
if os.path.exists(p):
    s = read(p)
    if 'Sound_GetDuration' in s:
        body = '''int CDROM_Interface_Image::AudioFile::getLength()
{
\t/* SDL_sound 1.0.3 has no Sound_GetDuration(); count decoded bytes instead.
\t   getLength() returns bytes, and the constructor requests 44100Hz/16bit/
\t   stereo = 176400 B/s, which is where the original's 176.4 came from. */
\tif (!sample) return -1;

\t/* Scan with a big buffer: the total is all that matters here, and the
\t   constructor's 2352-byte buffer would need ~300k calls for a full disc.
\t   If the resize fails, carry on at whatever size we have. */
\tconst Uint32 DOSBOX_SCAN_BUFFER = 256 * 1024;
\tconst bool resized = Sound_SetBufferSize(sample, DOSBOX_SCAN_BUFFER) != 0;
\t/* SDL_GetTicks, not DOSBox's GetTicks(): the latter is a macro in timer.h,
\t   which this file does not include.  cdrom.h includes SDL.h directly, so
\t   this needs nothing new -- and GetTicks() is #defined to exactly this. */
\tconst Uint32 t0 = SDL_GetTicks();

\tUint32 total = 0;
\tUint32 got;
\twhile ((got = Sound_Decode(sample)) > 0) {
\t\ttotal += got;
\t\tif (sample->flags & (SOUND_SAMPLEFLAG_ERROR | SOUND_SAMPLEFLAG_EOF)) break;
\t}
\tbool failed = (sample->flags & SOUND_SAMPLEFLAG_ERROR) != 0;

\t/* Put the sample back exactly as read() expects to find it: sector-sized
\t   buffer, lastCount agreeing with it, stream at the start. */
\tif (resized) {
\t\tSound_SetBufferSize(sample, RAW_SECTOR_SIZE);
\t\tlastCount = RAW_SECTOR_SIZE;
\t}

\t/* A failed rewind leaves the sample in an undefined state (SDL_sound.h),
\t   so it is a hard failure here rather than something to shrug at -- every
\t   later read() would return undefined data otherwise. */
\tif (!Sound_Rewind(sample)) {
\t\tLOG(LOG_MISC,LOG_ERROR)("CDROM: cannot rewind audio track after length scan: %s",
\t\t                        Sound_GetError());
\t\tfailed = true;
\t}
\tlastSeek = 0;

\tconst Uint32 ms = SDL_GetTicks() - t0;
\tif (ms >= 750)
\t\tLOG(LOG_MISC,LOG_WARN)("CDROM: measuring an audio track took %ums (%uMB decoded); "
\t\t                       "SDL_sound 1.0.3 has no duration API, so the track must be "
\t\t                       "decoded once at mount time", (unsigned)ms,
\t\t                       (unsigned)(total >> 20));

\treturn failed ? -1 : (int)total;
}'''
        s = sub1(s,
                 r'int CDROM_Interface_Image::AudioFile::getLength\(\)\s*\{\s*'
                 r'int length = Sound_GetDuration\(sample\);\s*'
                 r'return \(int\)floor\(\(length \* 176\.4\) \+ 0\.5\);\s*\}',
                 lambda m: body,
                 "replace Sound_GetDuration() with a decode-and-count equivalent")
        write(p, s)

# ================================================== main-loop instrumentation
# For the output=opengl + cycles=max collapse.  Either setting alone is fine,
# both together are not, and the obvious causes are already eliminated -- so
# this stops guessing and measures.  See include/dbprof.h for what the numbers
# mean; the short version is that comparing wall time against thread CPU time
# over one pass of Normal_Loop separates "the emulator thread was BLOCKED" from
# "the emulator thread was running and got less done", which is the fork in the
# road that frame-time measurements cannot resolve.
#
# All of it is inert unless $DOSBOX_PROF is set in the environment at run time.
if os.environ.get('DAUM_PROFILE', '1') != '0':
    p = os.path.join(root, 'src', 'dosbox.cpp')
    if not os.path.exists(p): bail("src/dosbox.cpp is missing")
    s = read(p)
    if 'dbprof.h' not in s:
        s = sub1(s, r'(#include "dosbox\.h"\n)', r'\1#include "dbprof.h"\n',
                 "include dbprof.h in dosbox.cpp")

        # One pass of Normal_Loop is one measurement interval: DOSBOX_RunMachine
        # calls it in a loop and it returns as soon as ticksRemain runs out, so
        # the interval boundary and the autoadjust decision point coincide --
        # which is exactly what makes a stall attributable to a cycle cut.
        s = sub1(s,
                 r'(static Bitu Normal_Loop\(void\) \{\n\tBits ret;\n)(\twhile \(1\) \{\n)',
                 r'\1\tdbprof_pass_begin(cycle_count);\n\2',
                 "open a profiler interval at the top of Normal_Loop")
        s = sub1(s,
                 r'(\t\t\tif \(ticksDone < 0\)\n\t\t\t\tticksDone = 0;\n\t\t\}\n\t\}\n)'
                 r'(\treturn 0;\n\})',
                 r'\1\tdbprof_pass_end(cycle_count, CPU_CycleMax);\n\2',
                 "close the profiler interval at the end of Normal_Loop")

        # Top-level phases.  PIC_RunQueue() is called inside an if, so it needs
        # a temporary rather than the statement-wrapping macro.
        s = sub1(s,
                 r'\t\trun_hw\(\);\n\t\tif \(PIC_RunQueue\(\)\) \{\n',
                 '\t\tDBPROF_TIME(DBP_HW, run_hw());\n'
                 '\t\tconst unsigned long long dbp__pic = dbprof_t0();\n'
                 '\t\tconst bool dbp__queued = PIC_RunQueue();\n'
                 '\t\tdbprof_add(DBP_PIC, dbp__pic);\n'
                 '\t\tif (dbp__queued) {\n',
                 "time run_hw() and PIC_RunQueue()")
        s = sub1(s, r'\t\t\t\tret = \(\*cpudecoder\)\(\);\n',
                 '\t\t\t\tDBPROF_TIME(DBP_CPU, ret = (*cpudecoder)());\n',
                 "time the CPU core")
        s = sub1(s, r'\t\t\tGFX_Events\(\);\n',
                 '\t\t\tDBPROF_TIME(DBP_EVENTS, GFX_Events());\n',
                 "time GFX_Events()")
        s = sub1(s, r'\t\t\t\tTIMER_AddTick\(\);\n',
                 '\t\t\t\tDBPROF_TIME(DBP_TICK, TIMER_AddTick());\n',
                 "time TIMER_AddTick()")
        s = sub1(s, r'\t\t\tSDL_Delay\(1\);\n',
                 '\t\t\tDBPROF_TIME(DBP_DELAY, SDL_Delay(1));\n',
                 "time the increaseticks idle sleep")

        # Every autoadjust decision, including the ones it declines to apply.
        # A ratio under the 1%/12% cut-offs is itself a finding: it means the
        # controller saw the stall and discarded the measurement rather than
        # reacting to it, which looks identical from outside to not stalling.
        s = sub1(s,
                 r'(\t{5}if\(ticksDone < 1\) ticksDone = 1; // Protect against div by zero\n)',
                 r'\1\t\t\t\t\tconst Bit32s dbp__cmax0 = CPU_CycleMax;\n',
                 "snapshot CPU_CycleMax before the autoadjust decision")
        s = sub1(s,
                 r'(\t{5})(CPU_IODelayRemoved = 0;\n)',
                 r'\1dbprof_adjust(ticksScheduled, ticksDone, ticksAdded, ratio,\n'
                 r'\1              dbp__cmax0, new_cmax,\n'
                 r'\1              CPU_CycleMax != dbp__cmax0);\n'
                 r'\1\2',
                 "log every autoadjust decision, applied or not")

        # The /3 branch.  One pass took over 15ms of wall clock with fewer than
        # 5 emulated ticks scheduled, so the controller concludes the host
        # cannot keep up and cuts the guest clock by two thirds.  A run of these
        # IS the collapse, and each one is caused by a single stall that the
        # STALL line immediately above will have attributed to a phase.
        s = sub1(s,
                 r'(\t{5})CPU_CycleMax /= 3;\n'
                 r'(\t{5}if \(CPU_CycleMax < CPU_CYCLES_LOWER_LIMIT\)\n)'
                 r'(\t{6}CPU_CycleMax = CPU_CYCLES_LOWER_LIMIT;\n)',
                 r'\1const Bit32s dbp__panic0 = CPU_CycleMax;\n'
                 r'\1CPU_CycleMax /= 3;\n'
                 r'\2\3'
                 r'\1dbprof_panic(ticksAdded, ticksScheduled, dbp__panic0, CPU_CycleMax);\n',
                 "log the /3 panic cut")
        write(p, s)

    p = os.path.join(root, 'src', 'gui', 'sdlmain.cpp')
    if not os.path.exists(p): bail("src/gui/sdlmain.cpp is missing")
    s = read(p)
    if 'dbprof.h' not in s:
        s = sub1(s, r'(#include "dosbox\.h"\n)', r'\1#include "dbprof.h"\n',
                 "include dbprof.h in sdlmain.cpp")

        # Log the raw SDL_ACTIVEEVENT mask before DOSBox acts on it.  See the
        # CPU_*_SkipAutoAdjust patch below for what goes wrong here.
        s = sub1(s,
                 r'(\t\tcase SDL_ACTIVEEVENT:\n)'
                 r'(\t\t\tif \(event\.active\.state & SDL_APPINPUTFOCUS\) \{\n)',
                 r'\1\t\t\tdbprof_focus(event.active.state, event.active.gain,\n'
                 r'\t\t\t             (event.active.state & SDL_APPINPUTFOCUS) != 0,\n'
                 r'\t\t\t             CPU_CycleMax);\n\2',
                 "log every SDL_ACTIVEEVENT with its raw state mask")


        # Three swap sites.  Upstream has four: the PBO branch of
        # GFX_EndUpdate swapped and then fell through to the unconditional swap
        # below it, costing two per frame.  The openglhq section above removes
        # the duplicate, so this count changing back to 4 means that edit
        # stopped applying.
        s = subn(s, r'SDL_GL_SwapBuffers\(\);',
                 'DBPROF_TIME(DBP_SWAP, SDL_GL_SwapBuffers());', 3,
                 "time every SDL_GL_SwapBuffers")
        s = subn(s, r'glCallList\(sdl\.opengl\.displaylist\);',
                 'DBPROF_TIME(DBP_DRAW, glCallList(sdl.opengl.displaylist));', 2,
                 "time the display-list draw")
        # Multi-line call; [^;] spans newlines, and neither site contains a
        # semicolon or a nested ') ;' before its own terminator.
        s = subn(s, r'glTexSubImage2D\([^;]*?\);',
                 lambda m: 'DBPROF_TIME(DBP_TEXUP, ' + m.group(0)[:-1] + ');', 2,
                 "time the texture uploads")
        s = subn(s, r'glUnmapBufferARB\(GL_PIXEL_UNPACK_BUFFER_EXT\);',
                 'DBPROF_TIME(DBP_TEXUP, '
                 'glUnmapBufferARB(GL_PIXEL_UNPACK_BUFFER_EXT));', 1,
                 "time the PBO unmap")
        s = subn(s, r'pixels=\(Bit8u \*\)glMapBufferARB'
                    r'\(GL_PIXEL_UNPACK_BUFFER_EXT, GL_WRITE_ONLY\);',
                 'DBPROF_TIME(DBP_MAP, pixels=(Bit8u *)glMapBufferARB'
                 '(GL_PIXEL_UNPACK_BUFFER_EXT, GL_WRITE_ONLY));', 1,
                 "time the PBO map")
        # Twice a second from Normal_Loop, and it is a Cocoa main-thread call.
        s = subn(s, r'SDL_WM_SetCaption\(title,VERSION\);',
                 'DBPROF_TIME(DBP_TITLE, SDL_WM_SetCaption(title,VERSION));', 2,
                 "time the title-bar update")
        write(p, s)

# ================================================== the focus/throttle latch
# Diagnosed from a profiler run, not guessed.  For the first 96 seconds of a
# DOS/4GW game launch, cycles=max sat at CPU_CycleMax 750 and then 375 with
# auto-adjust never running once, while the host loop was 80% idle in
# SDL_Delay.  Then it cleared and the clock climbed 375 -> 250000 in six
# seconds.  Two upstream assumptions combine to produce that:
#
#   1. CPU_Enable_SkipAutoAdjust() halves the guest clock EVERY time it is
#      called.  That is only safe if focus-lost and focus-gained arrive in
#      pairs.  Under sdl12-compat on macOS they do not -- each SDL_SetVideoMode
#      recreates the SDL2 window, and a window created while the app is not
#      frontmost emits another unpaired FOCUS_LOST.  3000 -> 1500 -> 750 -> 375
#      is three of them, and 3000 is exactly the cycles=max starting value.
#      /2 in CPU_Enable_SkipAutoAdjust is the only halving in the tree, and it
#      is guarded on CPU_CycleAutoAdjust, so this is the only thing those
#      numbers can be.
#
#   2. Nothing ever clears the latch except a focus-gained event.  Miss it and
#      the emulator is throttled for the rest of the session.
#
# The halving is made idempotent, the stale accumulators are reset on the way
# out, and GFX_Events consults SDL_GetAppState() rather than trusting that the
# event pairing held.  All three are corrections to real bugs, so unlike the
# profiler they are NOT gated on $DOSBOX_PROF -- only the logging is.
p = os.path.join(root, 'src', 'cpu', 'cpu.cpp')
if not os.path.exists(p): bail("src/cpu/cpu.cpp is missing")
s = read(p)
if 'dbp__already' not in s:
    if os.environ.get('DAUM_PROFILE', '1') != '0':
        s = sub1(s, r'(#include "cpu\.h"\n)', r'\1#include "dbprof.h"\n',
                 "include dbprof.h in cpu.cpp")
        log_enable = ('\tdbprof_skip("enable", dbp__already ? 1 : 0, dbp__c0,\n'
                      '\t            CPU_CycleMax, ticksScheduled, ticksDone);\n')
        log_disable = ('\t\tdbprof_skip("disable", 0, CPU_CycleMax, CPU_CycleMax,\n'
                       '\t\t            ticksScheduled, ticksDone);\n')
    else:
        log_enable = log_disable = ''

    body = '''void CPU_Enable_SkipAutoAdjust(void) {
\textern Bit32s ticksDone;
\textern Bit32u ticksScheduled;
\tconst Bit32s dbp__c0 = CPU_CycleMax;
\tconst bool dbp__already = CPU_SkipCycleAutoAdjust;
\t/* Idempotent.  Upstream halves the guest clock on every focus-lost, which
\t * assumes focus-lost and focus-gained arrive in pairs.  sdl12-compat on
\t * macOS emits unpaired losses -- one per SDL_SetVideoMode while the app is
\t * not frontmost -- and three of those during startup take cycles=max from
\t * 3000 down to 375 with no way back up. */
\tif (CPU_CycleAutoAdjust && !CPU_SkipCycleAutoAdjust) {
\t\tCPU_CycleMax /= 2;
\t\tif (CPU_CycleMax < CPU_CYCLES_LOWER_LIMIT)
\t\t\tCPU_CycleMax = CPU_CYCLES_LOWER_LIMIT;
\t}
\tCPU_SkipCycleAutoAdjust=true;
''' + log_enable + '''\t(void)dbp__c0; (void)dbp__already;
}

void CPU_Disable_SkipAutoAdjust(void) {
\textern Bit32s ticksDone;
\textern Bit32u ticksScheduled;
\t/* ticksScheduled += ticksAdded runs OUTSIDE the auto-adjust guard while the
\t * reset runs inside it, so both accumulators grow for the whole time
\t * auto-adjust is skipped.  Feeding that to the first evaluation after focus
\t * returns is not a recovery, it is a coin flip: one observed run came back
\t * with sched 96593 / done 19571 -- 96 seconds of stale measurement decided
\t * the next clock speed.  Daum already has the right function for this. */
\tif (CPU_SkipCycleAutoAdjust) {
''' + log_disable + '''\t\tCPU_Reset_AutoAdjust();
\t}
\tCPU_SkipCycleAutoAdjust=false;
}'''

    s = sub1(s,
             r'void CPU_Enable_SkipAutoAdjust\(void\) \{\n'
             r'\tif \(CPU_CycleAutoAdjust\) \{\n'
             r'\t\tCPU_CycleMax /= 2;\n'
             r'\t\tif \(CPU_CycleMax < CPU_CYCLES_LOWER_LIMIT\)\n'
             r'\t\t\tCPU_CycleMax = CPU_CYCLES_LOWER_LIMIT;\n'
             r'\t\}\n'
             r'\tCPU_SkipCycleAutoAdjust=true;\n'
             r'\}\n'
             r'\n'
             r'void CPU_Disable_SkipAutoAdjust\(void\) \{\n'
             r'\tCPU_SkipCycleAutoAdjust=false;\n'
             r'\}',
             lambda m: body,
             "make the focus throttle idempotent and reset the stale accumulators")
    write(p, s)

    # DOSBox tracks focus purely as a state machine driven by paired events.
    # sdl12-compat does not reliably deliver the pairs, and a missed
    # focus-gained leaves the emulator throttled for the rest of the session
    # with no way back.  SDL_GetAppState() answers the same question directly
    # and does not depend on any event having arrived -- so consult it, but
    # only while the latch is set, which is both the broken state and the one
    # where the loop is 80% idle anyway.
    p = os.path.join(root, 'src', 'gui', 'sdlmain.cpp')
    s = read(p)
    if 'SDL_GetAppState' not in s:
        s = sub1(s,
                 r'(void GFX_Events\(\) \{\n\tSDL_Event event;\n)',
                 r'''\1\tif (GCC_UNLIKELY(CPU_SkipCycleAutoAdjust) &&
\t    (SDL_GetAppState() & SDL_APPINPUTFOCUS))
\t\tCPU_Disable_SkipAutoAdjust();
''',
                 "self-heal the auto-adjust latch from the real focus state")
        write(p, s)

# ================================================== Makefile.am
p = os.path.join(root, 'src', 'cpu', 'core_dynrec', 'Makefile.am')
if os.path.exists(p):
    s = read(p)
    if 'risc_armv8le.h' not in s and 'risc_armv4le.h' in s:
        write(p, s.replace('risc_armv4le.h', 'risc_armv4le.h risc_armv8le.h', 1))

for c in sorted(set(changed)):
    sys.stderr.write("  patched %s\n" % c)
PYEOF

  # Independent verification: the patcher reports success, now prove it.
  grep -q 'risc_armv8le.h' "$DAUM_SRC/src/cpu/core_dynrec.cpp" \
    || die "core_dynrec.cpp still has no ARMV8LE branch"
  grep -q '#define PAGESIZE 16384' "$DAUM_SRC/src/cpu/core_dynrec.cpp" \
    || die "host page size was not raised to 16384"
  grep -q 'C_TARGETCPU,ARMV8LE' "$DAUM_SRC/configure.ac" \
    || die "configure.ac still has no aarch64 case"
  grep -q 'xarmv8le' "$DAUM_SRC/configure.ac" \
    || die "configure.ac still gates C_DYNREC on x86 only -- arm64 would build interpreter-only"
  grep -q 'drc_alloc_cache' "$DAUM_SRC/src/cpu/core_dynrec/cache.h" \
    || die "cache.h still uses the default allocator"
  grep -q 'OpenGLHQ_Render' "$DAUM_SRC/src/gui/sdlmain.cpp" \
    || die "GFX_EndUpdate does not dispatch to openglhq"
  # The three probe sites form a ladder, and the verifier reads it as one: a
  # missing rung does not read as "that step failed", it reads as "everything
  # after it failed".  So all three have to be there or the diagnosis is wrong
  # in a way that points at the wrong place.
  probes="$(grep -c 'OpenGLHQ_ProbeLog' "$DAUM_SRC/src/gui/sdlmain.cpp" || true)"
  [[ "${probes:-0}" -eq 7 ]] \
    || die "sdlmain.cpp has $probes openglhq probe sites, expected 7 (gfx-setsize, gl-startup-probe, conf, gl-arm, gl-context, mode-set-injected, mode-set-null)"
  grep -q 'switching back to surface: %s' "$DAUM_SRC/src/gui/sdlmain.cpp" \
    || die "the startup OpenGL probe still discards SDL_GetError()"
  # Exactly one, and on the real-call path only.  A second call site would
  # delete openglhq's objects on a mode set that changes nothing -- which is
  # the bug this replaced, reintroduced.
  ctxrel="$(grep -c 'OpenGLHQ_ReleaseForContextChange()' "$DAUM_SRC/src/gui/sdlmain.cpp" || true)"
  [[ "${ctxrel:-0}" -eq 1 ]] \
    || die "sdlmain.cpp calls OpenGLHQ_ReleaseForContextChange $ctxrel times, expected exactly 1"
  # It must come BEFORE the SDL_SetVideoMode it guards.  After the context is
  # replaced, the names it deletes may belong to DOSBox's own objects -- a
  # silent corruption, not a crash, so ordering gets an assertion of its own.
  python3 - "$DAUM_SRC/src/gui/sdlmain.cpp" <<'ORDER' || die "OpenGLHQ_ReleaseForContextChange must precede SDL_SetVideoMode"
import sys
src = open(sys.argv[1], errors='surrogateescape').read()
rel = src.index('OpenGLHQ_ReleaseForContextChange()')
mode = src.index('SDL_Surface* s = SDL_SetVideoMode(width,height,bpp,flags);')
sys.exit(0 if rel < mode else 1)
ORDER
  # And the old unconditional teardown must be gone, or both fire and the
  # surviving-context path never happens.
  if grep -q 'OpenGLHQ_Shutdown();' "$DAUM_SRC/src/gui/sdlmain.cpp"; then
    die "sdlmain.cpp still tears openglhq down on every GFX_SetSize -- see patch (d)"
  fi

  # ---- the invariant that makes a FAILED mode set safe -------------------
  #
  # openglhq is released on the way into SDL_SetVideoMode_Wrap.  If the mode set
  # then fails, i_width/i_height keep describing the last SUCCESSFUL mode -- so
  # on the face of it, a later identical GFX_SetSize should take the SETMODE_SAVES
  # early return, skip SDL_SetVideoMode entirely, and leave openglhq released and
  # never re-initialised.
  #
  # It cannot, and the reason is one term: the guard also requires
  # `sdl.surface != NULL`, and every one of the call sites assigns the returned
  # NULL straight into sdl.surface.  i_* and sdl.surface are written together on
  # success and neither is written on failure, so the early return can only fire
  # when i_* genuinely describes the surface being handed back.
  #
  # Three things have to stay true for that, and all three are the kind of edit
  # someone would make while tidying.  Each gets its own assertion, because
  # "openglhq silently stops working after an unrelated mode set" is not a
  # failure anyone would trace back to here.
  python3 - "$DAUM_SRC/src/gui/sdlmain.cpp" <<'INVARIANT' || die "the SETMODE_SAVES failure invariant no longer holds -- see lib/daum.sh"
import re, sys
src = open(sys.argv[1], errors='surrogateescape').read()
bad = []

# 1. The early-return guard must still test sdl.surface, and test it FIRST --
#    && short-circuits, so the position is what stops a stale i_* comparison
#    from being reached at all.
if not re.search(r'if \(sdl\.surface != NULL && height == i_height', src):
    bad.append("the SETMODE_SAVES guard no longer begins with `sdl.surface != NULL`")

# 2. i_* must be assigned only AFTER the NULL bail-out.
m_null = src.find('if (s == NULL) return s;')
m_iw   = src.find('i_width = width;')
if m_null < 0 or m_iw < 0 or not (m_null < m_iw):
    bad.append("`if (s == NULL) return s;` no longer precedes the i_* assignments")

# 3. Every call site must funnel the result into sdl.surface, or one of them
#    could leave a stale non-NULL surface behind after a failure.  Counted
#    rather than named: a new call site added later is exactly the case this
#    is here to catch.
tot = len(re.findall(r'SDL_SetVideoMode_Wrap', src))
asg = len(re.findall(r'sdl\.surface\s*=\s*SDL_SetVideoMode_Wrap', src))
dfn = len(re.findall(r'SDL_Surface\* SDL_SetVideoMode_Wrap', src))
rec = len(re.findall(r'return SDL_SetVideoMode_Wrap', src))
if tot != asg + dfn + rec:
    bad.append("%d SDL_SetVideoMode_Wrap use(s) do not assign to sdl.surface "
               "(total=%d assigned=%d def=%d recursive=%d)"
               % (tot - asg - dfn - rec, tot, asg, dfn, rec))

for b in bad:
    sys.stderr.write("        %s\n" % b)
sys.exit(1 if bad else 0)
INVARIANT
  # The startup banner must no longer claim to be the 2015 build.
  if grep -q 'UPDATED: JAN 24, 2015' "$DAUM_SRC/src/shell/shell.cpp"; then
    die "shell.cpp still prints the upstream 2015 banner date"
  fi
  grep -qF "$DAUM_BANNER_NOTICE" "$DAUM_SRC/src/shell/shell.cpp" \
    || die "the banner notice ($DAUM_BANNER_NOTICE) is not in shell.cpp -- and since
DAUM_BANNER_NOTICE reaches the patcher through the ENVIRONMENT, the usual cause
is that it stopped being exported from versions.sh."
  # Attribution stays: this is ykhwong's work under the GPL.
  grep -q 'ykhwong.x-y.net' "$DAUM_SRC/src/shell/shell.cpp" \
    || die "the upstream attribution line was removed from the banner"
  grep -q 'fpu_instructions_softfloat.h' "$DAUM_SRC/src/fpu/fpu.cpp" \
    || die "fpu.cpp does not use the soft-float FPU core"
  # Negative: if C_FPU_X86 could still select the x87 core, the two slices would
  # diverge again -- which is the whole thing this replaces.
  if grep -q 'fpu_instructions_x86.h' "$DAUM_SRC/src/fpu/fpu.cpp"; then
    die "fpu.cpp can still include fpu_instructions_x86.h -- the slices would not match"
  fi
  # BOTH FPU consumers, not just the interpreter's.  Checking only fpu.cpp is
  # what let the dynamic core keep Daum's 53-bit double core for the entire life
  # of this build while the feature audit cheerfully reported SoftFloat.
  grep -q 'fpu_instructions_softfloat.h' "$DAUM_SRC/src/cpu/core_dynrec/dyn_fpu.h" \
    || die "core_dynrec/dyn_fpu.h does not use the soft-float FPU core.
core=dynamic would run a different FPU from core=normal: 53-bit doubles, no
exception masks, and the Windows 3.1 OLE fix silently not applied."
  if grep -qE '#include "\.\./\.\./fpu/fpu_instructions(_x86)?\.h"' "$DAUM_SRC/src/cpu/core_dynrec/dyn_fpu.h"; then
    die "core_dynrec/dyn_fpu.h can still reach a non-soft-float FPU core"
  fi
  # Sweep for a third one rather than naming the two we know about.  These are
  # the only two files in the tree that select an FPU core, and if a future
  # merge adds another this should say so rather than quietly leaving it.
  local fpusel
  fpusel="$(grep -rlE '#include ".*fpu_instructions(_x86)?\.h"' "$DAUM_SRC/src" 2>/dev/null \
            | grep -v 'core_dyn_x86' || true)"
  [[ -z "$fpusel" ]] || die "these files still select a non-soft-float FPU core:
$(printf '    %s\n' $fpusel)
Every consumer must use fpu_instructions_softfloat.h or the cores disagree.
(core_dyn_x86 is exempt: C_DYNAMIC_X86 is never defined for this build.)"
  grep -q 'top_srcdir)/src/softfloat' "$DAUM_SRC/src/cpu/Makefile.am" \
    || die "src/cpu/Makefile.am lacks the SoftFloat include path -- core_dynrec will not compile"

  # ---- the FPU coverage histogram --------------------------------------
  #
  # Every enum member must have exactly one hook.  A member with no hook does
  # not report "missing" -- it reports 0, which is indistinguishable from "this
  # workload never executed that instruction", and that is the whole value of
  # the instrument destroyed silently.  Demonstrated: deleting the FPATAN hook
  # leaves the FPU test suite passing and prints
  #     FPATAN   0   <-- not exercised
  # So the counts are compared here, at build time, where a mismatch is loud.
  [[ -f "$DAUM_SRC/src/fpu/dbfpu.h" ]] || die "src/fpu/dbfpu.h was not installed"
  local dbf_enum dbf_hook
  dbf_enum="$(grep -oE 'DBF_[A-Z0-9_]+' "$DAUM_SRC/src/fpu/dbfpu.h" | grep -v '^DBF_N$' | sort -u | wc -l | tr -d ' ')"
  dbf_hook="$(cat "$DAUM_SRC/src/fpu/fpu_instructions_softfloat.h" "$DAUM_SRC/src/fpu/fpu.cpp" \
              | grep -oE 'DBFPU_HIT\(DBF_[A-Z0-9_]+\)' | sort -u | wc -l | tr -d ' ')"
  [[ "$dbf_enum" == "$dbf_hook" ]] \
    || die "the FPU histogram names $dbf_enum operations but only $dbf_hook are hooked.
An unhooked op reports 0, which reads exactly like 'this workload never used
it'.  Either add the hook or remove it from enum DBFpuOp in vendor/dbfpu.h.
Named but not hooked:
$(comm -23 \
    <(grep -oE 'DBF_[A-Z0-9_]+' "$DAUM_SRC/src/fpu/dbfpu.h" | grep -v '^DBF_N$' | sort -u) \
    <(cat "$DAUM_SRC/src/fpu/fpu_instructions_softfloat.h" "$DAUM_SRC/src/fpu/fpu.cpp" \
      | grep -oE 'DBFPU_HIT\(DBF_[A-Z0-9_]+\)' | sed 's/DBFPU_HIT(//;s/)//' | sort -u) \
  | sed 's/^/    /')"
  ok "FPU histogram: $dbf_enum operations named, $dbf_hook hooked"
  # And the exception counters, which are one hook covering every operation.
  grep -q 'dbfpu_anomaly(DBA_ES)' "$DAUM_SRC/src/fpu/fpu_instructions_softfloat.h" \
    || die "SF_flags() no longer feeds the FPU anomaly counters"
  # Declaration before use, in every file that uses the macro.
  #
  # A hook is legal only below the #include that declares it, and "the header is
  # included somewhere in this file" is not the same statement.  fpu.cpp defines
  # FPU_FLDCW at :33 and pulls the soft-float header in at :49, so the first
  # version of this hook sat 15 lines above its own declaration and the build
  # failed with `use of undeclared identifier 'DBF_FLDCW'` -- after a full
  # dependency build, which is the expensive way to find out.
  python3 - "$DAUM_SRC/src/fpu/fpu.cpp" "$DAUM_SRC/src/fpu/fpu_instructions_softfloat.h" <<'ORDER' \
    || die "a DBFPU_HIT appears before the #include that declares it"
import sys, re
bad = []
for path in sys.argv[1:]:
    src = open(path, errors='surrogateescape').read()
    use = src.find('DBFPU_HIT(')
    if use < 0: continue
    inc = min([m.start() for m in re.finditer(r'#include "(dbfpu|fpu_instructions_softfloat)\.h"', src)] or [len(src)])
    if inc > use:
        bad.append("        %s: first DBFPU_HIT at byte %d, declaring #include at %d"
                   % (path.split('/')[-1], use, inc))
for b in bad: sys.stderr.write(b + "\n")
sys.exit(1 if bad else 0)
ORDER
  [[ -f "$DAUM_SRC/src/softfloat/Makefile.am" ]] \
    || die "src/softfloat/Makefile.am was not generated"
  grep -q 'libsoftfloat.a' "$DAUM_SRC/src/Makefile.am" \
    || die "libsoftfloat.a is not linked into dosbox"
  # Negative check, written as an if: `grep -q ... && die` returns non-zero in
  # the *good* case, which under `set -e` would abort the build.
  if grep -q 'want_type=SCREEN_OPENGLHQ' "$DAUM_SRC/src/gui/sdlmain.cpp"; then
    die "something still selects SCREEN_OPENGLHQ -- Daum's handling of that type
is Windows-shaped (menu teardown, DestroyWindow, SDL_VIDEODRIVER) and none of it
applies here.  output=openglhq must resolve to SCREEN_OPENGL."
  fi
  if [[ "$DAUM_PROFILE" != "0" ]]; then
    grep -q 'dbprof_pass_begin' "$DAUM_SRC/src/dosbox.cpp" \
      || die "Normal_Loop was not instrumented -- the profiler would report nothing"
    grep -q 'DBP_SWAP' "$DAUM_SRC/src/gui/sdlmain.cpp" \
      || die "the GL output path was not instrumented"
  fi

  printf '%s\n' "$DAUM_PATCH_FP" > "$stamp"
  ok "sources adapted and verified"
}

# --------------------------------------------------------------------------
# Build
# --------------------------------------------------------------------------
daum_autogen() {
  local log; log="$(start_log "daum-autogen.log")"
  [[ -x "$DAUM_SRC/configure" && "$DAUM_SRC/configure" -nt "$DAUM_SRC/configure.ac" ]] && return 0
  ( cd "$DAUM_SRC" && ./autogen.sh ) >> "$log" 2>&1 \
    || die "autogen.sh failed -- see $log"
  [[ -x "$DAUM_SRC/configure" ]] || die "autogen.sh produced no configure script"
}

daum_build_arch() {
  set_arch "$1"
  step "Stage 3: DOSBox Daum ${DAUM_VERSION} ($ARCH)"

  local bdir log
  bdir="$BUILD/obj/$ARCH/daum"
  log="$(start_log "daum.${ARCH}.log")"
  rm -rf "$bdir"; mkdir -p "$bdir"

  # The rpath is required at CONFIGURE time, not just for the finished binary.
  # configure.ac does LIBS="$LIBS $SDL_LIBS", so every autoconf test program
  # links -lSDL-1.2 -- and stage 2b rewrote that dylib's install name to
  # @rpath/libSDL-1.2.0.dylib.  Without an rpath the test programs link but
  # cannot execute, and autoconf reports the failure as a *result* rather than
  # an error: AC_CHECK_SIZEOF returns 0 for every type, config.h gets
  # SIZEOF_UNSIGNED_CHAR 0, and acinclude.m4's AH_BOTTOM then fires
  #   #error "sizeof (unsigned char) != 1"
  # which surfaces hundreds of lines later as "unknown type name 'Bit8u'".
  #
  # bundle_relocate() strips this absolute rpath when assembling the .app, and
  # verify-bundle.sh fails the build if one survives.
  local daum_ldflags="$LDFLAGS -Wl,-rpath,${ARCH_PREFIX}/lib"

  ( cd "$bdir" \
    && PATH="$ARCH_PREFIX/bin:$PATH" \
       LDFLAGS="$daum_ldflags" \
       "$DAUM_SRC/configure" \
         --prefix="$BUILD/daum-install-$ARCH" \
         --build="$HOST_TRIPLE" --host="$HOST_TRIPLE" \
         --enable-dynrec \
         --enable-core-inline \
         --enable-unaligned-memory \
         --with-sdl-prefix="$ARCH_PREFIX" \
         --disable-sdltest \
         --disable-alsa-midi \
         --enable-debug \
  ) >> "$log" 2>&1 \
    || die "DOSBox Daum configure ($ARCH) failed -- see $log"

  daum_verify_sizeof "$bdir" "$ARCH" "$log"
  daum_verify_glide_sdk

  ( cd "$bdir" \
    && PATH="$ARCH_PREFIX/bin:$PATH" make -j"$(nproc_count)" \
    && make install ) >> "$log" 2>&1 \
    || die "DOSBox Daum build ($ARCH) failed -- see $log"

  local exe="$BUILD/daum-install-$ARCH/bin/dosbox"
  [[ -x "$exe" ]] || die "no dosbox binary produced for $ARCH"

  daum_verify_core "$log" "$ARCH"
  daum_audit_features "$ARCH"
}

# Catch a broken configure the moment it happens rather than as a wall of
# "unknown type name 'Bit8u'" during compilation.
#
# AC_CHECK_SIZEOF reports a failed test as the *value* 0, not as an error, so
# configure exits 0 with a config.h that cannot possibly work.  Anything that
# stops autoconf's test programs from running -- a missing rpath, a bad flag, a
# broken sysroot -- lands here.
daum_verify_sizeof() {
  # Deliberately split: bash expands every word of a `local` statement before
  # performing any of its assignments, so "local a=$1 b=$a" reads the *caller's*
  # a, not the one being declared -- which under `set -u` either aborts or,
  # worse, silently picks up a stale outer value of the same name.
  local bdir="$1" arch="$2" log="$3"
  local cfg="$bdir/config.h"
  [[ -f "$cfg" ]] || die "configure produced no config.h for $arch -- see $log"

  local name expect got bad=0
  for pair in "SIZEOF_UNSIGNED_CHAR:1" "SIZEOF_UNSIGNED_SHORT:2" \
              "SIZEOF_UNSIGNED_INT:4" "SIZEOF_INT_P:8"; do
    name="${pair%%:*}"; expect="${pair##*:}"
    got="$(awk -v n="$name" '$1=="#define" && $2==n {print $3; exit}' "$cfg")"
    [[ "$got" == "$expect" ]] || { warn "$name = ${got:-<unset>}, expected $expect"; bad=1; }
  done

  if (( bad )); then
    die "configure's type-size probes failed for $arch.

autoconf records a test program that will not RUN as size 0, so configure
exited successfully with a config.h that cannot build.  The usual cause on
macOS is a bundled dylib whose install name is @rpath/... with no matching
rpath on the test binary, so it links but will not execute.

Check config.log for 'Library not loaded':
    grep -n 'Library not loaded' $bdir/config.log"
  fi
  ok "$arch: type sizes probed correctly (configure test programs ran)"
}

# Daum's configure never fails on a missing optional library -- it emits
# AC_MSG_WARN and carries on.  So a build can complete, look entirely healthy,
# and have silently dropped the printer, IPX, compressed CD audio or Media
# Foundation-style capture because a dependency was not found.  Since Daum has
# features no other DOSBox fork reproduces, losing one to an unnoticed warning
# is the worst outcome available.  Read the generated config.h and say so.
daum_audit_features() {
  local arch="$1"
  local cfg="$BUILD/obj/$arch/daum/config.h"   # separate: see daum_verify_sizeof
  [[ -f "$cfg" ]] || { warn "no config.h for $arch; cannot audit features"; return 0; }

  # Report the FPU core from what the sources actually include, NOT from
  # C_FPU_X86.  configure still defines that macro on x86_64 -- we bypass it in
  # the sources rather than reworking configure.ac -- so reading config.h here
  # would report the core that would have been used, which is not the one that
  # was.  It did exactly that for one build, cheerfully announcing an asymmetry
  # that had just been removed.
  #
  # BOTH consumers.  This used to read fpu.cpp alone and print "SoftFloat-3e
  # (80-bit, identical on every slice)", which was a true statement about the
  # interpreter and a false one about the build: core_dynrec/dyn_fpu.h carried
  # its own #if C_FPU_X86 and was still on the 53-bit double core.  The line
  # nobody doubted was the line hiding it.
  local fpu_interp="unknown" fpu_dynrec="unknown"
  _fpu_core_of() {
    if grep -q 'fpu_instructions_softfloat.h' "$1" 2>/dev/null; then echo "SoftFloat-3e"
    elif grep -q 'fpu_instructions_x86.h' "$1" 2>/dev/null;        then echo "x87 asm"
    elif grep -q 'fpu_instructions.h' "$1" 2>/dev/null;            then echo "double"
    else echo "unknown"; fi
  }
  fpu_interp="$(_fpu_core_of "$DAUM_SRC/src/fpu/fpu.cpp")"
  fpu_dynrec="$(_fpu_core_of "$DAUM_SRC/src/cpu/core_dynrec/dyn_fpu.h")"
  if [[ "$fpu_interp" == "SoftFloat-3e" && "$fpu_dynrec" == "SoftFloat-3e" ]]; then
    info_optional "$arch: FPU core = SoftFloat-3e, 80-bit (core=normal and core=dynamic both)"
  else
    die "$arch: the two CPU cores would use different FPUs.
    core=normal  (src/fpu/fpu.cpp)                 -> $fpu_interp
    core=dynamic (core_dynrec/dyn_fpu.h)           -> $fpu_dynrec
Both must be SoftFloat-3e or the same program gives different answers depending
on the [cpu] core setting."
  fi

  # name:description:required
  local features=(
    "C_DYNREC:dynamic recompiler:yes"
    "C_FPU:FPU emulation:yes"
    "C_CORE_INLINE:inlined memory handling:yes"
    "C_OPENGL:OpenGL output (3dfx voodoo needs this):yes"
    "C_LIBPNG:screenshots:yes"
    "C_SSHOT:screenshot support:yes"
    "C_PRINTER:printer emulation:yes"
    "C_MODEM:modem emulation:yes"
    "C_IPX:IPX networking:yes"
    "C_NE2000:NE2000 ethernet passthrough:yes"
    "C_FLUIDSYNTH:SoundFont MIDI:yes"
    "C_SDL_SOUND:compressed CD-DA (ogg/mp3):yes"
    "C_HAVE_PHYSFS:PhysFS drive (mount archives as DOS drives):yes"
    "C_UNALIGNED_MEMORY:unaligned memory access:yes"
    "C_HAVE_MPROTECT:mprotect:yes"
    "C_DIRECTSERIAL:serial passthrough:no"
    "C_DEBUG:built-in debugger (needs a terminal):yes"
    "C_SET_PRIORITY:process priority control (priority= in [sdl]):yes"
  )

  local missing=0 entry name desc req
  say "feature audit ($arch)"
  for entry in "${features[@]}"; do
    name="${entry%%:*}"; entry="${entry#*:}"
    desc="${entry%%:*}"; req="${entry##*:}"
    if grep -qE "^#define ${name}[[:space:]]+1" "$cfg"; then
      printf '        %-20s %s\n' "$name" "$desc" >&2
    elif [[ "$req" == "yes" ]]; then
      warn "$name is OFF -- $desc"
      missing=$((missing+1))
    else
      info_optional "$name is off ($desc), optional"
    fi
  done

  if (( missing > 0 )); then
    die "$missing required feature(s) were disabled for $arch.

Daum's configure only warns about missing libraries, so this would otherwise
have gone unnoticed.  Search the build log for 'WARNING' to see which library
it could not find:
    grep -n 'WARNING' $LOGDIR/daum.${arch}.log"
  fi
  ok "$arch: all required features enabled"
}

info_optional() { printf '        %s\n' "$*" >&2; }

# Confirm configure actually selected the dynamic recompiler, and on arm64 that
# it selected the AArch64 backend.  Falling back to the interpreter silently is
# the single most likely way this build "succeeds" while missing the point.
daum_verify_core() {
  local log="$1" arch="$2"
  local cfg="$BUILD/obj/$arch/daum/config.h"   # separate: see daum_verify_sizeof

  if [[ -f "$cfg" ]]; then
    grep -q '^#define C_DYNREC 1' "$cfg" \
      || die "configure did not enable the dynamic recompiler for $arch -- see $log"
    ok "$arch: dynamic recompiler enabled"

    if [[ "$arch" == "arm64" ]]; then
      grep -q '^#define C_TARGETCPU ARMV8LE' "$cfg" \
        || die "arm64 build did not select the ARMV8LE backend.
config.h says: $(grep C_TARGETCPU "$cfg" 2>/dev/null || echo '<nothing>')
Without it core=dynamic cannot work natively on Apple Silicon."
      ok "arm64: ARMV8LE code generator selected"
    fi
  else
    warn "no config.h found for $arch; cannot confirm which CPU core was built"
  fi
}

build_daum() {
  daum_prepare
  daum_autogen
  local a
  for a in $BUILD_ARCHS; do daum_build_arch "$a"; done
}
