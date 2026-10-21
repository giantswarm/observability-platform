# Local development

Azure Blob is the only object storage backend this chart supports. By default
`helm install` needs a real storage account - see
[doc/OBJECT_STORAGE.md](./OBJECT_STORAGE.md).

`localBlobStorage.enabled` replaces it with [Azurite](https://github.com/Azure/Azurite),
Microsoft's Azure Storage emulator, running in the cluster.

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
- the chart in namespace `monitoring`, with `values-local.yaml`
- the external API, with Envoy Gateway and a JWKS server. See [EXTERNAL_API.md](./EXTERNAL_API.md).

## Verify

A sidecar in the Azurite pod creates the storage containers, and the pod turns ready only
once they exist. `make local-up` returns when it is ready:

```bash
kubectl get deployment azurite -n monitoring
```

```
NAME      READY   UP-TO-DATE   AVAILABLE   AGE
azurite   1/1     1            1           30s
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

The `https` listener serves a self-signed certificate that `make local-up` generates in
`hack/local/.keys/`, so browsers show a security warning. For `curl`, pass the certificate:

```bash
curl --cacert hack/local/.keys/tls.crt https://grafana.localhost:8443/api/health
```

Azurite keeps its data on the `azurite-data` PVC, so a restarted or recreated pod comes
back with the stored data, and the sidecar creates any missing container again. No
`helm upgrade` is needed. `helm uninstall` and `make local-down` delete the data.
Set `localBlobStorage.azurite.persistence` to change the volume size or StorageClass.

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
