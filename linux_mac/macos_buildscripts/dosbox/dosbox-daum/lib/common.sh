#!/usr/bin/env bash
# lib/common.sh -- shared helpers for the Wine 11.0 universal bundle build.
# shellcheck shell=bash disable=SC2034

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RST=$'\033[0m'; C_B=$'\033[1m'; C_R=$'\033[31m'; C_G=$'\033[32m'
  C_Y=$'\033[33m'; C_C=$'\033[36m'
else
  C_RST=""; C_B=""; C_R=""; C_G=""; C_Y=""; C_C=""
fi

# All progress output goes to stderr.  Several helpers below return values via
# stdout inside $( ), and mixing the two is how you end up with a progress
# message spliced into the middle of a file path.
say()  { printf '%s\n' "${C_C}==>${C_RST} $*" >&2; }
step() { printf '\n%s\n' "${C_B}${C_C}=== $* ===${C_RST}" >&2; }
ok()   { printf '%s\n' "${C_G}  ok${C_RST}  $*" >&2; }
warn() { printf '%s\n' "${C_Y}  warn${C_RST}  $*" >&2; }
die()  { printf '%s\n' "${C_R}  FATAL${C_RST}  $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Environment hygiene
#
# Homebrew and MacPorts must not leak into any configure run.  We rebuild PATH
# from scratch and drop every variable that could pull in /usr/local,
# /opt/homebrew or /opt/local.
# ---------------------------------------------------------------------------
scrub_environment() {
  local keep_path="$1"   # colon-separated prefix to prepend (our own tools)

  unset DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH DYLD_FRAMEWORK_PATH \
        DYLD_INSERT_LIBRARIES LD_LIBRARY_PATH LIBRARY_PATH CPATH \
        C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH \
        PKG_CONFIG_PATH PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR \
        ACLOCAL_PATH M4PATH GI_TYPELIB_PATH XDG_DATA_DIRS \
        HOMEBREW_PREFIX HOMEBREW_CELLAR HOMEBREW_REPOSITORY \
        CFLAGS CXXFLAGS LDFLAGS CPPFLAGS OBJCFLAGS \
        PYTHONPATH PYTHONHOME PERL5LIB GEM_HOME 2>/dev/null || true

  export PATH="${keep_path}:/usr/bin:/bin:/usr/sbin:/sbin"
  export LC_ALL=C
  export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"

  # Sanity: nothing from a package manager may be reachable.
  local p
  for p in /opt/homebrew /usr/local/Homebrew /opt/local; do
    case ":$PATH:" in
      *":$p/bin:"*) die "PATH still contains $p/bin after scrubbing" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Stamps (resumable builds)
# ---------------------------------------------------------------------------
stamp_path() { printf '%s/%s.done' "$STAMPS" "$1"; }
stamp_have() { [[ -f "$(stamp_path "$1")" ]]; }
stamp_set()  { mkdir -p "$STAMPS"; : > "$(stamp_path "$1")"; }
stamp_clear(){ rm -f "$(stamp_path "$1")"; }

# Run a stage only once.  usage: once <name> <command...>
once() {
  local name="$1"; shift
  if stamp_have "$name"; then
    ok "skip $name (already built)"
    return 0
  fi
  say "build $name"
  "$@"
  stamp_set "$name"
  ok "done $name"
}

# As once(), but the stamp is only believed if the artifact it claims to have
# produced is still present.  A stamp is a claim; the installed file is the
# evidence.  Prefixes get wiped far more often than stamps do -- by hand, by a
# --clean that misses the stamp directory, by an interrupted run -- and the
# resulting failure is silent: Daum's configure merely warns that the library
# is missing and switches the feature off, so the build "succeeds" without it.
# usage: once_artifact <name> <glob> <command...>
once_artifact() {
  local name="$1" glob="$2"; shift 2
  if stamp_have "$name"; then
    if compgen -G "$glob" >/dev/null; then
      ok "skip $name (already built)"
      return 0
    fi
    warn "$name is stamped as built but $glob is missing -- rebuilding"
    stamp_clear "$name"
  fi
  say "build $name"
  "$@"
  compgen -G "$glob" >/dev/null \
    || die "$name reported success but installed no $glob"
  stamp_set "$name"
  ok "done $name"
}

# ---------------------------------------------------------------------------
# Download + checksum
# ---------------------------------------------------------------------------
known_sha_for() {
  local base="$1" line name hash
  for line in "${KNOWN_SHA256[@]}"; do
    # shellcheck disable=SC2086
    set -- $line
    name="$1"; hash="$2"
    [[ "$name" == "$base" ]] && { printf '%s' "$hash"; return 0; }
  done
  return 1
}

sha256_of() { /usr/bin/shasum -a 256 "$1" | awk '{print $1}'; }

# Fallback mirrors, keyed by the name fetch() saves the file under -- so a
# mirror may serve it under a different name (Debian calls nasm's tarball
# nasm_2.16.03.orig.tar.xz) and the local copy still gets the canonical one.
#
# Same "key value..." array-of-strings shape as KNOWN_SHA256, and for the same
# reason: macOS ships bash 3.2, which has no associative arrays.
#
# This is only safe because the checksum is pinned. A mirror is an untrusted
# host serving a file we did not publish; what makes it acceptable is that
# fetch() rejects anything whose sha256 does not match the pin, so the worst a
# bad mirror can do is fail the build loudly. Do not add a mirror for a source
# that has neither a pin in KNOWN_SHA256 nor a published sidecar.
mirrors_for() {
  local base="$1" line name
  for line in ${SOURCE_MIRRORS[@]+"${SOURCE_MIRRORS[@]}"}; do
    # shellcheck disable=SC2086
    set -- $line
    name="$1"; shift
    [[ "$name" == "$base" ]] && { printf '%s\n' "$@"; return 0; }
  done
  return 1
}

# Many upstreams publish a checksum next to the tarball.  Using it means a
# version bump does not silently lose integrity checking, which is what would
# otherwise happen with hand-pinned hashes in versions.sh.
_sidecar_sha() {
  local url="$1" base="$2" cand body hash
  for cand in "${url}.sha256sum" "${url}.sha256" "${url}.sha256.txt" "${url}.SHA256"; do
    body="$(curl -fsSL --max-time 30 --connect-timeout 15 "$cand" 2>/dev/null)" || continue
    hash="$(printf '%s\n' "$body" | awk -v b="$base" '
        { n = $2; sub(/^\*/, "", n); sub(/.*\//, "", n)
          if (n == b && $1 ~ /^[0-9a-fA-F]{64}$/) { print tolower($1); exit } }')"
    [[ -n "$hash" ]] && { printf '%s' "$hash"; return 0; }
  done
  return 1
}

# A file that fails its checksum must not stay where fetch() will find it.
# Otherwise the next run sees a non-empty $out, skips the download entirely, and
# fails on the same bad bytes forever -- with an error that says "mismatch",
# never "delete this file".  Move it aside instead: the retry works, and the
# evidence survives for anyone who wants to look at what a mirror actually
# served.
_reject() {
  local out="$1" base="$2" expect="$3" sum="$4" src="$5"
  mv -f "$out" "$out.bad" 2>/dev/null || rm -f "$out"
  die "checksum mismatch for $base ($src)
  expected $expect
  got      $sum
The download has been moved to $out.bad and will be re-fetched on the next run.
If it came from a mirror, treat that mirror as untrusted until you know why."
}

fetch() {
  local url="$1" base out sum expect from_mirror=0
  base="${2:-$(basename "$url")}"
  out="$DOWNLOADS/$base"
  mkdir -p "$DOWNLOADS"

  if [[ ! -s "$out" ]]; then
    say "fetch $base"
    # Primary first, then any mirror. Upstream hosts go down -- nasm.us refused
    # connections outright (curl 000, not a 404) while its own front page was
    # serving fine -- and a project that builds every dependency from source
    # has a lot of hosts to be unlucky with.
    local u tried=""
    for u in "$url" $(mirrors_for "$base" || true); do
      [[ -n "$tried" ]] && say "  primary failed, trying mirror: $u"
      if curl --fail --location --retry 3 --retry-delay 2 --connect-timeout 30 \
              --progress-bar -o "$out.part" "$u"; then
        mv "$out.part" "$out"
        [[ -n "$tried" ]] && from_mirror=1
        break
      fi
      rm -f "$out.part"
      tried="$tried
    $u"
    done
    [[ -s "$out" ]] || die "download failed for $base. Tried:$tried

If every host is down, wait and retry -- anything already in $DOWNLOADS is
reused. To add a mirror, see SOURCE_MIRRORS in versions.sh; it is only safe for
sources with a pinned sha256."
  fi

  sum="$(sha256_of "$out")"
  # The sidecar is looked for beside the PRIMARY url, never beside the mirror
  # that served the file.  A checksum from the same host as the download proves
  # nothing -- that host can serve both -- so it would be verification in
  # appearance only.
  if expect="$(known_sha_for "$base")"; then
    [[ "$sum" == "$expect" ]] || _reject "$out" "$base" "$expect" "$sum" "pinned in versions.sh"
  elif expect="$(_sidecar_sha "$url" "$base")"; then
    [[ "$sum" == "$expect" ]] || _reject "$out" "$base" "$expect" "$sum" "upstream sidecar"
  else
    # Nothing to check it against.  Tolerable from the publisher's own host --
    # that is the status quo, recorded in checksums.observed -- but not from a
    # mirror, which is a third party serving a file we cannot recognise.  This
    # makes "never add a mirror without a pin" an enforced rule rather than a
    # comment someone has to remember.
    if [[ "$from_mirror" == "1" ]]; then
      mv -f "$out" "$out.unverified" 2>/dev/null || rm -f "$out"
      die "$base was served by a mirror and cannot be verified (observed $sum).
No entry in KNOWN_SHA256 and no sidecar next to the primary URL, so there is
nothing that says these are the right bytes.  Pin the sha256 in versions.sh --
from a source independent of the mirror -- or drop the mirror.
Saved as $out.unverified so you can inspect it; it will not be reused."
    fi
    if [[ "$STRICT_SHA" == "1" ]]; then
      die "no pinned or upstream sha256 for $base (observed $sum) and --strict-sha is set"
    fi
    grep -qs "  $base\$" "$OBSERVED_SHA" 2>/dev/null \
      || printf '%s  %s\n' "$sum" "$base" >> "$OBSERVED_SHA"
  fi
  printf '%s' "$out"
}

# Extract into $SOURCES and echo the resulting source directory.
extract() {
  local tarball="$1" name top
  name="$(basename "$tarball")"
  mkdir -p "$SOURCES"
  top="$(tar -tf "$tarball" 2>/dev/null | sed 's|^\./||' | grep -v '^$' | head -1 | cut -d/ -f1)"
  [[ -n "$top" && "$top" != "." ]] || die "cannot determine the top-level directory of $name"
  if [[ ! -d "$SOURCES/$top" ]]; then
    tar -xf "$tarball" -C "$SOURCES" || die "extract failed: $name"
  fi
  printf '%s' "$SOURCES/$top"
}

# ---------------------------------------------------------------------------
# Per-architecture compiler environment
# ---------------------------------------------------------------------------
# set_arch <arch>   -- arch is arm64 or x86_64
set_arch() {
  ARCH="$1"
  ARCH_PREFIX="$BUILD/prefix-$ARCH"
  # Use aarch64 rather than arm64 in the autoconf triple: every config.sub in
  # circulation understands aarch64-apple-darwin, and packages with hand-written
  # per-CPU assembly (gmp, nettle, ffmpeg) key off $host_cpu.
  if [[ "$ARCH" == "arm64" ]]; then
    HOST_TRIPLE="aarch64-apple-darwin"
  else
    HOST_TRIPLE="${ARCH}-apple-darwin"
  fi
  mkdir -p "$ARCH_PREFIX/lib/pkgconfig" "$ARCH_PREFIX/include"

  export CC="clang -arch $ARCH"
  export CXX="clang++ -arch $ARCH"
  export OBJC="clang -arch $ARCH"
  export OBJCXX="clang++ -arch $ARCH"

  # AVAIL_GUARD defaults to -Werror=unguarded-availability-new, which turns
  # "this API needs a newer macOS than your deployment target" from a silent
  # weak-link into a compile error.  It is the single most effective guard for
  # the macOS 11 requirement.  Escape hatch: AVAIL_GUARD= ./${SCRIPT_NAME}
  export CFLAGS="-arch $ARCH -mmacosx-version-min=${DEPLOYMENT_TARGET} -O2 -g0 -isysroot ${SDKROOT} ${AVAIL_GUARD}"
  export CXXFLAGS="$CFLAGS"
  export OBJCFLAGS="$CFLAGS"
  export CPPFLAGS="-I${ARCH_PREFIX}/include -isysroot ${SDKROOT} -mmacosx-version-min=${DEPLOYMENT_TARGET}"
  # -headerpad_max_install_names is mandatory: without it install_name_tool
  # cannot rewrite absolute dependency paths to @rpath later on.
  export LDFLAGS="-arch $ARCH -mmacosx-version-min=${DEPLOYMENT_TARGET} -isysroot ${SDKROOT} -L${ARCH_PREFIX}/lib -Wl,-headerpad_max_install_names"

  export PKG_CONFIG="$TOOLS/bin/pkgconf"
  export PKG_CONFIG_LIBDIR="${ARCH_PREFIX}/lib/pkgconfig:${ARCH_PREFIX}/share/pkgconfig"
  export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"
}

nproc_count() { sysctl -n hw.ncpu 2>/dev/null || echo 4; }

# Begin a fresh log for one build attempt, keeping the previous one as .prev.
# Appending across attempts makes every failure ambiguous: you cannot tell which
# run an error belongs to.
start_log() {
  local l="$LOGDIR/$1"
  mkdir -p "$LOGDIR"
  [[ -f "$l" ]] && mv -f "$l" "$l.prev"
  : > "$l"
  printf '%s' "$l"
}

# ---------------------------------------------------------------------------
# Generic builders
# ---------------------------------------------------------------------------
# build_autotools <name> <srcdir> [configure args...]
build_autotools() {
  local name="$1" src="$2"; shift 2
  local bdir="$BUILD/obj/$ARCH/$name" log
  log="$(start_log "${name}.${ARCH}.log")"
  rm -rf "$bdir"; mkdir -p "$bdir"
  ( cd "$bdir" \
    && "$src/configure" --prefix="$ARCH_PREFIX" \
         --build="$HOST_TRIPLE" --host="$HOST_TRIPLE" \
         --enable-shared --disable-static "$@" \
    && make -j"$(nproc_count)" \
    && make install ) >> "$log" 2>&1 \
    || die "$name ($ARCH) failed -- see $log"
}

# build_tool_autotools <name> <srcdir> [configure args...]
# Native build of a build-time-only tool into $TOOLS.  Always host arch.
build_tool_autotools() {
  local name="$1" src="$2"; shift 2
  local bdir="$BUILD/obj/tools/$name" log
  log="$(start_log "tool-${name}.log")"
  rm -rf "$bdir"; mkdir -p "$bdir"
  ( cd "$bdir" \
    && env -u CFLAGS -u CXXFLAGS -u LDFLAGS -u CPPFLAGS -u CC -u CXX \
         MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
         "$src/configure" --prefix="$TOOLS" "$@" \
    && make -j"$(nproc_count)" \
    && make install ) >> "$log" 2>&1 \
    || die "tool $name failed -- see $log"
}

# Write a meson machine file for the current $ARCH.
#   $1 = "native" (compiling for the machine we are on) or "cross"
# A [host_machine] section is only legal in a cross file, so the two flavours
# have to differ.
meson_machine_file() {
  local mode="$1"
  local out="$BUILD/meson-${ARCH}-${mode}.ini"
  local cpu_family="$ARCH" cpu="$ARCH"
  [[ "$ARCH" == "arm64" ]] && { cpu_family="aarch64"; cpu="aarch64"; }
  # Every common flag is baked into the compiler command rather than left to
  # [built-in options] below.  Meson honours built-in c_args/c_link_args in its
  # own compiler checks but does not reliably put them on real link lines, which
  # produces the worst possible failure: a dependency that is *detected*
  # successfully (the check link had -L) and then fails to link (the build link
  # did not).  Arguments attached to the binary itself always apply.
  #
  # Only flags that are valid for BOTH compiling and linking go here.  The
  # prefix search paths are deliberately absent: meson reuses this one command
  # for compile-only checks too, and a -L there breaks them in ways that look
  # nothing like the cause (meson reports that "long long" does not compile).
  # They are passed via CPATH/LIBRARY_PATH in build_meson() instead, which
  # clang honours without putting anything on the command line at all.
  local common="'-arch', '${ARCH}', '-Wno-unused-command-line-argument', '-isysroot', '${SDKROOT}', '-mmacosx-version-min=${DEPLOYMENT_TARGET}'"
  local cflags_common="$common${AVAIL_GUARD:+, '${AVAIL_GUARD}'}"

  cat > "$out" <<EOF
[binaries]
c          = ['clang', ${cflags_common}]
cpp        = ['clang++', ${cflags_common}]
objc       = ['clang', ${common}]
objcpp     = ['clang++', ${common}]
ar         = '$(xcrun -f ar 2>/dev/null || echo /usr/bin/ar)'
strip      = '$(xcrun -f strip 2>/dev/null || echo /usr/bin/strip)'
pkg-config = '${TOOLS}/bin/pkgconf'
nasm       = '${TOOLS}/bin/nasm'

[built-in options]
# Redundant with the flags baked into [binaries] above, and kept only for the
# paths meson drives from options rather than the compiler command.  Duplicate
# -I/-L/-isysroot on a clang command line is harmless.
c_link_args   = ['-L${ARCH_PREFIX}/lib', '-Wl,-headerpad_max_install_names']
cpp_link_args = ['-L${ARCH_PREFIX}/lib', '-Wl,-headerpad_max_install_names']
EOF

  if [[ "$mode" == "cross" ]]; then
    cat >> "$out" <<EOF

[properties]
# Binaries produced for x86_64 run on Apple Silicon through Rosetta 2, so meson
# may execute its own test programs instead of demanding an exe wrapper.
needs_exe_wrapper = false

[host_machine]
system     = 'darwin'
subsystem  = 'macos'
kernel     = 'xnu'
cpu_family = '${cpu_family}'
cpu        = '${cpu}'
endian     = 'little'
EOF
  fi
  printf '%s' "$out"
}

# Option names a project actually declares.
meson_known_opts() {
  local src="$1" f
  for f in "$src/meson_options.txt" "$src/meson.options"; do
    [[ -f "$f" ]] || continue
    sed -n "s/^[[:space:]]*option[[:space:]]*([[:space:]]*['\"]\([A-Za-z0-9_.-]*\)['\"].*/\1/p" "$f"
  done
}

# Meson's own options, which no project declares but every project accepts.
MESON_BUILTIN_OPTS="auto_features backend buildtype debug default_library errorlogs
install_umask layout optimization prefix strip unity warning_level werror wrap_mode
bindir datadir includedir infodir libdir libexecdir localedir mandir sbindir
sharedstatedir sysconfdir localstatedir prefer_static vsenv force_fallback_for
pkg_config_path cmake_prefix_path"

# Drop -Dfoo=... for options the project does not define.
#
# Plugin sets rename and retire options between releases -- gst-plugins-good has
# no 'introspection' because it ships no introspectable libraries, while core,
# base and bad all do -- and meson treats one unknown option as a fatal error.
# Filtering keeps a version bump from turning into a scavenger hunt.
meson_filter_opts() {
  local src="$1"; shift
  local known name a
  known=" $(meson_known_opts "$src" | tr '\n' ' ') $(printf '%s' "$MESON_BUILTIN_OPTS" | tr '\n' ' ') "
  for a in "$@"; do
    case "$a" in
      -D*=*)
        name="${a#-D}"; name="${name%%=*}"
        case "$known" in
          *" $name "*) printf '%s\n' "$a" ;;
          *) warn "$(basename "$src"): no option '$name' in this release, skipping" >&2 ;;
        esac
        ;;
      *) printf '%s\n' "$a" ;;
    esac
  done
}

