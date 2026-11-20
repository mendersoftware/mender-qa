#!/bin/bash
# Runs inside the Vagrant VM: removes Mender, SeaweedFS, Flux and everything vm-install created.
. "$(dirname "$0")/common.sh"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

if kubectl -n flux-system get kustomizations.kustomize.toolkit.fluxcd.io manifests >/dev/null 2>&1; then
  log "deleting the Flux kustomization (prunes the mender and seaweedfs HelmReleases)"
  flux delete kustomization manifests --silent
  kubectl wait --for=delete helmrelease --all --timeout=10m 2>/dev/null || true
fi
flux delete source git nt-iac --silent 2>/dev/null || true

log "removing leftovers: built-in MongoDB (Helm hook), PVCs, secrets, override values"
kubectl delete deployment,service,secret,configmap,pvc -l app.kubernetes.io/instance=mender --ignore-not-found
kubectl delete all,configmap,secret,pvc -l app.kubernetes.io/instance=seaweedfs --ignore-not-found
kubectl delete secret mender-ingress-tls seaweedfs-mender-s3-secret mender-s3-artifacts \
  my-mender-pull-secret my-gitlab-registry-secret --ignore-not-found
kubectl delete configmap mender-override-values --ignore-not-found
kubectl -n flux-system delete secret github-auth --ignore-not-found
rm -f ~/mender-certs/mender.key ~/mender-certs/server.crt

log "flux uninstall"
flux uninstall --silent
kubectl get deployment,statefulset,service,pvc,secret
