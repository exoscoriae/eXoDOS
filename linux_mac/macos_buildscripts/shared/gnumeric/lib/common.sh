# =============================================================================
# lib/common.sh - shared infrastructure: environment, manifest, download,
#                 extract, autotools/meson build helpers, arch handling.
# Compatible with macOS /bin/bash 3.2 (no associative arrays etc.)
# =============================================================================

# ---- global layout ----------------------------------------------------------
WORK="$TOP/work"
SRC="$WORK/src"            # downloaded tarballs
BLD="$WORK/build"          # per-arch build trees
TOOLS="$WORK/tools"        # native host tools prefix (pkg-config, meson, ...)
STAMPS="$WORK/stamps"
DIST="$TOP/dist"
LOCKFILE="$TOP/config/checksums.lock"

MACOS_MIN="11.0"
export MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN"

NATIVE_ARCH="$(uname -m)"   # arm64 on Apple Silicon, x86_64 on Intel

mkdir -p "$WORK" "$SRC" "$BLD" "$STAMPS" "$TOOLS/bin" "$TOP/config"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ---- package manifest -------------------------------------------------------
# One line per package: name version url
# Order in DEP_ORDER below is the build order and matters.
pkg_line() {
  case "$1" in
    pkgconfig)  echo "pkgconfig 0.29.2 https://pkg-config.freedesktop.org/releases/pkg-config-0.29.2.tar.gz" ;;
    ninja)      echo "ninja 1.11.1 https://github.com/ninja-build/ninja/archive/refs/tags/v1.11.1.tar.gz" ;;
    meson)      echo "meson 1.4.2 https://github.com/mesonbuild/meson/releases/download/1.4.2/meson-1.4.2.tar.gz" ;;
    xmlparser)  echo "xmlparser 2.47 https://cpan.metacpan.org/authors/id/T/TO/TODDR/XML-Parser-2.47.tar.gz" ;;
    intltool)   echo "intltool 0.51.0 https://launchpad.net/intltool/trunk/0.51.0/+download/intltool-0.51.0.tar.gz" ;;
    gettext)    echo "gettext 0.22.5 https://ftp.gnu.org/gnu/gettext/gettext-0.22.5.tar.xz" ;;
    zlib)       echo "zlib 1.3.1 https://zlib.net/fossils/zlib-1.3.1.tar.gz" ;;
    libffi)     echo "libffi 3.6.0 https://github.com/libffi/libffi/releases/download/v3.6.0/libffi-3.6.0.tar.gz" ;;
    pcre2)      echo "pcre2 10.43 https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.43/pcre2-10.43.tar.bz2" ;;
    expat)      echo "expat 2.6.2 https://github.com/libexpat/libexpat/releases/download/R_2_6_2/expat-2.6.2.tar.xz" ;;
    libpng)     echo "libpng 1.6.43 https://download.sourceforge.net/libpng/libpng-1.6.43.tar.xz" ;;
    jpeg)       echo "jpeg 9f https://www.ijg.org/files/jpegsrc.v9f.tar.gz" ;;
    freetype)   echo "freetype 2.13.2 https://download.savannah.gnu.org/releases/freetype/freetype-2.13.2.tar.xz" ;;
    fontconfig) echo "fontconfig 2.15.0 https://www.freedesktop.org/software/fontconfig/release/fontconfig-2.15.0.tar.xz" ;;
    glib)       echo "glib 2.78.6 https://download.gnome.org/sources/glib/2.78/glib-2.78.6.tar.xz" ;;
    libxml2)    echo "libxml2 2.12.7 https://download.gnome.org/sources/libxml2/2.12/libxml2-2.12.7.tar.xz" ;;
    libxslt)    echo "libxslt 1.1.39 https://download.gnome.org/sources/libxslt/1.1/libxslt-1.1.39.tar.xz" ;;
    fribidi)    echo "fribidi 1.0.15 https://github.com/fribidi/fribidi/releases/download/v1.0.15/fribidi-1.0.15.tar.xz" ;;
    harfbuzz)   echo "harfbuzz 8.5.0 https://github.com/harfbuzz/harfbuzz/releases/download/8.5.0/harfbuzz-8.5.0.tar.xz" ;;
    pixman)     echo "pixman 0.42.2 https://www.cairographics.org/releases/pixman-0.42.2.tar.gz" ;;
    cairo)      echo "cairo 1.18.0 https://www.cairographics.org/releases/cairo-1.18.0.tar.xz" ;;
    gdkpixbuf)  echo "gdkpixbuf 2.42.12 https://download.gnome.org/sources/gdk-pixbuf/2.42/gdk-pixbuf-2.42.12.tar.xz" ;;
    atk)        echo "atk 2.38.0 https://download.gnome.org/sources/atk/2.38/atk-2.38.0.tar.xz" ;;
    libepoxy)   echo "libepoxy 1.5.10 https://download.gnome.org/sources/libepoxy/1.5/libepoxy-1.5.10.tar.xz" ;;
    pango)      echo "pango 1.50.14 https://download.gnome.org/sources/pango/1.50/pango-1.50.14.tar.xz" ;;
    gtk3)       echo "gtk3 3.24.43 https://download.gnome.org/sources/gtk%2B/3.24/gtk%2B-3.24.43.tar.xz" ;;
    libgsf)     echo "libgsf 1.14.55 https://download.gnome.org/sources/libgsf/1.14/libgsf-1.14.55.tar.xz" ;;
    libcroco)   echo "libcroco 0.6.13 https://download.gnome.org/sources/libcroco/0.6/libcroco-0.6.13.tar.xz" ;;
    librsvg)    echo "librsvg 2.40.21 https://download.gnome.org/sources/librsvg/2.40/librsvg-2.40.21.tar.xz" ;;
    hicolor)    echo "hicolor 0.17 https://icon-theme.freedesktop.org/releases/hicolor-icon-theme-0.17.tar.xz" ;;
    adwaita)    echo "adwaita 41.0 https://download.gnome.org/sources/adwaita-icon-theme/41/adwaita-icon-theme-41.0.tar.xz" ;;
    goffice)    echo "goffice 0.10.61 https://download.gnome.org/sources/goffice/0.10/goffice-0.10.61.tar.xz" ;;
    gnumeric)   echo "gnumeric 1.12.61 https://download.gnome.org/sources/gnumeric/1.12/gnumeric-1.12.61.tar.xz" ;;
    *) return 1 ;;
  esac
}

