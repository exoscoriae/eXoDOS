#!/usr/bin/env bash
# lib/preflight.sh -- verify the build host before a single byte is compiled.
# shellcheck shell=bash

preflight_host() {
  step "Preflight: host"

  [[ "$(uname -s)" == "Darwin" ]] || die "this build must run on macOS"
  HOST_ARCH="$(uname -m)"
  ok "host: macOS $(sw_vers -productVersion) on $HOST_ARCH"

  xcode-select -p >/dev/null 2>&1 \
    || die "Xcode Command Line Tools are not installed. Run: xcode-select --install"

  local c
  for c in clang lipo otool install_name_tool codesign vtool nm strip \
           curl tar make shasum sed awk python3 git; do
    require_cmd "$c"
  done
  ok "command line tools present"

  SDKROOT="${SDKROOT:-$(xcrun --show-sdk-path)}"
  [[ -d "$SDKROOT" ]] || die "cannot locate a macOS SDK (xcrun --show-sdk-path)"
  ok "SDK: $SDKROOT ($(xcrun --show-sdk-version))"
  export SDKROOT
}

# The single most important check: does the installed SDK still accept a
# macOS 11.0 deployment target?  Newer Xcode releases periodically raise the
# floor, and when they do every binary silently gets a higher LC_BUILD_VERSION.
preflight_deployment_target() {
  step "Preflight: macOS ${DEPLOYMENT_TARGET} deployment target"

  local tmp out minos
  tmp="$(mktemp -d)"
  cat > "$tmp/t.c" <<'EOF'
#include <stdio.h>
int main(void){ printf("ok\n"); return 0; }
EOF
  if ! out="$(clang -arch "$(uname -m)" -isysroot "$SDKROOT" \
        -mmacosx-version-min="$DEPLOYMENT_TARGET" \
        -o "$tmp/t" "$tmp/t.c" 2>&1)"; then
    rm -rf "$tmp"
    die "the installed SDK cannot target macOS ${DEPLOYMENT_TARGET}:
$out

Install an SDK that still supports it (for example from an older Xcode) and
re-run with SDKROOT=/path/to/MacOSX11.sdk"
  fi
  if grep -qi 'ignoring.*version.min\|not supported.*deployment' <<<"$out"; then
    rm -rf "$tmp"
    die "clang refused the deployment target:
$out"
  fi

  minos="$(/usr/bin/otool -l "$tmp/t" | awk '/minos/{print $2; exit}')"
  rm -rf "$tmp"
  [[ -n "$minos" ]] || die "could not read LC_BUILD_VERSION from a test binary"
  if [[ "$minos" != "${DEPLOYMENT_TARGET}"* && "$minos" != "11" ]]; then
    die "test binary reports minos=$minos, expected ${DEPLOYMENT_TARGET}.
Your toolchain is silently raising the floor; the resulting bundle would not
run on macOS ${DEPLOYMENT_TARGET}."
  fi
  ok "clang produces binaries with minos ${minos}"
}

# Building the x86_64 slices on Apple Silicon requires Rosetta 2, because
# autoconf and meson execute the test programs they compile.
preflight_rosetta() {
  [[ "$HOST_ARCH" == "arm64" ]] || return 0
  step "Preflight: Rosetta 2"

  local tmp
  tmp="$(mktemp -d)"
  printf 'int main(void){return 0;}\n' > "$tmp/t.c"
  clang -arch x86_64 -isysroot "$SDKROOT" -mmacosx-version-min="$DEPLOYMENT_TARGET" \
        -o "$tmp/t" "$tmp/t.c" 2>/dev/null || { rm -rf "$tmp"; die "cannot compile for x86_64"; }
  if ! "$tmp/t" >/dev/null 2>&1; then
    rm -rf "$tmp"
    die "Rosetta 2 is not installed, so x86_64 configure tests cannot run.
Install it with:  softwareupdate --install-rosetta --agree-to-license"
  fi
  rm -rf "$tmp"
  ok "Rosetta 2 available"
}

preflight_clean_environment() {
  step "Preflight: package manager isolation"
  local found=0 p
  for p in /opt/homebrew/bin/brew /usr/local/bin/brew /opt/local/bin/port; do
    [[ -x "$p" ]] && { warn "$p exists on this machine (it will be kept off PATH)"; found=1; }
  done
  [[ $found -eq 0 ]] && ok "no Homebrew or MacPorts installation detected"
  ok "PATH for this build: $PATH"
}

preflight_disk() {
  step "Preflight: disk space"
  local avail_kb avail_gb
  avail_kb="$(df -k "$BUILD_ROOT" | awk 'NR==2{print $4}')"
  avail_gb=$(( avail_kb / 1024 / 1024 ))
  (( avail_gb >= 35 )) || die "only ${avail_gb}GB free under $BUILD_ROOT; ~35GB is needed"
  ok "${avail_gb}GB available"
}