# build_meson <name> <srcdir> [meson args...]
build_meson() {
  local name="$1" src="$2"; shift 2
  local bdir="$BUILD/obj/$ARCH/$name" mfile log
  log="$(start_log "${name}.${ARCH}.log")"
  local -a mach=()
  if [[ "$ARCH" == "$HOST_ARCH" ]]; then
    mfile="$(meson_machine_file native)"
    mach=(--native-file "$mfile")
  else
    mfile="$(meson_machine_file cross)"
    mach=(--cross-file "$mfile")
  fi
  local -a opts=()
  while IFS= read -r _o; do opts[${#opts[@]}]="$_o"; done < <(meson_filter_opts "$src" "$@")

  rm -rf "$bdir"
  ( export PKG_CONFIG_LIBDIR="${ARCH_PREFIX}/lib/pkgconfig:${ARCH_PREFIX}/share/pkgconfig"
    # clang reads these the same way it reads -I and -L, but because they never
    # appear on a command line they cannot upset compile-only invocations.  This
    # is what lets meson's builtin 'intl' dependency -- resolved by a
    # find_library() link test rather than pkg-config -- actually find the
    # libintl we built, at check time and at build time alike.
    export CPATH="${ARCH_PREFIX}/include"
    export LIBRARY_PATH="${ARCH_PREFIX}/lib"
    # OBJCFLAGS/OBJCXXFLAGS matter as much as CFLAGS here: meson reads them from
    # the environment and appends them to Objective-C compile lines, which is
    # how set_arch's flags were reappearing on .m files despite the machine file
    # deliberately leaving the availability guard off objc.
    unset CFLAGS CXXFLAGS OBJCFLAGS OBJCXXFLAGS LDFLAGS CPPFLAGS CC CXX OBJC OBJCXX
    "$VENV/bin/meson" setup "$bdir" "$src" \
      --prefix="$ARCH_PREFIX" \
      --libdir=lib \
      --buildtype=release \
      --default-library=shared \
      "${mach[@]}" \
      ${opts[@]+"${opts[@]}"} \
    && "$VENV/bin/meson" compile -C "$bdir" \
    && "$VENV/bin/meson" install -C "$bdir" --no-rebuild \
  ) >> "$log" 2>&1 \
    || die "$name ($ARCH) failed -- see $log"
}

# ---------------------------------------------------------------------------
# Mach-O helpers
# ---------------------------------------------------------------------------
is_macho() {
  local f="$1" magic
  [[ -f "$f" ]] || return 1
  magic="$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n')"
  case "$magic" in
    cffaedfe|cefaedfe|feedfacf|feedface|cafebabe|bebafeca|cffaedfe*) return 0 ;;
    *) return 1 ;;
  esac
}

