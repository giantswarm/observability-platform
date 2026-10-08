#!/usr/bin/env bash
# Render checks for the observability-operator wiring in the chart: the guards in
# templates/check-operator-namespace.yaml and the Standalone profile. Each case runs
# `helm template` and asserts it fails with the expected message, or renders the
# expected operator settings. Needs the chart dependencies (`helm dependency build`).
set -euo pipefail

CHART=helm/observability-platform
BASE=(--namespace monitoring --set global.objectStorage.azure.accountName=render-test)
failures=0

render() { helm template observability-platform "$CHART" "${BASE[@]}" "$@" 2>&1; }

expect_fail() { # name, expected message, helm args...
  local name=$1 msg=$2 out
  shift 2
  if out=$(render "$@"); then
    echo "FAIL  $name: render succeeded, expected an error containing: $msg"
    failures=$((failures + 1))
  elif ! grep -qF -- "$msg" <<<"$out"; then
    echo "FAIL  $name: render failed without: $msg"
    echo "$out" | tail -5
    failures=$((failures + 1))
  else
    echo "ok    $name"
  fi
}

expect_args() { # name, args the operator Deployment must have (one per line), helm args...
  local name=$1 want=$2 out
  shift 2
  if ! out=$(render "$@"); then
    echo "FAIL  $name: render failed"
    echo "$out" | tail -5
    failures=$((failures + 1))
    return
  fi
  while IFS= read -r arg; do
    if ! grep -qF -- "- $arg" <<<"$out"; then
      echo "FAIL  $name: operator is missing $arg"
      failures=$((failures + 1))
      return
    fi
  done <<<"$want"
  echo "ok    $name"
}

expect_fail "namespace other than monitoring" 'only works in namespace "monitoring"' \
  --namespace observability
expect_fail "Grafana URL override" "Remove the override" \
  --set observability-operator.grafana.url=http://grafana.example.svc.cluster.local
expect_fail "tracing on without Tempo" "tempo.enabled is false but observability-operator.tracing.enabled is true" \
  --set observability-operator.tracing.enabled=true
expect_fail "Tempo on without tracing" "tempo.enabled is true but observability-operator.tracing.enabled is false" \
  --set tempo.enabled=true
expect_fail "tenant mismatch" "observability-operator.defaultTenant" \
  --set global.tenant=other

expect_args "Standalone profile" "--controllers-grafana-organization-enabled=true
--controllers-dashboard-enabled=true
--controllers-agent-credential-enabled=false
--controllers-log-export-enabled=false
--controllers-cluster-enabled=false
--controllers-alertmanager-enabled=false
--grafana-sso-org-mapping-enabled=false
--tracing-enabled=false"
expect_args "Tempo and tracing on together" "--tracing-enabled=true" \
  --set tempo.enabled=true --set observability-operator.tracing.enabled=true

out=$(render)
if grep -q "^kind: PodMonitor" <<<"$out"; then
  echo "FAIL  Standalone profile: a PodMonitor is rendered"
  failures=$((failures + 1))
elif ! grep -q "name: grafanaorganizations.observability.giantswarm.io" <<<"$out"; then
  echo "FAIL  Standalone profile: the GrafanaOrganization CRD is not rendered"
  failures=$((failures + 1))
else
  echo "ok    Standalone profile: CRDs rendered, no PodMonitor"
fi

if ! render --namespace observability --set observabilityOperator.enabled=false >/dev/null; then
  echo "FAIL  operator disabled: the guards still run"
  failures=$((failures + 1))
else
  echo "ok    operator disabled: any namespace renders"
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures render check(s) failed"
  exit 1
fi
echo "all render checks passed"
