#!/bin/bash
# Uninstalls K3s from this host with all its data, after showing what is lost.
. "$(dirname "$0")/common.sh"

[ -x /usr/local/bin/k3s-uninstall.sh ] || { echo "K3s is not installed on this host"; exit 0; }

# read from K3s itself: KIT_KUBECONFIG may point to another cluster
if all=$(sudo k3s kubectl get namespaces --no-headers -o custom-columns=:metadata.name 2>/dev/null); then
  echo "Namespaces on this host's K3s (all of them are deleted, with their volumes):"
  ns=$(grep -vE '^(default|kube-node-lease|kube-public|kube-system)$' <<< "$all" || true)
  while read -r n; do echo "  $n"; done <<< "${ns:-(none besides the K3s system ones)}"
else
  echo "WARNING: cannot list the namespaces (K3s not running?). All workloads and volumes"
  echo "under /var/lib/rancher/k3s are deleted, including any you cannot see here."
fi
echo "Also deleted: cached images, /var/lib/rancher/k3s, /etc/rancher/k3s, the K3s binary and service,"
echo "the cni0/flannel interfaces, iptables rules named KUBE-*, CNI-*, *flannel*, and .state/."
read -r -p "Type 'remove' to uninstall K3s: " a || die "no answer, aborted"
[ "$a" = remove ] || die "aborted"

/usr/local/bin/k3s-uninstall.sh
cd "$KIT_DIR/.state" 2>/dev/null || exit 0
rm -f -- *-values.yaml *-mongodb-root-password *-image-tag *-edition *-url *-chart ca.crt server.crt