# Print every Mach-O file under a directory, NUL-separated.
macho_find0() {
  local root="$1" f
  while IFS= read -r -d '' f; do
    is_macho "$f" && printf '%s\0' "$f"
  done < <(find "$root" -type f -print0)
}

# Minimum OS version recorded in a Mach-O (per slice).  Prints one line per slice.
macho_minos() {
  local f="$1"
  /usr/bin/otool -l "$f" 2>/dev/null | awk '
    /^ *cmd LC_BUILD_VERSION/ { inbv=1; next }
    /^ *cmd LC_VERSION_MIN_MACOSX/ { invm=1; next }
    inbv && /^ *minos/ { print $2; inbv=0 }
    invm && /^ *version/ { print $2; invm=0 }
  '
}

macho_archs() { /usr/bin/lipo -archs "$1" 2>/dev/null || true; }

# Ad-hoc sign a single Mach-O, preserving entitlements when supplied.
sign_macho() {
  local f="$1" ents="${2:-}"
  if [[ -n "$ents" ]]; then
    codesign --force --sign - --timestamp=none --entitlements "$ents" "$f" 2>/dev/null \
      || warn "codesign failed: $f"
  else
    codesign --force --sign - --timestamp=none "$f" 2>/dev/null \
      || warn "codesign failed: $f"
  fi
}