ALL_PKGS="pkgconfig ninja meson xmlparser intltool gettext zlib libffi pcre2 expat \
libpng jpeg freetype fontconfig glib libxml2 libxslt fribidi harfbuzz pixman \
cairo gdkpixbuf atk libepoxy pango gtk3 libgsf libcroco librsvg hicolor \
adwaita goffice gnumeric"

# Per-arch build order for the library stack (host tools are separate)
DEP_ORDER="zlib libffi expat gettext pcre2 libpng jpeg freetype fontconfig \
glib libxml2 libxslt fribidi harfbuzz pixman cairo gdkpixbuf atk libepoxy \
pango gtk3 libgsf libcroco librsvg hicolor adwaita goffice gnumeric"

pkg_version() { pkg_line "$1" | awk '{print $2}'; }
pkg_url()     { pkg_line "$1" | awk '{print $3}'; }
pkg_tarball() { basename "$(pkg_url "$1" | sed 's/%2B/+/g')"; }

# Directory name inside the tarball (usually name-version, with exceptions)
pkg_srcdir() {
  case "$1" in
    jpeg)      echo "jpeg-9f" ;;
    ninja)     echo "ninja-1.11.1" ;;
    xmlparser) echo "XML-Parser-2.47" ;;
    pkgconfig) echo "pkg-config-0.29.2" ;;
    gdkpixbuf) echo "gdk-pixbuf-$(pkg_version gdkpixbuf)" ;;
    gtk3)      echo "gtk+-$(pkg_version gtk3)" ;;
    hicolor)   echo "hicolor-icon-theme-0.17" ;;
    adwaita)   echo "adwaita-icon-theme-41.0" ;;
    *)         echo "$1-$(pkg_version "$1")" ;;
  esac
}

