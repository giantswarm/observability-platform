#!/usr/bin/env bash
# Installs the Observability Platform and its prerequisites for a first try, on a cluster
# you own or on kind. See docs/QUICKSTART.md.
#
#   install.sh [<config>]   <config> defaults to config.env next to this script.
#
# config.env turns the optional components on and off. The script is safe to run again:
# every step is an upgrade or an apply. It does not apply agentcredentials.yaml.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
CONFIG=${1:-$DIR/config.env}
# The operator's values and the chart's name services in this namespace. See
# values-observability-operator.yaml.
NAMESPACE=monitoring

[ -f "$CONFIG" ] || { echo "error: config file $CONFIG not found" >&2; exit 1; }
# shellcheck source=config.env
. "$CONFIG"

log() { printf '\n==> %s\n' "$*"; }
fail() { echo "error: $*" >&2; exit 1; }

# enabled NAME: true when the toggle NAME is `true`. Anything but `true` or `false` fails.
enabled() {
  case "${!1:-}" in
    true) return 0 ;;
    false) return 1 ;;
    *) fail "$1 in $CONFIG must be true or false, not '${!1:-}'" ;;
  esac
}

for toggle in INSTALL_ENVOY_GATEWAY CREATE_GATEWAY INSTALL_CERT_MANAGER DEPLOY_JWT_ISSUER \
  CREATE_TLS_SECRET INSTALL_CNPG CREATE_GRAFANA_SECRET_KEY INSTALL_PLUGIN_BARMAN_CLOUD; do
  enabled "$toggle" || true
done
case "${GATEWAY_OVERLAY:-}" in
  kind | base) ;;
  *) fail "GATEWAY_OVERLAY in $CONFIG must be kind or base, not '${GATEWAY_OVERLAY:-}'" ;;
esac

KUBECTL=(kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"})
HELM=(helm ${KUBE_CONTEXT:+--kube-context "$KUBE_CONTEXT"})

# has_crd NAME: true when the cluster serves the CRD NAME.
has_crd() { "${KUBECTL[@]}" get crd "$1" >/dev/null 2>&1; }

# --- Checks, before anything changes -------------------------------------------

for tool in kubectl helm; do
  command -v "$tool" >/dev/null || fail "$tool not found"
done
"${KUBECTL[@]}" cluster-info >/dev/null || fail "cannot reach the cluster${KUBE_CONTEXT:+ of context $KUBE_CONTEXT}"

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
if ! enabled DEPLOY_JWT_ISSUER \
  && grep -q 'jwks.jwt-issuer.svc' "$DIR/values-observability-platform.yaml"; then
  echo "warning: DEPLOY_JWT_ISSUER=false, but values-observability-platform.yaml still trusts the" \
    "local issuer. The external API rejects every token until you point it at your own." >&2
fi

case "$PLATFORM_CHART" in
  /* | oci://*) CHART=$PLATFORM_CHART ;;
  *) CHART=$ROOT/$PLATFORM_CHART ;;
esac

# --- Gateway and certificates --------------------------------------------------

if enabled INSTALL_ENVOY_GATEWAY; then
  log "Installing Envoy Gateway $ENVOY_GATEWAY_VERSION"
  "${HELM[@]}" upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
    --version "$ENVOY_GATEWAY_VERSION" \
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
  --values "$DIR/values-observability-operator.yaml" --wait --timeout 5m

if enabled INSTALL_CNPG; then
  log "Installing the CloudNativePG operator $CNPG_VERSION"
  "${HELM[@]}" upgrade --install cloudnative-pg cloudnative-pg \
    --repo https://giantswarm.github.io/control-plane-catalog/ --version "$CNPG_VERSION" \
    --namespace "$NAMESPACE" --create-namespace \
    --values "$DIR/values-cloudnative-pg.yaml" --wait --timeout 5m
fi

if enabled INSTALL_PLUGIN_BARMAN_CLOUD; then
  log "Installing the barman-cloud plugin $PLUGIN_BARMAN_CLOUD_VERSION"
  "${HELM[@]}" upgrade --install plugin-barman-cloud plugin-barman-cloud \
    --repo https://giantswarm.github.io/control-plane-catalog/ --version "$PLUGIN_BARMAN_CLOUD_VERSION" \
    --namespace "$NAMESPACE" --create-namespace \
    --values "$DIR/values-plugin-barman-cloud.yaml" --wait --timeout 5m
fi

# Never replaced: changing the key makes the secrets Grafana stored unreadable.
if enabled CREATE_GRAFANA_SECRET_KEY \
  && ! "${KUBECTL[@]}" get secret grafana-secret-key -n "$NAMESPACE" >/dev/null 2>&1; then
  log "Creating Grafana's secret key"
  "${KUBECTL[@]}" create secret generic grafana-secret-key -n "$NAMESPACE" \
    --from-literal=secret-key="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
fi

# --- Platform ------------------------------------------------------------------

log "Installing the Observability Platform"
if [ -d "$CHART" ]; then
  "${HELM[@]}" dependency update "$CHART"
fi
"${HELM[@]}" upgrade --install observability-platform "$CHART" \
  --namespace "$NAMESPACE" --create-namespace \
  --values "$DIR/values-observability-platform.yaml"

cat <<EOF

Done. Watch the pods start, which takes a few minutes:

  kubectl ${KUBE_CONTEXT:+--context $KUBE_CONTEXT }get pods -n $NAMESPACE

To push data from agents, create AgentCredentials. Examples, one per backend:

  kubectl ${KUBE_CONTEXT:+--context $KUBE_CONTEXT }apply -f $DIR/agentcredentials.yaml
EOF
if enabled CREATE_TLS_SECRET; then
  cat <<EOF

The Gateway serves a self-signed certificate, saved to $DIR/.keys/tls.crt.
Pass it to curl with --cacert.
EOF
fi