# Rewrite every Mach-O in a prefix so that its install name and all of its
# intra-prefix dependencies are @rpath-relative, and drop the absolute rpaths
# libtool and meson bake in.
#
# The rpath stripping MUST happen here, on the thin per-architecture files,
# rather than later on the lipo'd universal ones.  Each slice carries a
# different absolute path (prefix-arm64 vs prefix-x86_64), and
# install_name_tool -delete_rpath is all-or-nothing across slices: it refuses
# any path that is not present in every architecture, so on a fat library it
# silently removes neither.
rpathify_prefix() {
  local prefix="$1" f base dep rp
  while IFS= read -r -d '' f; do
    base="$(basename "$f")"
    chmod u+w "$f" 2>/dev/null || true

    case "$f" in
      *.dylib|*.so) install_name_tool -id "@rpath/$base" "$f" 2>/dev/null || true ;;
    esac

    while read -r dep; do
      case "$dep" in
        "$prefix"/*|"$BUILD"/prefix-*/*)
          install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$f" 2>/dev/null || true
          ;;
      esac
      # Tab-indented lines only; see bundle_relocate for why.
    done < <(/usr/bin/otool -L "$f" | awk '/^\t/{print $1}')

    while read -r rp; do
      case "$rp" in
        @loader_path*|@executable_path*|"") ;;
        *) install_name_tool -delete_rpath "$rp" "$f" 2>/dev/null || true ;;
      esac
    done < <(/usr/bin/otool -l "$f" | awk '/LC_RPATH/{r=1} r&&/^ *path /{print $2; r=0}')

    sign_macho "$f"
  done < <(macho_find0 "$prefix")
}

