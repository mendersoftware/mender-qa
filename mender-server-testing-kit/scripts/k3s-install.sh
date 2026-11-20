#!/bin/bash
# Installs the Mender Server Helm chart on the local K3s with its built-in
# MongoDB, Redis and RustFS, and a self-signed CA. Testing only, not supported.
. "$(dirname "$0")/common.sh"
STATE=$KIT_DIR/.state

k3s_target confirm-remote
n=$(cat /proc/sys/fs/inotify/max_user_instances)
[ "$n" -ge 1024 ] || log "WARNING: fs.inotify.max_user_instances is $n, pods may fail with 'too many open files'"

# defaults: the settings of the last install in this namespace
mkdir -p "$STATE" && chmod 700 "$STATE"
last() { cat "$STATE/$NS-$1" 2>/dev/null || echo "${2:-}"; }
ask MENDER_SERVER_URL "Mender Server URL" "$(last url https://mender.local)"
ask_edition "$(last edition opensource)"
ask CHART "Helm chart: mender/mender or a local chart path" "$(last chart mender/mender)"

MENDER_SERVER_URL=${MENDER_SERVER_URL%/}
[[ $MENDER_SERVER_URL =~ ^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] \
  || die "MENDER_SERVER_URL must be https://<host name>, without port or path: $MENDER_SERVER_URL"
HOST=${MENDER_SERVER_URL#https://}

# an existing release keeps its edition and URL: the data and the TLS
# certificate belong to them
if helm -n "$NS" status mender >/dev/null 2>&1; then
  for f in url edition mongodb-root-password; do
    [ -s "$STATE/$NS-$f" ] || die "release mender exists in $NS but .state/$NS-$f is missing: make k3s-uninstall first"
  done
  [ "$(last edition)" = "$EDITION" ] || die "release mender in $NS is $(last edition): make k3s-uninstall first to change it"
  [ "$(last url)" = "$MENDER_SERVER_URL" ] || die "release mender in $NS uses $(last url): make k3s-uninstall first to change it"
fi

# the upstream chart is read from its URL, not from a helm repo named "mender"
# that may point elsewhere
REPO=()
if [ ! -d "$CHART" ]; then
  [ "$CHART" = mender/mender ] || die "CHART must be mender/mender or a local chart directory"
  REPO=(--repo https://charts.mender.io)
  CHART_REF=mender
else
  CHART_REF=$CHART
fi
helm_chart() { helm show "$1" "$CHART_REF" "${REPO[@]}" ${CHART_VERSION:+--version "$CHART_VERSION"}; }
values=$(helm_chart values) || die "cannot read the chart $CHART"
grep -q '^rustfs:' <<< "$values" || die "$CHART has no RustFS support, use a newer chart or a local mender-helm checkout"

# one image tag for all Mender services; the edition selects the registry.
# Default: the tag last used for this edition, else the chart appVersion.
TAG_FILE=$STATE/$NS-$EDITION-image-tag
APP_VERSION=$(helm_chart chart | sed -n 's/^appVersion: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p')
if [ "$EDITION" = enterprise ]; then IMAGES=registry.mender.io/mender-server-enterprise; else IMAGES=docker.io/mendersoftware; fi
ask IMAGE_TAG "Mender Server image tag ($IMAGES/*)" "$(cat "$TAG_FILE" 2>/dev/null || echo "$APP_VERSION")"
[[ $IMAGE_TAG =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || die "invalid image tag: $IMAGE_TAG"

printf '%s\n' "$MENDER_SERVER_URL" > "$STATE/$NS-url"
printf '%s\n' "$EDITION" > "$STATE/$NS-edition"
printf '%s\n' "$CHART" > "$STATE/$NS-chart"

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
if [ "$EDITION" = enterprise ]; then
  registry_secret my-mender-pull-secret registry.mender.io MENDER_REGISTRY PASSWORD "$NS"
fi

# MongoDB keeps the root password it first started with: reuse it on upgrades
MONGO_PW_FILE=$STATE/$NS-mongodb-root-password
[ -s "$MONGO_PW_FILE" ] || (umask 077; openssl rand -hex 24 > "$MONGO_PW_FILE")
VALUES=$STATE/$NS-values.yaml
(umask 077; cat > "$VALUES" <<EOV
global:
  enterprise: $([ "$EDITION" = enterprise ] && echo true || echo false)
  url: "$MENDER_SERVER_URL"
default:
  image:
    tag: "$IMAGE_TAG"
    pullPolicy: Always
$([ "$EDITION" = enterprise ] && printf '  imagePullSecrets:\n    - name: my-mender-pull-secret\n')
ingress:
  enabled: true
  ingressClassName: traefik
  path: /
  hosts:
    - $HOST
  tls:
    - secretName: mender-ingress-tls
      hosts:
        - $HOST
  selfSignedTLS:
    enabled: true
rustfs:
  enabled: true
mongodb:
  auth:
    rootPassword: "$(cat "$MONGO_PW_FILE")"
  persistence:
    enabled: true
redis:
  enabled: true
EOV
)

log "helm upgrade --install mender $CHART (namespace $NS, $EDITION, images $IMAGES/*:$IMAGE_TAG)"
helm upgrade --install mender "$CHART_REF" "${REPO[@]}" ${CHART_VERSION:+--version "$CHART_VERSION"} \
  -n "$NS" -f "$VALUES" ${EXTRA_VALUES:+-f "$EXTRA_VALUES"} --wait --timeout "${HELM_TIMEOUT:-15m}"
echo "$IMAGE_TAG" > "$TAG_FILE"

kubectl -n "$NS" get secret mender-ingress-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > "$STATE/ca.crt"
openssl x509 -noout -in "$STATE/ca.crt" 2>/dev/null || die "no CA in $NS/mender-ingress-tls"
log "done"
cat <<EON
  CA certificate: $STATE/ca.crt (import it in the browser, copy it to devices as ServerCertificate)
  First user:     make k3s-user
  URL:            $MENDER_SERVER_URL (make sure $HOST resolves to this host)
  Images:         $IMAGES/*:$IMAGE_TAG
  kubectl/helm:   export KUBECONFIG=$KUBECONFIG; kubectl -n $NS get pods
EON
