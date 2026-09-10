# Local development

Azure Blob is the only object storage backend this chart supports, so by default
`helm install` needs a real storage account - see
[doc/OBJECT_STORAGE.md](./OBJECT_STORAGE.md).

`localBlobStorage.enabled` replaces it with [Azurite](https://github.com/Azure/Azurite),
Microsoft's Azure Storage emulator, running in the cluster. No Azure account, no
credentials. Development only.

## Prerequisites

- [kind](https://kind.sigs.k8s.io/), `helm`, `kubectl`
- Around 6 GiB of memory free for the cluster
- Commands below run from the repository root

## Install

```bash
kind create cluster
kubectl create namespace monitoring
```

The namespace must be `monitoring`. The operator's Grafana and datasource URLs are
literals naming it, and the render fails otherwise.

```bash
helm dependency update helm/observability-platform

helm install observability-platform helm/observability-platform \
  --namespace monitoring \
  --values helm/observability-platform/values-local.yaml \
  --set localBlobStorage.enabled=true \
  --set observabilityOperator.enabled=false
```

- `values-local.yaml` is a development sizing profile. It takes the release from 36 GiB of
  memory requests to 5 GiB, so it fits on one node.
- `observabilityOperator.enabled=false` is unrelated to storage. The operator's chart emits
  an unguarded `PodMonitor`, which needs the Prometheus Operator CRDs.

Do not set `global.objectStorage.azure.accountName` or `connectionString` as well.
`localBlobStorage.enabled` computes both, and setting either fails the render.

## Verify

A `post-install` hook creates the storage containers, so `helm install` does not return
until it has finished:

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

Expect 21 Running and nothing Pending. Mimir and Loki may restart once or twice first,
while the emulator is still starting. Two errors are not transient:

- `storage_account_key and storage_connection_string cannot both be set` - the credentials
  Secret has a non-empty `AZURE_STORAGE_KEY`. The chart creates it empty on purpose.
- `ContainerNotFound` after `azurite-init` completed - the container names do not match
  what the components read.

To see the stored data, run the CLI against the emulator:

```bash
CONN=$(kubectl get configmap observability-platform-object-storage -n monitoring \
  -o jsonpath='{.data.OBS_AZURE_CONNECTION_STRING}')

kubectl run azcli --rm -it --restart=Never -n monitoring \
  --image=mcr.microsoft.com/azure-cli:2.90.0 -- \
  az storage blob list -c mimir-blocks --connection-string "$CONN" -o table
```

Each component writes a cluster seed at startup - `__mimir_cluster/mimir_cluster_seed.json`
in `mimir-blocks`, `loki_cluster_seed.json` in `loki`. That is the proof the wiring works.

An otherwise-empty container is normal. Mimir uploads blocks only when a block range
closes, two hours by default. Loki flushes chunks only once something ships it logs, and
nothing here does.

Finally, open Grafana:

```bash
kubectl port-forward -n monitoring svc/grafana 3000:80
```

## Limits

- **No persistence.** The emulator's data directory is an `emptyDir`. Restart the pod and
  the data is gone.
- **Not a fidelity test.** Azurite has no lifecycle management, access tiers or
  immutability, so retention and tiering cannot be validated here.
- **No headroom.** The sizing profile is enough for a canary's worth of ingest, nothing
  more.

## Teardown

```bash
helm uninstall observability-platform -n monitoring
kind delete cluster
```
