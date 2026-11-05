# Local development

By default `helm install` needs a real object store - see
[doc/OBJECT_STORAGE.md](./OBJECT_STORAGE.md).

`localBlobStorage.enabled` replaces it with [Azurite](https://github.com/Azure/Azurite),
Microsoft's Azure Storage emulator, running in the cluster. Azurite serves the `azure`
backend only. `values-local.yaml` sets `backend: azure`.

## Prerequisites

- [kind](https://kind.sigs.k8s.io/), `helm` 4, `kubectl`, `curl`
- Around 6 GiB of memory free
- No kind cluster named `kind`
- Commands run from the repository root

## Install

```bash
make local-up
```

`make local-up` creates a kind cluster and installs these components:

- the observability-operator, as its own release, with `values/observability-operator.yaml`
- the chart in namespace `monitoring`, with `values-local.yaml`
- the external API, with Envoy Gateway and a JWKS server. See [EXTERNAL_API.md](./EXTERNAL_API.md).
- the agent write routes, at `mimir.localhost`, `write.loki.localhost` and `tempo.localhost`,
  with one AgentCredential per backend in namespace `agents` (`hack/local/agentcredentials.yaml`).
  See [AGENT_CREDENTIALS.md](./AGENT_CREDENTIALS.md).

## Verify

A `post-install` hook creates the storage containers, so `make local-up` returns once it
has finished:

```bash
kubectl get job azurite-init -n monitoring
```

```
NAME           STATUS     COMPLETIONS   DURATION   AGE
azurite-init   Complete   1/1           14s        30s
```

Then check the pods:

```bash
kubectl get pods -n monitoring
```

Expect 23 Running. Mimir and Loki may restart once or twice while the emulator starts.
Tempo's ingester, querier, query-frontend and compactor restart until the hook creates the
`tempo` container, two to four times each.

Log in at <https://grafana.localhost:8443> as `admin`. The chart generates a random password and
stores it in the `grafana` secret:

```bash
kubectl get secret grafana -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

The `https` listener serves a self-signed certificate, so browsers show a security warning.
A signer pod in the `jwt-issuer` namespace generates it, and `make local-up` copies it to
`hack/local/.keys/`. For `curl`, pass the certificate:

```bash
curl --cacert hack/local/.keys/tls.crt https://grafana.localhost:8443/api/health
```

The signer creates the certificate once, when its pod starts, and keeps it. A cluster created
before the agent write hostnames were added keeps a certificate without `mimir.localhost`,
`write.loki.localhost` and `tempo.localhost`, so pushes to them fail TLS verification. Run
`make local-down` and `make local-up` to get a new one.

Storage lives in an `emptyDir`: restarting the emulator discards the data.

## Send data through the external API

The local setup replaces the OIDC issuer with a static JWKS served in the cluster.
`make local-token` signs tokens with a key the signer pod generates. Do not use this anywhere real.

The API answers only on the `https` listener. `AUTH` also passes the self-signed certificate
to `curl`:

```bash
API=https://observability.localhost:8443
AUTH=(--cacert hack/local/.keys/tls.crt -H "Authorization: Bearer $(make -s local-token)" -H "X-Scope-OrgID: default")
```

The requests in [EXTERNAL_API.md](./EXTERNAL_API.md#send-data) then run as written.

The token expires after one hour. Run the `AUTH=` line again for a new one.

## Push with an AgentCredential

`make local-up` creates the AgentCredentials `metrics`, `logs` and `traces` in namespace `agents`.
The operator writes a Secret of the same name next to each. Read the username and password of the
`logs` credential from its Secret:

```bash
CRED="$(kubectl get secret logs -n agents -o jsonpath='{.data.username}' | base64 -d):$(kubectl get secret logs -n agents -o jsonpath='{.data.password}' | base64 -d)"
```

Push a log line with it:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' --cacert hack/local/.keys/tls.crt -u "$CRED" \
  -H "X-Scope-OrgID: default" -H "Content-Type: application/json" https://write.loki.localhost:8443/loki/api/v1/push \
  -d '{"streams":[{"stream":{"job":"basic-auth-test"},"values":[["'"$(date +%s)"'000000000","hello"]]}]}'
```

```
204
```

The same credential gets a `401` on `https://mimir.localhost:8443/otlp/v1/metrics`. See
[AGENT_CREDENTIALS.md](./AGENT_CREDENTIALS.md) for the other backends.

## Test

```bash
make local-ats
```

`make local-ats` runs the app-test-suite smoke test in `tests/ats` on a new kind cluster
named `ats`, then deletes the cluster. The `execute-chart-tests` CI job runs the same test. It needs
Docker and port 8443 free: run `make local-down` first.

## Teardown

```bash
make local-down
```

## Chart unit tests

The chart unit tests render the Platform chart and assert on the output. They need no
cluster. CI runs them in the `chart-tests` workflow.

```bash
make helm-test
```

The target installs the helm-unittest plugin on first run. It runs without subcharts, so
the suites cover only the Platform chart's own templates.

- Suites live in `helm/observability-platform/tests/` and end in `_test.yaml`.
- Shared values files live in `helm/observability-platform/tests/values/`: `azure.yaml`,
  `s3-aws.yaml` and `s3-compatible.yaml`. A case lists them under `values:`.
- Every suite renders with release `obs` in namespace `monitoring`.
- Tests never contain the Azurite dev key literal. They match the key shape.
