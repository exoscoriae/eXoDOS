# shellcheck shell=bash
# Build configuration for the portable GNU Wget2 macOS bundle.
# Every value can be overridden from the environment, e.g.
#   JOBS=4 ENABLE_PQC=0 ./build.sh

# --- inputs -----------------------------------------------------------------
# macOS 11 SDK used for compiling AND linking: anything that is not in it
# cannot end up in the binaries.  Xcode 12.5.1 ships MacOSX11.3.sdk.
: "${MACOS_SDK:=$HOME/SDKs/MacOSX11.3.sdk}"
: "${MACOS_MIN:=11.0}"
: "${ARCHS:=arm64 x86_64}"

# --- locations --------------------------------------------------------------
# Large scratch tree (downloads, sources, per-arch prefixes, logs; ~3 GB).
# Must not contain spaces (autotools).
: "${WORK_DIR:=$HOME/wget2-macos-build}"
# Where wget.app (and wget2-<version>-macos.zip) end up.
: "${DIST_DIR:=$PROJECT_DIR/dist}"

# --- features ---------------------------------------------------------------
# GnuPG inside the bundle, so --verify-sig works on a stock macOS.
: "${ENABLE_GNUPG:=1}"
# DANE certificate checking (--dane): libunbound + libgnutls-dane.
: "${ENABLE_DANE:=1}"
# Post-quantum algorithms in GnuTLS (ML-KEM/ML-DSA via leancrypto; needs
# meson+ninja, which the build installs into a private Python venv).
: "${ENABLE_PQC:=1}"

# --- bundle -----------------------------------------------------------------
: "${BUNDLE_ID:=org.gnu.wget2}"
: "${SIGN_IDENTITY:=-}"          # "-" = ad-hoc signature
: "${MAKE_ZIP:=1}"

# --- misc ---------------------------------------------------------------------
: "${JOBS:=$(/usr/sbin/sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

WGET2_VERSION=2.3.0

# meson/ninja (only for leancrypto) from PyPI, pinned by hash.
# meson 1.11.x is the last series that runs on the CLT's Python 3.9.
MESON_WHEEL="meson==1.11.2 --hash=sha256:7e4f6e83fec83e3eaac928e058b073c7557b282c35b6a2024cea143a39926a39"
NINJA_WHEEL="ninja==1.13.2 --hash=sha256:fd82e26c0706ad4ab88e5fdd26f3fab0a987a90f810160f6c322e752c6af298b"

# Data that is fetched fresh on every build (no pinned checksum on purpose).
CACERT_URL="https://curl.se/ca/cacert.pem"
PSL_URLS="https://publicsuffix.org/list/public_suffix_list.dat https://raw.githubusercontent.com/publicsuffix/list/main/public_suffix_list.dat"
HSTS_JSON_URL="https://raw.githubusercontent.com/chromium/chromium/main/net/http/transport_security_state_static.json"
IANA_ANCHORS_URL="https://data.iana.org/root-anchors/root-anchors.xml"