# lipo_merge <arm64-file> <x86_64-file> <out>
lipo_merge() {
  local a="$1" b="$2" out="$3"
  mkdir -p "$(dirname "$out")"
  if [[ -f "$a" && -f "$b" ]]; then
    if is_macho "$a" && is_macho "$b"; then
      lipo -create "$a" "$b" -output "$out" 2>/dev/null || cp -p "$b" "$out"
    else
      cp -p "$b" "$out"
    fi
  elif [[ -f "$b" ]]; then
    cp -p "$b" "$out"
  elif [[ -f "$a" ]]; then
    cp -p "$a" "$out"
  fi
}

# Copy one library (and any symlinks that point at it) from the per-arch
# prefixes into a destination directory as a universal binary.
install_universal_lib() {
  local relpath="$1" destdir="$2"
  local base; base="$(basename "$relpath")"
  local a="$BUILD/prefix-arm64/$relpath"
  local x="$BUILD/prefix-x86_64/$relpath"
  mkdir -p "$destdir"
  if [[ "$UNIVERSAL_DEPS" == "1" ]]; then
    lipo_merge "$a" "$x" "$destdir/$base"
  elif [[ -f "$x" ]]; then
    cp -p "$x" "$destdir/$base"
  fi
  [[ -f "$destdir/$base" ]] && chmod u+w "$destdir/$base"
  return 0
}

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

