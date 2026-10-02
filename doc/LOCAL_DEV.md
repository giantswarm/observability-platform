# Local development

Azure Blob is the only object storage backend this chart supports. By default
`helm install` needs a real storage account - see
[doc/OBJECT_STORAGE.md](./OBJECT_STORAGE.md).

`localBlobStorage.enabled` replaces it with [Azurite](https://github.com/Azure/Azurite),
Microsoft's Azure Storage emulator, running in the cluster.

## Prerequisites

- [kind](https://kind.sigs.k8s.io/), `helm`, `kubectl`, `openssl`, `xxd`, `curl`
- Around 6 GiB of memory free
- No kind cluster named `o11y-platform`
- Commands run from the repository root

## Install

```bash
make local-up
```

`make local-up` creates a kind cluster and installs these components:

- the chart in namespace `monitoring`, with `values-local.yaml`
- the external API, with Envoy Gateway and a JWKS server. See [EXTERNAL_API.md](./EXTERNAL_API.md).

Envoy Gateway serves Grafana at `grafana.localhost:8080` and the external API at
`observability.localhost:8080`. `*.localhost` resolves to the loopback address.

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

Expect 21 Running. Mimir and Loki may restart once or twice while the emulator starts.

Log in at <http://grafana.localhost:8080> as `admin`. The chart generates a random password and
stores it in the `grafana` secret:

```bash
kubectl get secret grafana -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

Storage lives in an `emptyDir`: restarting the emulator discards the data.

## Send data through the external API

The local setup replaces the OIDC issuer with a static JWKS served in the cluster.
`make local-token` signs tokens with a local key. Do not use this anywhere real.

```bash
API=http://observability.localhost:8080
AUTH=(-H "Authorization: Bearer $(make -s local-token)" -H "X-Scope-OrgID: default")
```

The requests in [EXTERNAL_API.md](./EXTERNAL_API.md#send-data) then run as written.

The token expires after one hour. Run the `AUTH=` line again for a new one.

## Teardown

```bash
make local-down
```
