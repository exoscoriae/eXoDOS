#!/usr/bin/env bash
#
# 02f-clear-deploy-args.sh — clear any per-package `args` override on KF / phonon /
# Okular / backend blueprints.
#
# The deployment target is now enforced globally by [General] MacDeploymentTarget
# (01-bootstrap), so per-package -DCMAKE_OSX_DEPLOYMENT_TARGET is unnecessary AND
# harmful: it gets appended to autotools ./configure for ghostscript/djvu, which
# reject -D options ("unrecognized option"). $CMAKE_DEPLOY_ARG is empty, so this
# sets args="" and removes any stale -D an earlier version wrote. The audit (05)
# is the final backstop for the deployment target.
# ---------------------------------------------------------------------------
source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"
THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

run_craft() {
  local root="$1"; shift
  ( set +u; scrub_brew_env; source "$root/craft/craftenv.sh"; craft "$@" )
}

set_deploy() {
  local root="$1" blueprint="$2"
  if run_craft "$root" --set "args=$CMAKE_DEPLOY_ARG" "$blueprint" >/dev/null 2>&1; then
    printf '   cleared args -> %-45s\n' "$blueprint"
  else
    warn "could not clear args on $blueprint — skipped"
  fi
}

set_deploy_list() {
  local root="$1" file="$2"
  while IFS= read -r line; do
    line="${line%%#*}"; line="$(echo "$line" | xargs)"
    [[ -z "$line" ]] && continue
    set_deploy "$root" "$line"
  done < "$file"
}

for arch in "${ARCHES[@]}"; do
  root="$(craft_root_for "$arch")"
  [[ -f "$root/etc/CraftSettings.ini" ]] || die "Root for $arch not bootstrapped."
  log "[$arch] Clearing per-package deploy args (global [General] handles the target)"
  set_deploy_list "$root" "$THIS_DIR/kf6-frameworks.txt"
  set_deploy_list "$root" "$THIS_DIR/backends.txt"
  set_deploy "$root" "qt-libs/phonon"
  set_deploy "$root" "$OKULAR_BLUEPRINT"
done

log "Deployment target forced. (Qt modules get it via 02c.)"
