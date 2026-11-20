#!/bin/bash
# Removes the release, its namespace (MongoDB and RustFS volumes) and its .state files.
. "$(dirname "$0")/common.sh"
STATE=$KIT_DIR/.state

k3s_target confirm-always
if kubectl get namespace "$NS" >/dev/null 2>&1; then
  helm -n "$NS" status mender >/dev/null 2>&1 \
    || die "namespace $NS has no mender release, not deleting it (set KIT_NAMESPACE?)"
  helm -n "$NS" uninstall mender --wait
  kubectl delete namespace "$NS" --timeout=5m
fi
rm -f "$STATE/$NS-values.yaml" "$STATE/$NS-mongodb-root-password" "$STATE/ca.crt" \
  "$STATE/$NS-opensource-image-tag" "$STATE/$NS-enterprise-image-tag" \
  "$STATE/$NS-edition" "$STATE/$NS-url" "$STATE/$NS-chart"