# Pull the actual failure out of a build log.
#
# Tailing is the wrong tool here: ninja runs jobs in parallel, so by the time it
# stops the failing compiler output is buried under dozens of lines from other
# jobs that were still in flight.  Anchor on the failure marker instead.
log_excerpt() {
  local l="$1" lines="${2:-40}" start=""
  [[ -f "$l" ]] || return 0

  # Anchor on the LAST marker, not the first.  Logs used to be appended across
  # runs, so the first "FAILED:" could belong to an attempt from an hour ago --
  # which is exactly the sort of stale evidence that sends you chasing a bug you
  # already fixed.  start_log() now truncates per attempt as well.
  start="$(grep -n -E '^FAILED:' "$l" | tail -1 | cut -d: -f1)"
  [[ -z "$start" ]] && start="$(grep -n -E '(^| )error:' "$l" | tail -1 | cut -d: -f1)"
  [[ -z "$start" ]] && start="$(grep -n -E 'Error [0-9]+$' "$l" | tail -1 | cut -d: -f1)"

  printf '  --- %s ---\n' "$l"
  if [[ -n "$start" ]]; then
    (( start > 3 )) && start=$(( start - 3 ))
    sed -n "${start},$(( start + lines ))p" "$l" | sed 's/^/  /'
    printf '  ... (full log: %s)\n' "$l"
  else
    tail -"$lines" "$l" | sed 's/^/  /'
  fi
}
