#!/usr/bin/env bash
#
# 01-bootstrap-craft.sh — clone Craft and bootstrap one CraftRoot per architecture.
#
# Produces two independent prefixes:
#   $CRAFT_ROOT_ARM64   (ABI macos-clang-arm64)
#   $CRAFT_ROOT_X86_64  (ABI macos-clang-x86_64, cross-built on Apple Silicon)
#
# After bootstrap it force-patches each CraftSettings.ini so the ABI, job count,
# build type, and macOS deployment target are exactly what we want — the patch is
# the source of truth, not the interactive prompts.
# ---------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"

command -v git    >/dev/null || die "git not found. Install the Xcode command-line tools: xcode-select --install"
command -v python3 >/dev/null || die "python3 not found (ships with the Xcode command-line tools)."

mkdir -p "$CRAFT_BASE"

# --- 1. Get a clean copy of Craft itself --------------------------------------
CRAFT_SRC="$CRAFT_BASE/craft-src"
if [[ ! -d "$CRAFT_SRC/.git" ]]; then
  log "Cloning Craft from $CRAFT_GIT_URL ($CRAFT_GIT_REF)"
  git clone "$CRAFT_GIT_URL" "$CRAFT_SRC"
fi
git -C "$CRAFT_SRC" fetch --all --quiet
git -C "$CRAFT_SRC" checkout --quiet "$CRAFT_GIT_REF"

# --- 2. Patch a single CraftSettings.ini --------------------------------------
# Usage: patch_settings <ini-path> <abi>
patch_settings() {
  local ini="$1" abi="$2"
  python3 - "$ini" "$abi" "$CRAFT_BUILD_TYPE" "$CRAFT_JOBS" "$MACOSX_DEPLOYMENT_TARGET" <<'PY'
import configparser, sys
ini, abi, buildtype, jobs, deploy = sys.argv[1:6]
cp = configparser.ConfigParser()
cp.optionxform = str            # preserve key case
cp.read(ini)

def setk(section, key, val):
    if not cp.has_section(section):
        cp.add_section(section)
    cp.set(section, key, val)

setk("General", "ABI", abi)
setk("General", "AllowUnsupportedPlatforms", "True")
# THE global deployment target. Craft reads [General] MacDeploymentTarget (default
# "13") and exports it as MACOSX_DEPLOYMENT_TARGET for EVERY sub-build, overwriting
# any value we export ourselves (CraftSetupHelper.py:367). It MUST live in [General]
# (an earlier version wrongly put it under [Compile], so Craft used the 13 default
# and most libraries compiled for macOS 13). Setting it here makes the whole tree —
# including transitive libs not in our -D lists — build for macOS 11.
setk("General", "MacDeploymentTarget", deploy)
setk("Compile", "BuildType", buildtype)
setk("Compile", "Jobs", str(jobs))
setk("Compile", "UseCcache", "True")

with open(ini, "w") as fh:
    cp.write(fh)
print(f"patched {ini}: ABI={abi} deploy={deploy} jobs={jobs}")
PY
}

# --- 3. Bootstrap one CraftRoot ----------------------------------------------
# CraftBootstrap's first prompt is the target architecture, chosen BY INDEX:
#   [0] x86_64, [1] arm64
arch_index_for() {
  case "$1" in
    x86_64) echo "0" ;;
    arm64)  echo "1" ;;
    *) die "Unknown arch: $1" ;;
  esac
}

# Usage: bootstrap_root <root-path> <arch>
bootstrap_root() {
  local root="$1" arch="$2" abi idx
  abi="$(craft_abi_for "$arch")"
  idx="$(arch_index_for "$arch")"

  if [[ -f "$root/etc/CraftSettings.ini" ]]; then
    log "CraftRoot for $arch already bootstrapped at $root — re-patching settings only."
    patch_settings "$root/etc/CraftSettings.ini" "$abi"
    return
  fi

  # A previous failed attempt may have left a partial (un-bootstrapped) root.
  # It has no settings file, so nothing valuable is lost — clear it for a clean retry.
  if [[ -d "$root" ]]; then
    warn "Removing partial/un-bootstrapped root at $root before retrying."
    rm -rf "$root"
  fi

  log "Bootstrapping CraftRoot for $arch at $root"
  mkdir -p "$root"
  # CraftBootstrap is interactive and expects each answer as a numeric INDEX.
  # We send the architecture index first, then a stream of blank lines so every
  # remaining prompt takes its default (an empty line == default). This is robust
  # to the exact number/order of later prompts. patch_settings is authoritative
  # for the ABI afterward regardless.
  { printf '%s\n' "$idx"; for _ in $(seq 1 60); do printf '\n'; done; } | \
    python3 "$CRAFT_SRC/setup/CraftBootstrap.py" \
      --prefix "$root" \
      --branch "$CRAFT_GIT_REF" \
      --verbose || warn "CraftBootstrap returned non-zero; verifying settings file anyway."

  [[ -f "$root/etc/CraftSettings.ini" ]] || die "Bootstrap did not produce $root/etc/CraftSettings.ini. Run CraftBootstrap.py manually for $arch (python3 $CRAFT_SRC/setup/CraftBootstrap.py --prefix \"$root\"), then re-run this script."
  patch_settings "$root/etc/CraftSettings.ini" "$abi"
}

for arch in "${ARCHES[@]}"; do
  bootstrap_root "$(craft_root_for "$arch")" "$arch"
done

log "Bootstrap complete."
log "  arm64  root: $CRAFT_ROOT_ARM64"
log "  x86_64 root: $CRAFT_ROOT_X86_64"
log "Next: ./02-pin-versions.sh"
