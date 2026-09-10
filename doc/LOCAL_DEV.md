# Local development

Azure Blob is the only object storage backend this chart supports, so by default
`helm install` needs a real storage account - see
[doc/OBJECT_STORAGE.md](./OBJECT_STORAGE.md).

`localBlobStorage.enabled` replaces it with [Azurite](https://github.com/Azure/Azurite),
Microsoft's Azure Storage emulator, running in the cluster. Use it for development.

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
literals naming it, and the render fails on any other namespace.

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
- `observabilityOperator.enabled=false` keeps the operator out of the release. Its chart
  emits an unguarded `PodMonitor`, which needs the Prometheus Operator CRDs.

`localBlobStorage.enabled` computes the account name and the connection string. Setting
`global.objectStorage.azure.accountName` or `connectionString` by hand fails the render.

## Verify

A `post-install` hook creates the storage containers, so `helm install` returns once it has
finished:

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

Expect 21 Running. Mimir and Loki may restart once or twice first, while the emulator is
still starting. Two errors point at the storage wiring and need action:

- `storage_account_key and storage_connection_string cannot both be set` - the credentials
  Secret holds a non-empty `AZURE_STORAGE_KEY`. The chart creates it empty on purpose.
- `ContainerNotFound` after `azurite-init` completed - the container names differ from the
  ones the components read.

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

Data arrives on each component's own schedule. Mimir uploads blocks when a block range
closes, two hours by default. Loki flushes chunks once something ships it logs. Containers
hold the seed alone until then.

Finally, open Grafana:

```bash
kubectl port-forward -n monitoring svc/grafana 3000:80
```

## Limits

- **Storage lives in an `emptyDir`.** Restarting the emulator discards the data.
- **Azurite implements the Blob API.** Retention, tiering and immutability behaviour needs a
  real storage account to validate.
- **The sizing profile suits a canary's worth of ingest.**

## Teardown

```bash
helm uninstall observability-platform -n monitoring
kind delete cluster
```