# ---- sanity checks ----------------------------------------------------------
sanity_checks() {
  [ "$(uname -s)" = "Darwin" ] || die "This build system must run on macOS."

  xcode-select -p >/dev/null 2>&1 || \
    die "Xcode Command Line Tools not installed. Run: xcode-select --install"

  SDKROOT="$(xcrun --show-sdk-path 2>/dev/null)" || die "Cannot locate macOS SDK (xcrun failed)."
  export SDKROOT
  command -v clang  >/dev/null || die "clang not found"
  command -v python3 >/dev/null || die "python3 not found (install Command Line Tools)"
  command -v bison  >/dev/null || die "bison not found (should ship with macOS)"

  # We build the non-native arch as a 'native' build and rely on being able
  # to EXECUTE its binaries. On Apple Silicon that means Rosetta 2.
  if [ "$NATIVE_ARCH" = "arm64" ]; then
    if ! arch -x86_64 /usr/bin/true 2>/dev/null; then
      die "Rosetta 2 is required to build the x86_64 half.
Install it with:  softwareupdate --install-rosetta --agree-to-license"
    fi
  fi
}

# ---- download & verify ------------------------------------------------------
fetch() { # fetch <url> <dest>
  curl -fL --retry 3 --connect-timeout 30 -o "$2.part" "$1" && mv "$2.part" "$2"
}

sha256_of() { /usr/bin/shasum -a 256 "$1" | awk '{print $1}'; }

# Trust-on-first-use checksum ledger: config/checksums.lock
# Keyed by tarball filename, so version bumps start a fresh entry.
verify_or_record() { # <name> <file>
  local file="$2" base sum have
  base="$(basename "$file")"
  sum="$(sha256_of "$file")"
  touch "$LOCKFILE"
  have="$(awk -v n="$base" '$1==n{print $2; exit}' "$LOCKFILE")" || true
  if [ -z "$have" ]; then
    echo "$base $sum" >> "$LOCKFILE"
    echo "    recorded sha256 $sum"
  elif [ "$have" != "$sum" ]; then
    die "Checksum mismatch for $base!
  expected: $have
  actual:   $sum
If this is intentional, remove the $base line from config/checksums.lock and re-run."
  fi
}

# GNOME publishes .sha256sum files next to every tarball - verify those hard.
verify_gnome() { # <name> <file> <url>
  local url sums want base
  url="${3%.tar.xz}.sha256sum"
  base="$(basename "$2")"
  sums="$SRC/.$base.sha256sum"
  if ! fetch "$url" "$sums" 2>/dev/null; then
    warn "could not fetch GNOME checksum file for $base (continuing with TOFU)"
    return 0
  fi
  # exact string match on the last field - no regex, so '+' etc. are safe
  want="$(awk -v f="$base" '$NF == f {print $1; exit}' "$sums")" || true
  if [ -z "$want" ]; then
    warn "no entry for $base in GNOME checksum file (continuing with TOFU)"
    return 0
  fi
  if [ "$want" != "$(sha256_of "$2")" ]; then
    die "GNOME sha256 verification FAILED for $base"
  fi
  echo "    GNOME sha256 verified"
  return 0
}

download_all() {
  log "Downloading sources into work/src"
  local p line url tb
  for p in $ALL_PKGS; do
    url="$(pkg_url "$p")"
    tb="$SRC/$(pkg_tarball "$p")"
    if [ ! -f "$tb" ]; then
      echo "  fetching $(basename "$tb")"
      fetch "$url" "$tb" || die "Download failed: $url"
    fi
    case "$url" in
      https://download.gnome.org/*) verify_gnome "$p" "$tb" "$url" ;;
    esac
    verify_or_record "$p" "$tb"
  done
}

