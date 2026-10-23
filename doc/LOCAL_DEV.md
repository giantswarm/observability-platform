# Local development

By default `helm install` needs a real object store - see
[doc/OBJECT_STORAGE.md](./OBJECT_STORAGE.md).

`localObjectStorage.enabled` replaces it with a store running in the cluster. The store
follows `global.objectStorage.backend`:

- `s3`: [Garage](https://garagehq.deuxfleurs.fr/), a single-node S3-compatible store.
  It needs `global.objectStorage.s3.store: compatible`.
- `azure`: [Azurite](https://github.com/Azure/Azurite), Microsoft's Azure Storage emulator.

The kind setup runs Garage by default. `values-local.yaml` sets `backend: s3`,
`s3.store: compatible` and `localObjectStorage.enabled: true`. Loki runs Loki thanos mode
against Garage.

The chart computes the Garage endpoint, the region `garage` and plain HTTP. Setting
`global.objectStorage.s3.endpoint` or `global.objectStorage.s3.region` on top fails the
render.

Garage creates a fixed, well-known dev key on every start. The `garage-credentials` Secret
holds it. Mimir, Loki and Tempo read it from there. Do not use this key anywhere real.

## Prerequisites

- [kind](https://kind.sigs.k8s.io/), `helm`, `kubectl`, `openssl`, `xxd`, `curl`
- Around 6 GiB of memory free
- No kind cluster named `kind`
- Commands run from the repository root

## Install

```bash
make local-up
```

`make local-up` creates a kind cluster and installs these components:

- the observability-operator, as its own release, with `values/observability-operator.yaml`
- the chart in namespace `monitoring`, with `values-local.yaml`, on the `s3` backend with Garage
- the external API, with Envoy Gateway and a JWKS server. See [EXTERNAL_API.md](./EXTERNAL_API.md).

## Verify

A `post-install` hook creates the five buckets, so `make local-up` returns once it has
finished:

```bash
kubectl get job garage-init -n monitoring
```

```
NAME          STATUS     COMPLETIONS   DURATION   AGE
garage-init   Complete   1/1           14s        30s
```

Then check the pods:

```bash
kubectl get pods -n monitoring
```

Expect 24 Running. Mimir and Loki may restart once or twice while Garage starts.
Tempo's ingester, querier, query-frontend and compactor restart until the hook creates the
`tempo` bucket, two to four times each.

Log in at <https://grafana.localhost:8443> as `admin`. The chart generates a random password and
stores it in the `grafana` secret:

```bash
kubectl get secret grafana -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

The `https` listener serves a self-signed certificate that `make local-up` generates in
`hack/local/.keys/`, so browsers show a security warning. For `curl`, pass the certificate:

```bash
curl --cacert hack/local/.keys/tls.crt https://grafana.localhost:8443/api/health
```

Garage keeps its data and its buckets in an `emptyDir`: restarting the `garage` pod
discards both. The dev key survives: Garage creates it again on every start.

## Run on Azurite

```bash
make local-up LOCAL_BACKEND=azure
```

`LOCAL_BACKEND` defaults to `s3`. `LOCAL_BACKEND=azure` adds `hack/local/values-azure.yaml`
after the other values files. It sets `backend: azure` and drops the `s3` block of
`values-local.yaml`. The rest of the setup is the same.

These parts differ:

- Azurite runs in place of Garage.
- The chart computes the dev account name and the connection string. Mimir and Loki read the
  connection string. Tempo reads the dev account key from the `azurite-credentials` Secret.
- Loki runs its default Azure client, not Loki thanos mode.
- The `azurite-init` hook creates the five containers:

```bash
kubectl get job azurite-init -n monitoring
```

Azurite keeps its data in an `emptyDir`: restarting the `azurite` pod discards the data.

`make local-down` deletes the cluster for both backends. Pass `LOCAL_BACKEND=azure` again on
the next `make local-up` to stay on Azurite.

## Send data through the external API

The local setup replaces the OIDC issuer with a static JWKS served in the cluster.
`make local-token` signs tokens with a local key. Do not use this anywhere real.

The API answers only on the `https` listener. `AUTH` also passes the self-signed certificate
to `curl`:

```bash
API=https://observability.localhost:8443
AUTH=(--cacert hack/local/.keys/tls.crt -H "Authorization: Bearer $(make -s local-token)" -H "X-Scope-OrgID: default")
```

The requests in [EXTERNAL_API.md](./EXTERNAL_API.md#send-data) then run as written.

The token expires after one hour. Run the `AUTH=` line again for a new one.

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
- Tests never contain the Azurite or Garage dev key literals. They match the key shape.
