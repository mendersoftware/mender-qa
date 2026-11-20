# shellcheck shell=bash
set -euo pipefail
# an exported CDPATH makes cd print paths and breaks $(cd ...) substitutions
unset CDPATH
KIT_DIR=$(readlink -f "$(dirname "${BASH_SOURCE[0]}")/..")
export KIT_DIR

log() { printf '\033[1m> %s\033[0m\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ask VAR "Prompt" [default]: keeps VAR if already set in the environment.
# Without input (EOF) the default is used.
ask() {
  local var=$1 prompt=$2 def=${3:-} val=
  [ -n "${!var:-}" ] && return
  read -r -p "$prompt${def:+ [$def]}: " val || true
  printf -v "$var" '%s' "${val:-$def}"
  [ -n "${!var}" ] || die "$var is required"
}

ask_secret() {
  local var=$1 prompt=$2 val=
  [ -n "${!var:-}" ] && return
  read -r -s -p "$prompt: " val || true; echo
  printf -v "$var" '%s' "$val"
  [ -n "${!var}" ] || die "$var is required"
}

# Local K3s targets use a fixed kubeconfig and namespace, never the shell's
# KUBECONFIG, current context or HELM_* overrides.
# k3s_target confirm-remote|confirm-always. Sets NS.
k3s_target() {
  NS=${KIT_NAMESPACE:-mender}
  [[ $NS =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || die "invalid KIT_NAMESPACE: $NS"
  case $NS in default|kube-*) die "refusing to use namespace $NS" ;; esac
  unset HELM_KUBEAPISERVER HELM_KUBETOKEN HELM_KUBECONTEXT HELM_KUBEASUSER HELM_KUBEASGROUPS \
    HELM_KUBECAFILE HELM_KUBEINSECURE_SKIP_TLS_VERIFY HELM_KUBETLS_SERVER_NAME HELM_NAMESPACE
  export KUBECONFIG=${KIT_KUBECONFIG:-$HOME/.kube/k3s.yaml}
  [ -r "$KUBECONFIG" ] || die "$KUBECONFIG not found: run make k3s-setup, or set KIT_KUBECONFIG"
  if ! kubectl get --raw /readyz >/dev/null 2>&1; then
    command -v k3s >/dev/null && ! systemctl is-active -q k3s \
      && die "K3s is not running: sudo systemctl start k3s"
    die "the cluster in $KUBECONFIG is not reachable"
  fi
  local server a
  server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
  log "target: $server, namespace $NS ($KUBECONFIG)"
  case $server in https://127.0.0.1:*|https://localhost:*) [ "$1" = confirm-always ] || return 0 ;; esac
  read -r -p "Continue on $server, namespace $NS? [y/N] " a || die "no answer, aborted"
  [ "$a" = y ] || die "aborted"
}

ask_edition() { # [default]
  ask EDITION "Installation type (opensource/enterprise)" "${1:-opensource}"
  case $EDITION in opensource|enterprise) ;; *) die "unknown installation type: $EDITION" ;; esac
}

# registry_secret NAME SERVER PREFIX PASSWORD_SUFFIX [NAMESPACE]
# Docker registry secret from ${PREFIX}_USERNAME, ${PREFIX}_${PASSWORD_SUFFIX}
# and ${PREFIX}_EMAIL; asks for the unset ones. With none set, an existing
# secret is kept. The password never reaches argv.
registry_secret() {
  local name=$1 server=$2 u=${3}_USERNAME p=${3}_${4} e=${3}_EMAIL ns=${5:-} auth
  if [ -z "${!u:-}${!p:-}${!e:-}" ] && kubectl ${ns:+-n "$ns"} get secret "$name" >/dev/null 2>&1; then
    log "reusing secret $name (set $u, $p and $e to replace it)"
    return
  fi
  ask "$u" "$server username"
  ask_secret "$p" "$server password"
  ask "$e" "$server email"
  [[ ${!u}${!e} != *[\"\\]* ]] || die "$u and $e must not contain quotes or backslashes"
  auth=$(printf '%s:%s' "${!u}" "${!p}" | base64 -w0)
  kubectl ${ns:+-n "$ns"} create secret docker-registry "$name" --dry-run=client -o yaml \
    --from-file=.dockerconfigjson=<(printf '{"auths":{"%s":{"auth":"%s","email":"%s"}}}' "$server" "$auth" "${!e}") \
    | kubectl apply -f - >/dev/null
  log "secret $name for $server written from $u, $p and $e"
}

# Vagrant VM scripts: variables forwarded from the host by "make vm-*"
load_vm_env() {
  local f=$KIT_DIR/.vm-env
  # shellcheck source=/dev/null
  if [ -f "$f" ]; then . "$f"; rm -f "$f"; fi
}
