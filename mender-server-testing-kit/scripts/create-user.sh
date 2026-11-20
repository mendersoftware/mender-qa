#!/bin/bash
# Creates the first user (Open Source) or organization and admin (Enterprise).
# KIT_VM=1: inside the Vagrant VM, default namespace. Else the local K3s target.
. "$(dirname "$0")/common.sh"
if [ "${KIT_VM:-}" = 1 ]; then
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  load_vm_env
  NS=default
  def_edition=opensource
else
  k3s_target confirm-remote
  def_edition=$(cat "$KIT_DIR/.state/$NS-edition" 2>/dev/null || echo opensource)
fi
ask_edition "$def_edition"
ask USER_EMAIL "Admin email" admin@example.com
component=useradm
if [ "$EDITION" = enterprise ]; then
  component=tenantadm
  ask ORG_NAME "Organization name" Acme
fi
pod=$(kubectl -n "$NS" get pod -l app.kubernetes.io/component=$component -o name | head -1)
[ -n "$pod" ] || die "no $component pod in namespace $NS: check make k3s-status"

[ "$EDITION" = enterprise ] && log "creating organization $ORG_NAME, its tenant ID is printed at the end"
# The CLIs read the password only from a terminal: without USER_PASSWORD
# they prompt themselves through "exec -it" and it never reaches a command line
if [ -n "${USER_PASSWORD:-}" ]; then
  log "WARNING: USER_PASSWORD from the environment is passed with --password, visible in ps"
  exec_opts=() pw=(--password "$USER_PASSWORD")
else
  [ -t 0 ] || die "USER_PASSWORD is required without a terminal"
  log "admin password, 8+ characters:"
  exec_opts=(-it) pw=()
fi
if [ "$EDITION" = enterprise ]; then
  kubectl -n "$NS" exec "${exec_opts[@]}" "$pod" -- tenantadm create-org --name "$ORG_NAME" \
    --username "$USER_EMAIL" "${pw[@]}" --addon troubleshoot --addon monitor --addon configure --plan enterprise
else
  kubectl -n "$NS" exec "${exec_opts[@]}" "$pod" -- useradm create-user --username "$USER_EMAIL" "${pw[@]}"
fi
