#!/usr/bin/env bash
# Installs the platform and its prerequisites on a kind cluster created from
# .ats/kind-config.yaml, then writes tests/ats/target.env. `make local-up` and the
# app-test-suite pre-hook run it.
#
#   install.sh [<chart>]   <chart> is the chart directory or a packaged .tgz.
#                          Unset, ATS_CHART_PATH applies: app-test-suite sets it.
#
# KUBE_CONTEXT selects the kubeconfig context. Unset, the current context applies.
# LOCAL_BACKEND selects the object storage backend: `s3` (default) runs Garage, `azure`
# runs Azurite.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
CHART=${1:-${ATS_CHART_PATH:?pass the chart as an argument or set ATS_CHART_PATH}}
# observability-operator release installed before the chart. Keep in step with the
# version the platform is tested against.
OPERATOR_VERSION=0.88.0
# CNPG operator release for the Grafana PostgreSQL cluster. Keep in step with the
# tested range in docs/GRAFANA_DATABASE.md.
CNPG_VERSION=0.1.0
KUBECTL=(kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"})
HELM=(helm ${KUBE_CONTEXT:+--kube-context "$KUBE_CONTEXT"})
CONTEXT=${KUBE_CONTEXT:-$("${KUBECTL[@]}" config current-context)}

# --force-conflicts: app-test-suite applies its own Gateway API and Prometheus
# Operator CRDs first. The CRDs of the Envoy Gateway chart and of this chart take
# over their fields.
"${HELM[@]}" upgrade --install eg oci://docker.io/envoyproxy/gateway-helm --version 1.9.1 \
  --namespace envoy-gateway-system --create-namespace --force-conflicts --wait --timeout 10m

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

"${HELM[@]}" upgrade --install cloudnative-pg cloudnative-pg \
  --repo https://giantswarm.github.io/control-plane-catalog/ --version "$CNPG_VERSION" \
  --namespace monitoring --create-namespace \
  --values "$ROOT/values/cloudnative-pg.yaml" --wait --timeout 5m
if ! "${KUBECTL[@]}" get secret grafana-secret-key -n monitoring >/dev/null 2>&1; then
  "${KUBECTL[@]}" create secret generic grafana-secret-key -n monitoring \
    --from-literal=secret-key="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
fi
# One AgentCredential per backend, for the agent write routes.
"${KUBECTL[@]}" apply -f "$DIR/agentcredentials.yaml"
BACKEND_VALUES=()
if [ "${LOCAL_BACKEND:-s3}" = azure ]; then
  BACKEND_VALUES=(--values "$DIR/values-azure.yaml")
fi
"${HELM[@]}" upgrade --install observability-platform "$CHART" \
  --namespace monitoring --create-namespace --force-conflicts \
  --values "$ROOT/helm/observability-platform/values-local.yaml" \
  --values "$DIR/values.yaml" "${BACKEND_VALUES[@]}"

# Garage starts without buckets. The garage-init Job creates them.
if [ "${LOCAL_BACKEND:-s3}" = s3 ]; then
  "${KUBECTL[@]}" wait --for=condition=complete job/garage-init -n monitoring --timeout 5m
fi

# The target of the tests in tests/ats. kind maps the Envoy Gateway `https` NodePort
# to 127.0.0.1:8443 (.ats/kind-config.yaml).
cat > "$ROOT/tests/ats/target.env" <<EOF
KUBE_CONTEXT=$CONTEXT
OBS_TOKEN_COMMAND=kubectl --context $CONTEXT exec -n jwt-issuer deploy/jwks -c signer -- /scripts/jwt.sh token
OBS_GATEWAY_ADDRESS=127.0.0.1:8443
OBS_CA_BUNDLE=$DIR/.keys/tls.crt
EOF
