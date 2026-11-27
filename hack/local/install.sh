#!/usr/bin/env bash
# Installs the platform and the prerequisites hack/local/config.env turns on. See
# docs/QUICKSTART.md. `make local-up` and the app-test-suite pre-hook run it too.
#
#   install.sh [<chart>]   <chart> is the chart directory, a packaged .tgz or an OCI
#                          reference. Unset, ATS_CHART_PATH applies, then PLATFORM_CHART.
#
# LOCAL_CONFIG names the config file. Unset, config.env next to this script applies.
# A variable set in the environment wins over the config file. Under app-test-suite
# (ATS_CHART_PATH set), every toggle is on: the tests need the whole setup.
#
# With the issuer and the certificate on, it writes .env.verify, the target of
# `make verify`. It does not apply agentcredentials.yaml.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
CONFIG=${LOCAL_CONFIG:-$DIR/config.env}
# The operator's values and the chart's name services in this namespace. See
# values/observability-operator.yaml.
NAMESPACE=monitoring

TOGGLES=(INSTALL_ENVOY_GATEWAY CREATE_GATEWAY INSTALL_CERT_MANAGER DEPLOY_JWT_ISSUER
  CREATE_TLS_SECRET INSTALL_CNPG CREATE_GRAFANA_SECRET_KEY INSTALL_PLUGIN_BARMAN_CLOUD)
SETTINGS=("${TOGGLES[@]}" KUBE_CONTEXT GATEWAY_OVERLAY LOCAL_BACKEND PLATFORM_CHART
  ENVOY_GATEWAY_VERSION CERT_MANAGER_VERSION OPERATOR_VERSION CNPG_VERSION PLUGIN_BARMAN_CLOUD_VERSION)

log() { printf '\n==> %s\n' "$*"; }
fail() { echo "error: $*" >&2; exit 1; }

[ -f "$CONFIG" ] || fail "config file $CONFIG not found"
# The environment wins: keep what it sets, source the config, then restore it.
ENVIRONMENT=$(for v in "${SETTINGS[@]}"; do [ -z "${!v+set}" ] || declare -p "$v"; done)
# shellcheck source=config.env
. "$CONFIG"
eval "$ENVIRONMENT"

ATS=false
if [ $# -eq 0 ] && [ -n "${ATS_CHART_PATH:-}" ]; then
  ATS=true
  for toggle in "${TOGGLES[@]}"; do
    printf -v "$toggle" true
  done
fi

# enabled NAME: true when the toggle NAME is `true`. Anything but `true` or `false` fails.
enabled() {
  case "${!1:-}" in
    true) return 0 ;;
    false) return 1 ;;
    *) fail "$1 must be true or false, not '${!1:-}'" ;;
  esac
}

for toggle in "${TOGGLES[@]}"; do
  enabled "$toggle" || true
done
case "${GATEWAY_OVERLAY:-}" in
  kind | base) ;;
  *) fail "GATEWAY_OVERLAY must be kind or base, not '${GATEWAY_OVERLAY:-}'" ;;
esac
case "${LOCAL_BACKEND:-}" in
  s3 | azure) ;;
  *) fail "LOCAL_BACKEND must be s3 or azure, not '${LOCAL_BACKEND:-}'" ;;
esac

