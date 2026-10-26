# Local development

Azure Blob is the only object storage backend this chart supports. By default
`helm install` needs a real storage account - see
[doc/OBJECT_STORAGE.md](./OBJECT_STORAGE.md).

`localBlobStorage.enabled` replaces it with [Azurite](https://github.com/Azure/Azurite),
Microsoft's Azure Storage emulator, running in the cluster.

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

## Test

```bash
make local-ats
```

`make local-ats` runs the app-test-suite smoke test in `tests/ats` on a new kind cluster
named `ats`, then deletes the cluster. The `e2e-ats` CI job runs the same test. It needs
Docker and port 8443 free: run `make local-down` first.

## Teardown

```bash
make local-down
```