# ---- extraction -------------------------------------------------------------
extract_to() { # <pkg> <destdir>  -> echoes source dir path
  local p="$1" dest="$2" tb sd
  tb="$SRC/$(pkg_tarball "$p")"
  sd="$dest/$(pkg_srcdir "$p")"
  rm -rf "$sd"
  mkdir -p "$dest"
  tar -xf "$tb" -C "$dest"
  [ -d "$sd" ] || die "Extraction of $p did not produce $(pkg_srcdir "$p")"
  echo "$sd"
}

# ---- per-arch environment ---------------------------------------------------
root_for() { echo "$WORK/root-$1"; }

# The 'other' arch triple for autotools --host
host_triple() {
  case "$1" in
    arm64)  echo "aarch64-apple-darwin20" ;;
    x86_64) echo "x86_64-apple-darwin20" ;;
  esac
}

# Set up environment for building package for arch $1. Call inside subshell!
arch_env() {
  local A="$1" ROOT
  ROOT="$(root_for "$A")"
  mkdir -p "$ROOT/bin" "$ROOT/lib/pkgconfig" "$ROOT/include" "$ROOT/share"

  export CC="clang"
  export CXX="clang++"
  export OBJC="clang"
  export ARCHFLAG="-arch $A"
  export CFLAGS="$ARCHFLAG -mmacosx-version-min=$MACOS_MIN -O2 -I$ROOT/include"
  export CXXFLAGS="$CFLAGS"
  export OBJCFLAGS="$CFLAGS"
  export CPPFLAGS="-I$ROOT/include"
  # -rpath $ROOT/lib: meson gives libraries @rpath/ install names, so build-tree
  # tools need a way to find them while we build. relocate_tree.py strips all
  # absolute rpaths again when the bundle is assembled (verify.sh enforces it).
  export LDFLAGS="$ARCHFLAG -mmacosx-version-min=$MACOS_MIN -L$ROOT/lib -Wl,-headerpad_max_install_names -Wl,-rpath,$ROOT/lib"
  export MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN"

  # pkg-config: ONLY our roots; never /usr/local or anything else.
  export PKG_CONFIG="$TOOLS/bin/pkg-config"
  export PKG_CONFIG_LIBDIR="$ROOT/lib/pkgconfig:$ROOT/share/pkgconfig"
  unset PKG_CONFIG_PATH

  # PATH: this arch's root first (its tools run natively or under Rosetta),
  # then host tools, then a MINIMAL system path. No /usr/local/bin!
  export PATH="$ROOT/bin:$TOOLS/bin:/usr/bin:/bin:/usr/sbin:/sbin"

  # Perl helper modules (XML::Parser fallback build)
  if [ -d "$TOOLS/perl5/lib/perl5" ]; then
    export PERL5LIB="$TOOLS/perl5/lib/perl5"
  fi

  export ACLOCAL_PATH="$ROOT/share/aclocal"
  export XDG_DATA_DIRS="$ROOT/share"
}

