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
preflight_urls() {
  step "Preflight: source URLs"
  local url bad=0 cached=0 code base
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
    code="$(curl -sS -L -o /dev/null -w '%{http_code}' \
              --retry 2 --retry-delay 2 --connect-timeout 20 --max-time 60 \
              -r 0-0 "$url" 2>/dev/null)" || code="000"

    if [[ "$code" == "200" || "$code" == "206" ]]; then
      printf '  %s  %s\n' "${C_G}ok${C_RST}" "$base"
    else
      printf '  %s  %s  (HTTP %s)\n    %s\n' "${C_R}MISSING${C_RST}" "$base" "$code" "$url"
      bad=$((bad+1))
    fi
  done

  if (( bad > 0 )); then
    die "$bad source URL(s) unreachable.

If the host is simply down, wait and retry, or skip this sweep with
    ./build-wine.sh --skip-url-check

If a version pin has gone stale, override it from the environment, e.g.
    FREETYPE_VERSION=2.13.2 ./build-wine.sh
See versions.sh for every variable you can set."
  fi
  ok "all ${#ALL_SOURCE_URLS[@]} sources available (${cached} already downloaded)"
}

preflight_xcodebuild() {
  step "Preflight: MoltenVK build strategy"

  # An explicit MOLTENVK_FROM_SOURCE=0 in the environment wins, so a failed
  # source build can be worked around without editing anything.
  if [[ "${MOLTENVK_FROM_SOURCE:-}" == "0" ]]; then
    ok "MOLTENVK_FROM_SOURCE=0 -- using the official MoltenVK ${MOLTENVK_VERSION} release binary"
    export MOLTENVK_FROM_SOURCE=0
    return 0
  fi

  local xcout rc=0
  xcout="$(xcodebuild -version 2>&1)" || rc=$?

  if [[ $rc -eq 0 ]]; then
    MOLTENVK_FROM_SOURCE=1
    ok "$(head -1 <<<"$xcout") active -- MoltenVK ${MOLTENVK_VERSION} will be built from source"
    export MOLTENVK_FROM_SOURCE
    return 0
  fi

  MOLTENVK_FROM_SOURCE=0

  # The overwhelmingly common case: Xcode is installed, but the active
  # developer directory still points at the Command Line Tools, so xcodebuild
  # is a stub.  Say so precisely rather than claiming Xcode is absent.
  local xc="" cand
  for cand in /Applications/Xcode.app /Applications/Xcode-beta.app "$HOME/Applications/Xcode.app"; do
    [[ -d "$cand" ]] && { xc="$cand"; break; }
  done

  if [[ -n "$xc" ]]; then
    warn "$xc exists, but the active developer directory is $(xcode-select -p)."
    if grep -qi 'license' <<<"$xcout"; then
      warn "Xcode's licence has not been accepted yet."
      warn "Run:  sudo xcodebuild -license accept"
    else
      warn "Point the toolchain at Xcode and re-run this script:"
      warn "    sudo xcode-select -s $xc/Contents/Developer"
      warn "    sudo xcodebuild -runFirstLaunch"
    fi
    warn "Continuing for now with the official MoltenVK ${MOLTENVK_VERSION} release binary."
  else
    warn "full Xcode not found (only Command Line Tools)."
    warn "Falling back to the official MoltenVK ${MOLTENVK_VERSION} release binary."
  fi
  warn "Either way the result is audited for minos ${DEPLOYMENT_TARGET} by verify-bundle.sh."
  [[ -n "$xcout" ]] && info_xcodebuild_error "$xcout"
  export MOLTENVK_FROM_SOURCE
}

info_xcodebuild_error() {
  printf '        xcodebuild said: %s\n' "$(head -2 <<<"$1" | tr '\n' ' ')" >&2
}

run_preflight() {
  preflight_host
  preflight_deployment_target
  preflight_rosetta
  preflight_clean_environment
  preflight_disk
  preflight_xcodebuild
  [[ "$SKIP_URL_CHECK" == "1" ]] || preflight_urls
}
