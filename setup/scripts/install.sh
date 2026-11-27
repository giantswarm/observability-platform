#!/usr/bin/env bash
# Installs the platform and the prerequisites setup/config/config.env turns on.
# `make local-up` and the app-test-suite pre-hook run it too.
#
#   install.sh [<chart>]   <chart> is the chart directory, a packaged .tgz or an OCI
#                          reference. Unset, ATS_CHART_PATH applies, then PLATFORM_CHART.
#
# LOCAL_CONFIG names the config file. Unset, setup/config/config.env applies.
# A variable set in the environment wins over the config file. Under app-test-suite
# (ATS_CHART_PATH set), every toggle is on: the tests need the whole setup.
#
# Under app-test-suite, it writes .env.verify, the target of the tests. It does not apply
# agentcredentials.yaml.
set -euo pipefail

# Giant Swarm's OCI registry for Helm charts. Every release comes from it, except a
# Platform chart given as a directory or a .tgz.
REGISTRY=oci://gsoci.azurecr.io/charts/giantswarm
# This script's directory, setup/scripts, and the setup files in setup/config.
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
CONFIG_DIR=$ROOT/setup/config
CONFIG=${LOCAL_CONFIG:-$CONFIG_DIR/config.env}
# The operator's values and the chart's name services in this namespace. See
# values/observability-operator.yaml.
NAMESPACE=monitoring

TOGGLES=(INSTALL_ENVOY_GATEWAY CREATE_GATEWAY INSTALL_CERT_MANAGER DEPLOY_JWT_ISSUER
  CREATE_TLS_SECRET INSTALL_CNPG CREATE_GRAFANA_SECRET_KEY INSTALL_PLUGIN_BARMAN_CLOUD
  USE_LOCAL_PROFILE)
SETTINGS=("${TOGGLES[@]}" KUBE_CONTEXT GATEWAY_OVERLAY LOCAL_BACKEND PLATFORM_CHART PLATFORM_CHART_VERSION PLATFORM_VALUES
  ENVOY_GATEWAY_VERSION CERT_MANAGER_VERSION OPERATOR_VERSION CNPG_VERSION PLUGIN_BARMAN_CLOUD_VERSION)

log() { printf '\n==> %s\n' "$*"; }
fail() { echo "error: $*" >&2; exit 1; }

[ -f "$CONFIG" ] || fail "config file $CONFIG not found"
# The environment wins: keep what it sets, source the config, then restore it.
ENVIRONMENT=$(for v in "${SETTINGS[@]}"; do [ -z "${!v+set}" ] || declare -p "$v"; done)
# shellcheck source=../config/config.env
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

