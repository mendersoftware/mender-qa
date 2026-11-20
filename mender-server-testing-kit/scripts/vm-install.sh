#!/bin/bash
# Runs inside the Vagrant VM: SeaweedFS + Mender from nt-iac through Flux,
# same steps as Documentation/how-to-test-server-locally-with-k8s.md.
. "$(dirname "$0")/common.sh"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
DOMAIN=mender.local
load_vm_env

ask_edition opensource
if ! kubectl get secret mender-ingress-tls >/dev/null 2>&1; then
  log "self-signed certificate for $DOMAIN"
  mkdir -p ~/mender-certs && cd ~/mender-certs
  openssl req -x509 -newkey rsa:2048 -nodes -days 365 -keyout mender.key -out server.crt \
    -subj "/C=US/ST=State/L=City/O=Mender/CN=$DOMAIN" -addext "subjectAltName=DNS:$DOMAIN" 2>/dev/null
  kubectl create secret tls mender-ingress-tls --cert=server.crt --key=mender.key
  cd - >/dev/null
fi

if ! kubectl get secret seaweedfs-mender-s3-secret >/dev/null 2>&1; then
  log "SeaweedFS and Mender S3 secrets"
  ADMIN_KEY=$(openssl rand -hex 16) ADMIN_SECRET=$(openssl rand -hex 32)
  READ_KEY=$(openssl rand -hex 16) READ_SECRET=$(openssl rand -hex 32)
  S3_CONFIG="{\"identities\":[{\"name\":\"anvAdmin\",\"credentials\":[{\"accessKey\":\"$ADMIN_KEY\",\"secretKey\":\"$ADMIN_SECRET\"}],\"actions\":[\"Admin\",\"Read\",\"Write\"]},{\"name\":\"anvReadOnly\",\"credentials\":[{\"accessKey\":\"$READ_KEY\",\"secretKey\":\"$READ_SECRET\"}],\"actions\":[\"Read\"]}]}"
  kubectl create secret generic seaweedfs-mender-s3-secret \
    --from-file=admin_access_key_id=<(printf %s "$ADMIN_KEY") \
    --from-file=admin_secret_access_key=<(printf %s "$ADMIN_SECRET") \
    --from-file=read_access_key_id=<(printf %s "$READ_KEY") \
    --from-file=read_secret_access_key=<(printf %s "$READ_SECRET") \
    --from-file=seaweedfs_s3_config=<(printf %s "$S3_CONFIG")
  kubectl create secret generic mender-s3-artifacts \
    --from-file=AWS_AUTH_KEY=<(printf %s "$ADMIN_KEY") \
    --from-file=AWS_AUTH_SECRET=<(printf %s "$ADMIN_SECRET") \
    --from-literal=AWS_BUCKET=mender-artifacts-storage-seaweedfs \
    --from-literal=AWS_FORCE_PATH_STYLE=true \
    --from-literal=AWS_URI=http://seaweedfs-s3:8333 \
    --from-literal=AWS_REGION=us-east-1
fi

if [ "$EDITION" = enterprise ]; then
  registry_secret my-mender-pull-secret registry.mender.io MENDER_REGISTRY PASSWORD
fi

log "flux install"
flux install

if ! kubectl -n flux-system get secret github-auth >/dev/null 2>&1; then
  ask_secret GITHUB_TOKEN "GitHub token with read access to NorthernTechHQ/nt-iac"
  kubectl -n flux-system create secret generic github-auth \
    --from-literal=username=git --from-file=password=<(printf %s "$GITHUB_TOKEN")
fi

log "nt-iac source and manifests/test-k3s-$EDITION"
flux create source git nt-iac --url=https://github.com/NorthernTechHQ/nt-iac \
  --branch="${NT_IAC_BRANCH:-main}" --interval=1m --secret-ref=github-auth
flux create kustomization manifests --source=GitRepository/nt-iac \
  --path="./manifests/test-k3s-$EDITION" --prune=true --interval=10m

log "done, pods start in about 10 minutes: make vm-status"