# ---- meson machine files ----------------------------------------------------
# Always used as a --cross-file (even for the native arch: host==build is a
# legal 'cross' and gives us one uniform code path). needs_exe_wrapper=false
# when the target arch can execute here (native, or x86_64 under Rosetta).
write_meson_files() { # <arch>  -> file path in $BLD
  local A="$1" f="$BLD/meson-$1.ini" ROOT wrapper=false
  ROOT="$(root_for "$A")"
  if [ "$A" != "$NATIVE_ARCH" ]; then
    if [ "$NATIVE_ARCH" = "arm64" ] && [ "$A" = "x86_64" ]; then
      wrapper=false     # Rosetta 2 runs x86_64 binaries (checked in sanity_checks)
    else
      wrapper=true      # Intel host cannot execute arm64
    fi
  fi
  local LINKARGS="'-mmacosx-version-min=$MACOS_MIN', '-L$ROOT/lib', '-Wl,-headerpad_max_install_names', '-Wl,-rpath,$ROOT/lib'"
  cat > "$f" <<EOF
[binaries]
c = ['clang', '-arch', '$A']
cpp = ['clang++', '-arch', '$A']
objc = ['clang', '-arch', '$A']
objcpp = ['clang++', '-arch', '$A']
ar = '/usr/bin/ar'
strip = '/usr/bin/strip'
pkg-config = '$TOOLS/bin/pkg-config'

[built-in options]
c_args = ['-mmacosx-version-min=$MACOS_MIN', '-I$ROOT/include']
c_link_args = [$LINKARGS]
cpp_args = ['-mmacosx-version-min=$MACOS_MIN', '-I$ROOT/include']
cpp_link_args = [$LINKARGS]
objc_args = ['-mmacosx-version-min=$MACOS_MIN', '-I$ROOT/include']
objc_link_args = [$LINKARGS]

[host_machine]
system = 'darwin'
cpu_family = '$(echo "$A" | sed 's/arm64/aarch64/')'
cpu = '$(echo "$A" | sed 's/arm64/aarch64/')'
endian = 'little'

[properties]
needs_exe_wrapper = $wrapper
EOF
  echo "$f"
}

# ---- build helpers ----------------------------------------------------------
stamp()     { echo "$STAMPS/$2-$1"; }   # stamp <arch|host> <pkg>
is_built()  { [ -f "$(stamp "$1" "$2")" ]; }
mark_built(){ touch "$(stamp "$1" "$2")"; }

should_skip() { # <arch> <pkg>
  if [ -n "${ONLY:-}" ]; then
    [ "$ONLY" = "$2" ] && return 1 || return 0
  fi
  if [ -n "${RESUME_FROM:-}" ]; then
    if [ "$RESUME_FROM" = "$2" ]; then RESUME_FROM=""; return 1; fi
    return 0
  fi
  is_built "$1" "$2" && return 0
  return 1
}

NPROC="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

# autotools_build <arch> <srcdir> [configure args...]
# In cross mode, autoconf cannot execute run-tests (AC_RUN_IFELSE/AC_FUNC_MMAP)
# and guesses pessimistically - which makes the cross arch take DIFFERENT code
# paths than the native arch (e.g. libgsf falling back from mmap to buffered
# stdio, which corrupted zip reads). Seed the cache with the correct answers:
# both macOS architectures have identical POSIX behavior.
CROSS_SEEDS="ac_cv_func_mmap_fixed_mapped=yes"

autotools_build() {
  local A="$1" sd="$2" ROOT hostflags=""
  shift 2
  ROOT="$(root_for "$A")"
  if [ "$A" != "$NATIVE_ARCH" ]; then
    hostflags="--host=$(host_triple "$A") --build=$(host_triple "$NATIVE_ARCH") $CROSS_SEEDS"
  fi
  ( cd "$sd" && \
    ./configure --prefix="$ROOT" --disable-static --enable-shared \
                --disable-dependency-tracking $hostflags "$@" && \
    make -j"$NPROC" && make install )
}

# meson_build <arch> <srcdir> [meson options...]
meson_build() {
  local A="$1" sd="$2" ROOT mfile
  shift 2
  ROOT="$(root_for "$A")"
  mfile="$(write_meson_files "$A")"
  ( cd "$sd" && \
    "$TOOLS/bin/meson" setup _build --prefix="$ROOT" --libdir=lib \
        --buildtype=release --wrap-mode=nofallback \
        -Ddefault_library=shared --cross-file "$mfile" "$@" && \
    "$TOOLS/bin/meson" compile -C _build -j "$NPROC" && \
    "$TOOLS/bin/meson" install -C _build )
}

# meson option helper: include option only if the project declares it
meson_opt_if_exists() { # <srcdir> <optname> <optvalue>
  if grep -rqs "option('$2'" "$1/meson_options.txt" "$1/meson.options" 2>/dev/null; then
    echo "-D$2=$3"
  fi
}
