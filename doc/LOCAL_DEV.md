# Local development

Azure Blob is the only object storage backend this chart supports. By default
`helm install` needs a real storage account - see
[doc/OBJECT_STORAGE.md](./OBJECT_STORAGE.md).

`localBlobStorage.enabled` replaces it with [Azurite](https://github.com/Azure/Azurite),
Microsoft's Azure Storage emulator, running in the cluster.

## Prerequisites

- [kind](https://kind.sigs.k8s.io/), `helm`, `kubectl`
- Around 6 GiB of memory free
- Commands run from the repository root

## Install

```bash
kind create cluster
kubectl create namespace monitoring
```

The namespace must be `monitoring`. The operator's Grafana and datasource URLs name it
as literals, so any other namespace fails the render.

```bash
helm dependency update helm/observability-platform

helm install observability-platform helm/observability-platform \
  --namespace monitoring \
  --values helm/observability-platform/values-local.yaml \
  --set localBlobStorage.enabled=true \
  --set observabilityOperator.enabled=false
```

- `values-local.yaml` is a development sizing profile. It cuts memory requests from
  36 GiB to 5 GiB, so the release fits on one node.
- `observabilityOperator.enabled=false` keeps the operator out of the release. Its chart
  emits an unguarded `PodMonitor`, which needs the Prometheus Operator CRDs.
- `localBlobStorage.enabled` computes the account name and connection string. Setting
  `global.objectStorage.azure.accountName` or `connectionString` by hand fails the render.

## Verify

A `post-install` hook creates the storage containers, so `helm install` returns once it
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

Finally, open Grafana:

```bash
kubectl port-forward -n monitoring svc/grafana 3000:80
```

Storage lives in an `emptyDir`: restarting the emulator discards the data.

## Teardown

```bash
helm uninstall observability-platform -n monitoring
kind delete cluster
```
