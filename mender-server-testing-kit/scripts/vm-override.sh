#!/bin/bash
# Runs inside the Vagrant VM. vm-override.sh VERSION [pr]
# Pins the Mender Server image tag; with "pr", pulls the build from the GitLab registry.
. "$(dirname "$0")/common.sh"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
VERSION=${1:?usage: vm-override.sh VERSION [pr]}
[[ $VERSION =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || die "invalid image tag: $VERSION"
load_vm_env
if [ "${2:-}" = pr ]; then
  registry_secret my-gitlab-registry-secret registry.gitlab.com GITLAB_REGISTRY TOKEN
  values="default:
  image:
    registry: registry.gitlab.com
    repository: northern.tech/mender/mender-server-enterprise
    tag: \"$VERSION\"
  imagePullSecrets:
    - name: my-gitlab-registry-secret"
else
  values="default:
  image:
    tag: \"$VERSION\""
fi
kubectl create configmap mender-override-values --dry-run=client -o yaml \
  --from-literal=mender-override-values.yaml="$values" | kubectl apply -f -