# The Platform chart's values files, in order. Relative paths are relative to the
# repository root.
read -r -a VALUES_FILES <<< "${PLATFORM_VALUES:-values/observability-platform.yaml}"
[ ${#VALUES_FILES[@]} -gt 0 ] || fail "PLATFORM_VALUES names no values file"
for i in "${!VALUES_FILES[@]}"; do
  case "${VALUES_FILES[$i]}" in
    /*) ;;
    *) VALUES_FILES[i]=$ROOT/${VALUES_FILES[i]} ;;
  esac
  [ -f "${VALUES_FILES[i]}" ] || fail "values file ${VALUES_FILES[i]} not found"
done

# last_with PATTERN: the last values file with a line matching PATTERN, the one whose
# setting wins. Empty when none has one.
last_with() {
  local file found=
  for file in "${VALUES_FILES[@]}"; do
    if grep -qE "$1" "$file"; then found=$file; fi
  done
  echo "$found"
}

# grafana_on_postgresql: false when the last values file that sets
# grafana.postgresqlCluster.enabled sets it to false, for Grafana on SQLite.
grafana_on_postgresql() {
  local file setting=true
  for file in "${VALUES_FILES[@]}"; do
    case "$(awk '
      /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
      { indent = match($0, /[^ ]/) }
      block && indent <= block { block = 0 }
      /^[[:space:]]*postgresqlCluster:[[:space:]]*$/ { block = indent; next }
      block && /^[[:space:]]*enabled:[[:space:]]*/ { sub(/^[[:space:]]*enabled:[[:space:]]*/, ""); print; exit }
    ' "$file")" in
      false) setting=false ;;
      true) setting=true ;;
    esac
  done
  [ "$setting" = true ]
}

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
# Grafana on PostgreSQL needs the CNPG operator and its secret key. The chart's render
# checks catch both too, but only after every release above it is installed.
if grafana_on_postgresql; then
  if ! enabled INSTALL_CNPG && ! has_crd clusters.postgresql.cnpg.io; then
    fail "INSTALL_CNPG=false needs a CNPG operator: set INSTALL_CNPG=true or install it first"
  fi
  if ! enabled CREATE_GRAFANA_SECRET_KEY \
    && ! "${KUBECTL[@]}" get secret grafana-secret-key -n "$NAMESPACE" >/dev/null 2>&1; then
    fail "CREATE_GRAFANA_SECRET_KEY=false needs the Secret grafana-secret-key in $NAMESPACE: create it first"
  fi
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
# --enable-gateway-api only while the cluster serves them: without them, cert-manager
# crashloops.
if enabled INSTALL_CERT_MANAGER; then
  log "Installing cert-manager $CERT_MANAGER_VERSION"
  CERT_MANAGER_ARGS=()
  if has_crd gateways.gateway.networking.k8s.io; then
    CERT_MANAGER_ARGS=(--set 'extraArgs={--enable-gateway-api}')
  fi
  "${HELM[@]}" upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager \
    --version "$CERT_MANAGER_VERSION" --namespace cert-manager --create-namespace \
    --set crds.enabled=true "${CERT_MANAGER_ARGS[@]}" --wait --timeout 10m
fi

# The signer generates the JWT signing key and the Gateway certificate. See jwks.yaml.
if enabled DEPLOY_JWT_ISSUER; then
  log "Deploying the local JWT issuer"
  "${KUBECTL[@]}" create namespace jwt-issuer --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
  "${KUBECTL[@]}" create configmap local-scripts -n jwt-issuer \
    --from-file="$DIR/jwt.sh" --from-file="$DIR/tls.sh" \
    --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
  "${KUBECTL[@]}" apply -f "$CONFIG_DIR/jwks.yaml"
  "${KUBECTL[@]}" rollout status deployment/jwks -n jwt-issuer --timeout 5m
fi

if enabled CREATE_TLS_SECRET; then
  log "Creating the self-signed Gateway certificate"
  mkdir -p "$CONFIG_DIR/.keys"
  "${KUBECTL[@]}" exec -n jwt-issuer deploy/jwks -c signer -- cat /keys/tls.crt > "$CONFIG_DIR/.keys/tls.crt"
  KEY=$(mktemp)
  trap 'rm -f "$KEY"' EXIT
  "${KUBECTL[@]}" exec -n jwt-issuer deploy/jwks -c signer -- cat /keys/tls.key > "$KEY"
  "${KUBECTL[@]}" create namespace envoy-gateway-system --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
  "${KUBECTL[@]}" create secret tls local-https-tls -n envoy-gateway-system \
    --cert="$CONFIG_DIR/.keys/tls.crt" --key="$KEY" \
    --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
fi

if enabled CREATE_GATEWAY; then
  log "Creating the Gateway ($GATEWAY_OVERLAY)"
  "${KUBECTL[@]}" apply -k "$CONFIG_DIR/envoy-gateway/$GATEWAY_OVERLAY"
fi

# --- Operators -----------------------------------------------------------------

log "Installing the observability-operator $OPERATOR_VERSION"
"${HELM[@]}" upgrade --install observability-operator "$REGISTRY/observability-operator" \
  --version "$OPERATOR_VERSION" \
  --namespace "$NAMESPACE" --create-namespace \
  --values "$ROOT/values/observability-operator.yaml" --wait --timeout 5m