# HEAD-check every source URL up front.  A stale version pin is by far the most
# likely reason this script breaks months from now, and finding out in 30
# seconds beats finding out three hours in.
# A mirror whose key does not match any source's basename is never consulted --
# and nothing anywhere would say so.  It would sit in versions.sh looking like
# protection while the build still dies the moment the primary host blinks.
# Same for a mirror without a pin: fetch() refuses those at download time, but
# finding out then means finding out after the outage has already started.
preflight_mirror_table() {
  local line key found url u
  for line in ${SOURCE_MIRRORS[@]+"${SOURCE_MIRRORS[@]}"}; do
    # shellcheck disable=SC2086
    set -- $line
    key="$1"
    found=0
    for u in "${ALL_SOURCE_URLS[@]}"; do
      [[ "$(basename "$u")" == "$key" ]] && { found=1; break; }
    done
    (( found )) || die "SOURCE_MIRRORS has an entry for '$key', but no source URL
saves a file under that name, so the mirror could never be used.  The key must
equal the basename of the primary URL (see versions.sh)."
    known_sha_for "$key" >/dev/null \
      || die "SOURCE_MIRRORS has an entry for '$key' with no KNOWN_SHA256 pin.
A mirror is an untrusted host; the pin is the only thing that makes accepting
its bytes safe.  Add the sha256 -- from a source independent of the mirror --
or remove the mirror."
  done
}

preflight_urls() {
  step "Preflight: source URLs"
  local url bad=0 cached=0 code base
  preflight_mirror_table
  for url in "${ALL_SOURCE_URLS[@]}"; do
    base="$(basename "$url")"

    # Already downloaded?  Then an unreachable mirror is irrelevant -- fetch()
    # will use the cached copy and still verify its checksum.  Upstream hosts go
    # down for maintenance; that is no reason to stop a resumed build.
    if [[ -s "$DOWNLOADS/$base" ]]; then
      printf '  %s  %s\n' "${C_G}cached${C_RST}" "$base"
      cached=$((cached+1))
      continue
    fi

    # A one-byte ranged GET rather than HEAD: several release CDNs (GitHub's in
    # particular) answer HEAD with 403 while serving GET perfectly well.
    # On a connection failure curl prints 000 and exits non-zero, so assign
    # rather than append -- otherwise the two combine into a nonsense "000000".
    #
    # Sweep the mirrors too, or this reports a source as MISSING that fetch()
    # would have downloaded without complaint -- a preflight that is stricter
    # than the build it precedes is worse than none, because it stops a build
    # that would have worked.
    local u first=1 got="" gotcode=""
    for u in "$url" $(mirrors_for "$base" || true); do
      code="$(curl -sS -L -o /dev/null -w '%{http_code}' \
                --retry 2 --retry-delay 2 --connect-timeout 20 --max-time 60 \
                -r 0-0 "$u" 2>/dev/null)" || code="000"
      [[ "$first" == "1" ]] && gotcode="$code"
      first=0
      if [[ "$code" == "200" || "$code" == "206" ]]; then got="$u"; break; fi
    done

    if [[ "$got" == "$url" ]]; then
      printf '  %s  %s\n' "${C_G}ok${C_RST}" "$base"
    elif [[ -n "$got" ]]; then
      printf '  %s  %s  (primary HTTP %s; a mirror has it)\n    %s\n' \
             "${C_Y}mirror${C_RST}" "$base" "$gotcode" "$got"
    else
      printf '  %s  %s  (HTTP %s)\n    %s\n' "${C_R}MISSING${C_RST}" "$base" "$gotcode" "$url"
      bad=$((bad+1))
    fi
  done

  if (( bad > 0 )); then
    die "$bad source URL(s) unreachable.

If the host is simply down, wait and retry, or skip this sweep with
    ./${SCRIPT_NAME} --skip-url-check

If a version pin has gone stale, override it from the environment, e.g.
    FREETYPE_VERSION=2.13.2 ./${SCRIPT_NAME}
See versions.sh for every variable you can set.

If the host is gone for good, add a mirror to SOURCE_MIRRORS in versions.sh --
but pin its sha256 in KNOWN_SHA256 in the same commit, or you have swapped a
trusted publisher for an untrusted one."
  fi
  ok "all ${#ALL_SOURCE_URLS[@]} sources available (${cached} already downloaded)"
}

# The AArch64 code generator is fetched from a live branch of DOSBox-X unless a
# commit is pinned.  Say so plainly: it is the single most important input to
# this build and the one thing that is not reproducible by default.
preflight_backend_pin() {
  step "Preflight: AArch64 dynrec backend"
  if [[ -n "$ARMV8LE_LOCAL" && -f "$ARMV8LE_LOCAL" ]]; then
    if [[ -n "$ARMV8LE_SHA256" ]]; then
      ok "backend vendored and hash-pinned ($(basename "$ARMV8LE_LOCAL"))"
    else
      ok "backend vendored ($(basename "$ARMV8LE_LOCAL"))"
      warn "no ARMV8LE_SHA256 set -- the copy is used but not verified"
    fi
  elif [[ "$DOSBOXX_COMMIT" == "master" || -z "$DOSBOXX_COMMIT" ]]; then
    warn "risc_armv8le.h will be taken from ${DOSBOXX_REPO}@master (unpinned)."
    warn "Prefer vendoring it -- a content hash cannot be force-pushed:"
    warn "    cp build/downloads/risc_armv8le.h vendor/"
    warn "    shasum -a 256 vendor/risc_armv8le.h    # -> ARMV8LE_SHA256"
    warn "Or pin the commit: DOSBOXX_COMMIT=<40-char-sha> ./${SCRIPT_NAME}"
  else
    ok "backend pinned to ${DOSBOXX_REPO}@${DOSBOXX_COMMIT}"
  fi
}

run_preflight() {
  preflight_host
  preflight_deployment_target
  preflight_rosetta
  preflight_clean_environment
  preflight_disk
  preflight_backend_pin
  [[ "$SKIP_URL_CHECK" == "1" ]] || preflight_urls
}
