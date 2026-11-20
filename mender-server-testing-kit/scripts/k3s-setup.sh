#!/bin/bash
# Installs K3s and Helm on this host and raises the inotify limit. Needs sudo.
. "$(dirname "$0")/common.sh"
# installers from release tags; they verify the downloaded binaries' sha256
K3S_VERSION=${K3S_VERSION:-v1.37.2+k3s1}
HELM_VERSION=${HELM_VERSION:-v3.22.1}

if [ "$(cat /proc/sys/fs/inotify/max_user_instances)" -lt 1024 ]; then
  log "fs.inotify.max_user_instances = 1024"
  echo "fs.inotify.max_user_instances = 1024" | sudo tee /etc/sysctl.d/90-mender-inotify.conf >/dev/null
  sudo sysctl -q -p /etc/sysctl.d/90-mender-inotify.conf
fi

if ! command -v k3s >/dev/null; then
  log "installing K3s $K3S_VERSION"
  curl -fsSL "https://raw.githubusercontent.com/k3s-io/k3s/${K3S_VERSION/+/%2B}/install.sh" \
    | env -u K3S_URL -u K3S_TOKEN -u K3S_TOKEN_FILE INSTALL_K3S_VERSION="$K3S_VERSION" sh -
fi

systemctl is-active -q k3s || { log "starting K3s"; sudo systemctl start k3s; }

# a dedicated file: ~/.kube/config may hold other clusters and is never touched
KCFG=~/.kube/k3s.yaml
mkdir -p ~/.kube
for _ in $(seq 60); do sudo test -s /etc/rancher/k3s/k3s.yaml && break; sleep 1; done
sudo install -m 600 -o "$(id -u)" -g "$(id -g)" /etc/rancher/k3s/k3s.yaml "$KCFG"

if ! command -v helm >/dev/null; then
  log "installing Helm $HELM_VERSION"
  curl -fsSL "https://raw.githubusercontent.com/helm/helm/$HELM_VERSION/scripts/get-helm-3" \
    | DESIRED_VERSION=$HELM_VERSION bash
fi

log "kubeconfig written to $KCFG (used by all k3s-* targets)"
echo "  For kubectl and helm in your shell: export KUBECONFIG=$KCFG"
