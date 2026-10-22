#!/usr/bin/env bash
# Verification for the local setup. `make local-test` runs it after `make local-up`.
#
#   test.sh   checks that the workloads are ready, Grafana answers, and one
#             write/read round trip per signal works through the external API
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
KUBECTL="kubectl --context kind-kind"
NAMESPACE=monitoring
API=https://observability.localhost:8443
GRAFANA=https://grafana.localhost:8443
TENANT=default
RUN="e2e-$(date +%s)"
TRACE_ID=$(openssl rand -hex 16)
CURL=(curl -sS --cacert "$DIR/.keys/tls.crt"
  --connect-to "observability.localhost:8443:127.0.0.1:8443"
  --connect-to "grafana.localhost:8443:127.0.0.1:8443")

PASS=0
ok() { PASS=$((PASS + 1)); echo "OK   $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

# retry <name> <seconds> <command...>: run the command every 5s until it
# succeeds, then print OK. Fail once the deadline passes.
retry() {
  local name=$1 deadline=$(($(date +%s) + $2))
  shift 2
  until "$@" >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "$deadline" ] || fail "$name"
    sleep 5
  done
  ok "$name"
}

# == Install

rollouts() {
  local kind name
  for kind in deployment statefulset daemonset; do
    for name in $($KUBECTL get "$kind" -n "$NAMESPACE" -o name); do
      $KUBECTL rollout status "$name" -n "$NAMESPACE" --timeout=10s || return 1
    done
  done
}

retry "install/azurite-init" 300 \
  $KUBECTL wait --for=condition=complete job/azurite-init -n "$NAMESPACE"
retry "install/workloads ready" 900 rollouts

# == Grafana

grafana_health() { "${CURL[@]}" -f -o /dev/null "$GRAFANA/api/health"; }
grafana_login() {
  local password
  password=$($KUBECTL get secret grafana -n "$NAMESPACE" -o jsonpath='{.data.admin-password}' | base64 -d)
  "${CURL[@]}" -f -o /dev/null -u "admin:$password" "$GRAFANA/api/org"
}

retry "grafana/health" 300 grafana_health
grafana_login && ok "grafana/login" || fail "grafana/login"

# == Write, one request per signal, through the external API

AUTH=(-H "Authorization: Bearer $("$DIR/jwt.sh" token)" -H "X-Scope-OrgID: $TENANT")

write_metric() {
  "${CURL[@]}" -f -o /dev/null "${AUTH[@]}" -H "Content-Type: application/json" "$API/otlp/v1/metrics" \
    -d '{"resourceMetrics":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"'"$RUN"'"}}]},"scopeMetrics":[{"metrics":[{"name":"e2e_test","gauge":{"dataPoints":[{"asDouble":42,"timeUnixNano":"'"$(date +%s)"'000000000"}]}}]}]}]}'
}
write_log() {
  "${CURL[@]}" -f -o /dev/null "${AUTH[@]}" -H "Content-Type: application/json" "$API/loki/api/v1/push" \
    -d '{"streams":[{"stream":{"job":"'"$RUN"'"},"values":[["'"$(date +%s)"'000000000","hello from '"$RUN"'"]]}]}'
}
write_trace() {
  local now
  now=$(date +%s)
  "${CURL[@]}" -f -o /dev/null "${AUTH[@]}" -H "Content-Type: application/json" "$API/v1/traces" \
    -d '{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"'"$RUN"'"}}]},"scopeSpans":[{"spans":[{"traceId":"'"$TRACE_ID"'","spanId":"eee19b7ec3c1b174","name":"e2e-test","kind":1,"startTimeUnixNano":"'"$now"'000000000","endTimeUnixNano":"'"$now"'100000000"}]}]}]}'
}

retry "write/metric otlp" 120 write_metric
retry "write/log" 120 write_log
retry "write/trace otlp" 120 write_trace

# == Read the data back

read_metric() {
  "${CURL[@]}" -fG "${AUTH[@]}" "$API/prometheus/api/v1/query" --data-urlencode 'query=e2e_test' \
    | grep '"__name__":"e2e_test"'
}
read_log() {
  "${CURL[@]}" -fG "${AUTH[@]}" "$API/loki/api/v1/query_range" --data-urlencode 'query={job="'"$RUN"'"}' \
    | grep "hello from $RUN"
}
read_trace() {
  "${CURL[@]}" -f "${AUTH[@]}" "$API/tempo/api/v2/traces/$TRACE_ID" | grep "$RUN"
}

retry "read/metric" 300 read_metric
retry "read/log" 300 read_log
retry "read/trace" 300 read_trace

# == Auth rejection

no_token() {
  local code
  code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' -H "X-Scope-OrgID: $TENANT" "$API/prometheus/api/v1/query?query=up")
  [ "$code" = 401 ]
}
no_token && ok "auth/read no token" || fail "auth/read no token"

echo "== $PASS checks passed"