if enabled INSTALL_CNPG; then
  log "Installing the CloudNativePG operator $CNPG_VERSION"
  "${HELM[@]}" upgrade --install cloudnative-pg "$REGISTRY/cloudnative-pg" \
    --version "$CNPG_VERSION" \
    --namespace "$NAMESPACE" --create-namespace \
    --values "$ROOT/values/cloudnative-pg.yaml" --wait --timeout 5m
fi

if enabled INSTALL_PLUGIN_BARMAN_CLOUD; then
  log "Installing the barman-cloud plugin $PLUGIN_BARMAN_CLOUD_VERSION"
  "${HELM[@]}" upgrade --install plugin-barman-cloud "$REGISTRY/plugin-barman-cloud" \
    --version "$PLUGIN_BARMAN_CLOUD_VERSION" \
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

# The local profile: small sizing and a store in the cluster, under the platform values.
VALUES=()
OVERRIDES=()
if enabled USE_LOCAL_PROFILE; then
  VALUES=(--values "$ROOT/helm/observability-platform/values-local.yaml")
  if [ "$LOCAL_BACKEND" = azure ]; then
    # Backups support the s3 backend only.
    OVERRIDES+=(--set global.objectStorage.backend=azure
      --set grafana.postgresqlCluster.backup.enabled=false)
  fi
fi
for file in "${VALUES_FILES[@]}"; do
  VALUES+=(--values "$file")
done

# The platform values turn on the features below. Turn off the ones whose
# prerequisites are missing, so the chart's render checks pass.
if ! has_crd objectstores.barmancloud.cnpg.io; then
  echo "note: the cluster serves no barman-cloud ObjectStore CRD. Grafana's backups stay off." >&2
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
elif ! enabled DEPLOY_JWT_ISSUER; then
  # The last file that lists JWT providers sets them: lists replace, they don't merge.
  PROVIDERS=$(last_with '^[[:space:]]*providers:')
  if [ -n "$PROVIDERS" ] && grep -q 'jwks.jwt-issuer.svc' "$PROVIDERS"; then
    echo "note: DEPLOY_JWT_ISSUER=false and $PROVIDERS trusts the local issuer." \
      "The external API stays off." >&2
    OVERRIDES+=(--set observabilityPlatformApi.enabled=false)
  fi
fi

log "Installing the Observability Platform"
# A directory needs its subcharts. A registry chart takes PLATFORM_CHART_VERSION, or its
# latest release when that's empty.
CHART_ARGS=()
case "$CHART" in
  oci://*) CHART_ARGS=(${PLATFORM_CHART_VERSION:+--version "$PLATFORM_CHART_VERSION"}) ;;
  *) [ ! -d "$CHART" ] || "${HELM[@]}" dependency update "$CHART" ;;
esac
"${HELM[@]}" upgrade --install observability-platform "$CHART" "${CHART_ARGS[@]}" \
  --namespace "$NAMESPACE" --create-namespace "${FORCE[@]}" \
  "${VALUES[@]}" "${OVERRIDES[@]}"

# The target of the tests in tests/ats, under app-test-suite. kind maps the Envoy Gateway
# `https` NodePort to 127.0.0.1:8443 (.ats/kind-config.yaml). `make local-up` writes its
# own.
if [ "$ATS" = true ]; then
  cat > "$ROOT/.env.verify" <<EOF
KUBE_CONTEXT=$CONTEXT
OBS_TOKEN_COMMAND=kubectl --context $CONTEXT exec -n jwt-issuer deploy/jwks -c signer -- /scripts/jwt.sh token
OBS_GATEWAY_ADDRESS=127.0.0.1:8443
OBS_CA_BUNDLE=$CONFIG_DIR/.keys/tls.crt
EOF
fi

cat <<EOF

Done. Watch the pods start, which takes a few minutes:

  kubectl --context $CONTEXT get pods -n $NAMESPACE

To push data from agents, create AgentCredentials. Examples, one per backend:

  kubectl --context $CONTEXT apply -f $CONFIG_DIR/agentcredentials.yaml
EOF
