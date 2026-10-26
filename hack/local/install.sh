#!/usr/bin/env bash
# Installs the platform and its prerequisites on a kind cluster created from
# .ats/kind-config.yaml. `make local-up` and the app-test-suite tests run it.
#
#   install.sh <chart>   <chart> is the chart directory or a packaged .tgz
#
# KUBE_CONTEXT selects the kubeconfig context. Unset, the current context applies.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
CHART=$1
# observability-operator release installed before the chart. Keep in step with the
# version the platform is tested against.
OPERATOR_VERSION=0.86.0
KUBECTL=(kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"})
HELM=(helm ${KUBE_CONTEXT:+--kube-context "$KUBE_CONTEXT"})

"${HELM[@]}" upgrade --install eg oci://docker.io/envoyproxy/gateway-helm --version 1.9.1 \
  --namespace envoy-gateway-system --create-namespace --wait --timeout 10m

# The signer generates the JWT signing key and the Gateway certificate. See jwks.yaml.
"${KUBECTL[@]}" create namespace jwt-issuer --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
"${KUBECTL[@]}" create configmap local-scripts -n jwt-issuer \
  --from-file="$DIR/jwt.sh" --from-file="$DIR/tls.sh" \
  --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
"${KUBECTL[@]}" apply -f "$DIR/jwks.yaml"
"${KUBECTL[@]}" rollout status deployment/jwks -n jwt-issuer --timeout 5m

mkdir -p "$DIR/.keys"
"${KUBECTL[@]}" exec -n jwt-issuer deploy/jwks -c signer -- cat /keys/tls.crt > "$DIR/.keys/tls.crt"
KEY=$(mktemp)
trap 'rm -f "$KEY"' EXIT
"${KUBECTL[@]}" exec -n jwt-issuer deploy/jwks -c signer -- cat /keys/tls.key > "$KEY"
"${KUBECTL[@]}" create secret tls local-https-tls -n envoy-gateway-system \
  --cert="$DIR/.keys/tls.crt" --key="$KEY" \
  --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
"${KUBECTL[@]}" apply -k "$DIR/envoy-gateway/kind"

"${HELM[@]}" upgrade --install observability-operator observability-operator \
  --repo https://giantswarm.github.io/control-plane-catalog/ --version "$OPERATOR_VERSION" \
  --namespace monitoring --create-namespace \
  --values "$ROOT/values/observability-operator.yaml" --wait --timeout 5m
"${HELM[@]}" upgrade --install observability-platform "$CHART" \
  --namespace monitoring --create-namespace \
  --values "$ROOT/helm/observability-platform/values-local.yaml" \
  --values "$DIR/values.yaml"