KUBECTL=(kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"})
HELM=(helm ${KUBE_CONTEXT:+--kube-context "$KUBE_CONTEXT"})
CONTEXT=${KUBE_CONTEXT:-$("${KUBECTL[@]}" config current-context)}

# has_crd NAME: true when the cluster serves the CRD NAME.
has_crd() { "${KUBECTL[@]}" get crd "$1" >/dev/null 2>&1; }

# --- Checks, before anything changes -------------------------------------------

for tool in kubectl helm; do
  command -v "$tool" >/dev/null || fail "$tool not found"
done
"${KUBECTL[@]}" cluster-info >/dev/null || fail "cannot reach the cluster of context $CONTEXT"

if enabled CREATE_TLS_SECRET && ! enabled DEPLOY_JWT_ISSUER; then
  fail "CREATE_TLS_SECRET=true needs DEPLOY_JWT_ISSUER=true: the issuer's signer generates the certificate"
fi
if enabled CREATE_GATEWAY && ! enabled INSTALL_ENVOY_GATEWAY \
  && ! has_crd envoyproxies.gateway.envoyproxy.io; then
  fail "CREATE_GATEWAY=true needs Envoy Gateway: set INSTALL_ENVOY_GATEWAY=true or install it first"
fi
if enabled INSTALL_PLUGIN_BARMAN_CLOUD && ! enabled INSTALL_CERT_MANAGER \
  && ! has_crd certificates.cert-manager.io; then
  fail "INSTALL_PLUGIN_BARMAN_CLOUD=true needs cert-manager: set INSTALL_CERT_MANAGER=true or install it first"
fi

CHART=${1:-${ATS_CHART_PATH:-$PLATFORM_CHART}}
case "$CHART" in
  /* | oci://*) ;;
  *) [ -e "$CHART" ] || CHART=$ROOT/$CHART ;;
esac

# --- Gateway and certificates --------------------------------------------------

# --force-conflicts: app-test-suite applies its own Gateway API and Prometheus Operator
# CRDs first. The CRDs of the Envoy Gateway chart and of this chart take over their fields.
FORCE=()
if [ "$ATS" = true ]; then
  FORCE=(--force-conflicts)
fi

if enabled INSTALL_ENVOY_GATEWAY; then
  log "Installing Envoy Gateway $ENVOY_GATEWAY_VERSION"
  "${HELM[@]}" upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
    --version "$ENVOY_GATEWAY_VERSION" "${FORCE[@]}" \
    --namespace envoy-gateway-system --create-namespace --wait --timeout 10m
fi

# After Envoy Gateway: cert-manager detects the Gateway API CRDs at start-up only.
if enabled INSTALL_CERT_MANAGER; then
  log "Installing cert-manager $CERT_MANAGER_VERSION"
  "${HELM[@]}" upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager \
    --version "$CERT_MANAGER_VERSION" --namespace cert-manager --create-namespace \
    --set crds.enabled=true --set 'extraArgs={--enable-gateway-api}' --wait --timeout 10m
fi

# The signer generates the JWT signing key and the Gateway certificate. See jwks.yaml.
if enabled DEPLOY_JWT_ISSUER; then
  log "Deploying the local JWT issuer"
  "${KUBECTL[@]}" create namespace jwt-issuer --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
  "${KUBECTL[@]}" create configmap local-scripts -n jwt-issuer \
    --from-file="$DIR/jwt.sh" --from-file="$DIR/tls.sh" \
    --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
  "${KUBECTL[@]}" apply -f "$DIR/jwks.yaml"
  "${KUBECTL[@]}" rollout status deployment/jwks -n jwt-issuer --timeout 5m
fi

if enabled CREATE_TLS_SECRET; then
  log "Creating the self-signed Gateway certificate"
  mkdir -p "$DIR/.keys"
  "${KUBECTL[@]}" exec -n jwt-issuer deploy/jwks -c signer -- cat /keys/tls.crt > "$DIR/.keys/tls.crt"
  KEY=$(mktemp)
  trap 'rm -f "$KEY"' EXIT
  "${KUBECTL[@]}" exec -n jwt-issuer deploy/jwks -c signer -- cat /keys/tls.key > "$KEY"
  "${KUBECTL[@]}" create namespace envoy-gateway-system --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
  "${KUBECTL[@]}" create secret tls local-https-tls -n envoy-gateway-system \
    --cert="$DIR/.keys/tls.crt" --key="$KEY" \
    --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
fi

if enabled CREATE_GATEWAY; then
  log "Creating the Gateway ($GATEWAY_OVERLAY)"
  "${KUBECTL[@]}" apply -k "$DIR/envoy-gateway/$GATEWAY_OVERLAY"
fi

# --- Operators -----------------------------------------------------------------

log "Installing the observability-operator $OPERATOR_VERSION"
"${HELM[@]}" upgrade --install observability-operator observability-operator \
  --repo https://giantswarm.github.io/control-plane-catalog/ --version "$OPERATOR_VERSION" \
  --namespace "$NAMESPACE" --create-namespace \
  --values "$ROOT/values/observability-operator.yaml" --wait --timeout 5m

if enabled INSTALL_CNPG; then
  log "Installing the CloudNativePG operator $CNPG_VERSION"
  "${HELM[@]}" upgrade --install cloudnative-pg cloudnative-pg \
    --repo https://giantswarm.github.io/control-plane-catalog/ --version "$CNPG_VERSION" \
    --namespace "$NAMESPACE" --create-namespace \
    --values "$ROOT/values/cloudnative-pg.yaml" --wait --timeout 5m
fi

if enabled INSTALL_PLUGIN_BARMAN_CLOUD; then
  log "Installing the barman-cloud plugin $PLUGIN_BARMAN_CLOUD_VERSION"
  "${HELM[@]}" upgrade --install plugin-barman-cloud plugin-barman-cloud \
    --repo https://giantswarm.github.io/control-plane-catalog/ --version "$PLUGIN_BARMAN_CLOUD_VERSION" \
    --namespace "$NAMESPACE" --create-namespace \
    --values "$ROOT/values/plugin-barman-cloud.yaml" --wait --timeout 5m
fi

# Never replaced: changing the key makes the secrets Grafana stored unreadable.
if enabled CREATE_GRAFANA_SECRET_KEY \
  && ! "${KUBECTL[@]}" get secret grafana-secret-key -n "$NAMESPACE" >/dev/null 2>&1; then
  log "Creating Grafana's secret key"
  "${KUBECTL[@]}" create secret generic grafana-secret-key -n "$NAMESPACE" \
    --from-literal=secret-key="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
fi

# --- Platform ------------------------------------------------------------------

# values/observability-platform.yaml turns on the features below. Turn off the ones whose
# prerequisites are missing, so the chart's render checks pass.
OVERRIDES=()
if [ "$LOCAL_BACKEND" = azure ]; then
  OVERRIDES+=(--set global.objectStorage.backend=azure)
fi
# Backups support the s3 backend only.
if ! enabled INSTALL_PLUGIN_BARMAN_CLOUD || [ "$LOCAL_BACKEND" = azure ]; then
  OVERRIDES+=(--set grafana.postgresqlCluster.backup.enabled=false)
fi
# Grafana's route, the agent write routes and the external API need Envoy Gateway.
if ! has_crd securitypolicies.gateway.envoyproxy.io; then
  echo "note: the cluster serves no Envoy Gateway CRDs. Grafana's route, the agent write" \
    "routes and the external API stay off." >&2
  OVERRIDES+=(--set grafana.grafana.route.main.enabled=false
    --set mimir.routes.gateway.enabled=false --set loki.gatewayRoute.enabled=false
    --set tempo.routes.https.enabled=false --set tempo.routes.grpc.enabled=false
    --set observabilityPlatformApi.enabled=false)
elif ! enabled DEPLOY_JWT_ISSUER \
  && grep -q 'jwks.jwt-issuer.svc' "$ROOT/values/observability-platform.yaml"; then
  echo "note: DEPLOY_JWT_ISSUER=false and values/observability-platform.yaml trusts the local" \
    "issuer. The external API stays off." >&2
  OVERRIDES+=(--set observabilityPlatformApi.enabled=false)
fi

log "Installing the Observability Platform"
if [ -d "$CHART" ]; then
  "${HELM[@]}" dependency build "$CHART"
fi
"${HELM[@]}" upgrade --install observability-platform "$CHART" \
  --namespace "$NAMESPACE" --create-namespace "${FORCE[@]}" \
  --values "$ROOT/helm/observability-platform/values-local.yaml" \
  --values "$ROOT/values/observability-platform.yaml" "${OVERRIDES[@]}"

# The target of the tests in tests/ats. With the kind overlay, kind maps the Envoy Gateway
# `https` NodePort to 127.0.0.1:8443 (.ats/kind-config.yaml).
if enabled DEPLOY_JWT_ISSUER && enabled CREATE_TLS_SECRET; then
  cat > "$ROOT/.env.verify" <<EOF
KUBE_CONTEXT=$CONTEXT
OBS_TOKEN_COMMAND=kubectl --context $CONTEXT exec -n jwt-issuer deploy/jwks -c signer -- /scripts/jwt.sh token
OBS_GATEWAY_ADDRESS=127.0.0.1:8443
OBS_CA_BUNDLE=$DIR/.keys/tls.crt
EOF
fi

cat <<EOF

Done. Watch the pods start, which takes a few minutes:

  kubectl --context $CONTEXT get pods -n $NAMESPACE

To push data from agents, create AgentCredentials. Examples, one per backend:

  kubectl --context $CONTEXT apply -f $DIR/agentcredentials.yaml
EOF
