# Local development

The platform needs object storage, and Azure Blob is the only backend it supports - so by
default `helm install` needs a real Azure storage account, provisioned as
[doc/OBJECT_STORAGE.md](./OBJECT_STORAGE.md) describes.

`localBlobStorage.enabled` replaces that account with
[Azurite](https://github.com/Azure/Azurite), Microsoft's Azure Storage emulator, running
in the cluster beside the platform. Azurite speaks the real Blob API, so Mimir and Loki
run against it unmodified, and the chart delivers its endpoint through the same
ConfigMap-and-Secret path it uses in production. Nothing about it is suitable for anything
but development.

## What you get

Turning it on adds four objects to the release:

| Object                                          | Purpose                                                    |
| ----------------------------------------------- | ---------------------------------------------------------- |
| Deployment `azurite`                            | The emulator, blob service only, on port 10000 over plain HTTP |
| Service `azurite`                               | The endpoint named in the connection string                |
| Secret `observability-platform-object-storage`  | The credentials Secret, with an empty key - see [Why the key is empty](#why-the-key-is-empty) |
| Job `azurite-init`                              | Creates the four containers, which Azurite does not create itself |

and points Mimir and Loki at the emulator with a connection string the chart computes:

```
DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=<well-known key>;BlobEndpoint=http://azurite.<namespace>.svc.cluster.local:10000/devstoreaccount1;
```

The account and key are Azurite's
[well-known development credentials](https://learn.microsoft.com/azure/storage/common/storage-connect-azurite#use-a-well-known-storage-account-and-key)
- public, fixed constants, not secrets.

## Limitations

- **No persistence.** Azurite's data directory is an `emptyDir`. Restart the pod and every
  block, chunk and index is gone. The platform recovers, but the data does not.
- **Plain HTTP, no isolation.** Anything in the cluster that can reach the Service can read
  and write every container, with a key that is published in Microsoft's documentation.
- **Not a fidelity test.** Azurite implements no lifecycle management, no access tiers and
  no immutability, so retention, tiering and compaction-against-real-storage behaviour
  cannot be validated here. It answers "does the wiring work", not "does it work in
  production".
- **One node's worth of load.** Azurite makes no performance guarantees and does not
  handle many concurrent clients. It is fine for a canary's worth of ingest.

## Prerequisites

- A cluster - [kind](https://kind.sigs.k8s.io/) is enough
- `helm` and `kubectl`
- No Azure account, no credentials, no `az` login

## Install

```bash
kind create cluster
kubectl create namespace monitoring
```

The namespace has to be `monitoring`: the operator's Grafana URL and datasource URLs are
literals in `values.yaml` that name it, and `templates/operator-namespace.yaml` fails the
render rather than installing an operator that talks to nothing.

```bash
helm dependency update helm/observability-platform

helm install observability-platform helm/observability-platform \
  --namespace monitoring \
  --values helm/observability-platform/values-local.yaml \
  --set localBlobStorage.enabled=true \
  --set observabilityOperator.enabled=false
```

`localBlobStorage.enabled` computes both the account name and the connection string, so
setting `global.objectStorage.azure.accountName` or
`global.objectStorage.azure.connectionString` beside it fails the render rather than being
silently ignored. It does not need the Secret from Step 4 of
[doc/OBJECT_STORAGE.md](./OBJECT_STORAGE.md) - it creates that itself.

`observabilityOperator.enabled=false` is unrelated to storage: the operator's chart emits a
`PodMonitor` with no guard, so it needs the Prometheus Operator CRDs present. See the note
on issue 15 in `values.yaml`.

## The local sizing profile

`values-local.yaml` is what makes the release fit on one node. The default profile asks for
**36 Gi of memory across 21 workloads**; this brings it to **5 Gi**, measured on a kind node
that then reported 17% of its memory committed. Without it most of the second replicas never
leave `Pending` with `Insufficient memory`.

It is a separate values file rather than part of `localBlobStorage.enabled` for the same
reason the storage parameters travel through a ConfigMap: replicas and resources are
subchart values, and Helm will not let this chart compute those. A values file is the only
thing that can reach them - which is also how mimir-distributed ships its own `small.yaml`
and `large.yaml`.

What it does, and the two rules it keeps so that it stays a sizing change and nothing more:

- Turns off Loki's `chunksCache` and `resultsCache`. They are **11 Gi of the 36** between
  them. Loki runs without them; queries are just slower.
- Takes every component to a single replica, turning the wrappers' HPAs off rather than
  lowering `minReplicas`, so a dev cluster has a fixed and predictable set of pods.
- **Lowers only `requests`, never `limits`.** Scheduling was the problem and requests are
  what the scheduler reads, so nothing here is more likely to be OOMKilled than it was on
  the default profile.
- **Keeps all three Mimir ingester and store-gateway zones.** One replica per zone is what
  Mimir's replication factor of 3 needs; collapsing the zones would change replication
  behaviour rather than sizing.

It has no headroom for ingest. Do not use it anywhere real.

## Verify

The container-creating Job runs as a `post-install` hook, so `helm install` does not
return until it has finished:

```bash
kubectl get job azurite-init -n monitoring
```

```
NAME           STATUS     COMPLETIONS   DURATION   AGE
azurite-init   Complete   1/1           14s        30s
```

Its log names each container it created:

```bash
kubectl logs -n monitoring job/azurite-init
```

```
waiting for azurite
creating container mimir-blocks
creating container mimir-alertmanager
creating container mimir-ruler
creating container loki
done
```

Then watch Mimir and Loki come up:

```bash
kubectl get pods -n monitoring
```

Both may restart once or twice before the Job finishes - the components are created at the
same time as the emulator, so the first attempts hit `connection refused` against a
Service with no endpoints yet. What matters is that they settle. Two failures are *not*
transient, and both mean the storage wiring is wrong rather than slow:

- `storage_account_key and storage_connection_string cannot both be set` - the credentials
  Secret has a non-empty `AZURE_STORAGE_KEY`. See below.
- `ContainerNotFound` still appearing after `azurite-init` completed - the containers were
  created under names the components do not read.

To look at the data, run the CLI against the emulator with the connection string from the
ConfigMap:

```bash
CONN=$(kubectl get configmap observability-platform-object-storage -n monitoring \
  -o jsonpath='{.data.OBS_AZURE_CONNECTION_STRING}')

kubectl run azcli --rm -it --restart=Never -n monitoring \
  --image=mcr.microsoft.com/azure-cli:2.90.0 -- \
  az storage blob list -c mimir-blocks --connection-string "$CONN" -o table
```

What proves the wiring works is the cluster seed each component writes at startup:
`__mimir_cluster/mimir_cluster_seed.json` in `mimir-blocks`, and `loki_cluster_seed.json`
in `loki`. Both appear within a minute of the component becoming ready, and both are a
full authenticated round-trip through the Blob API.

Do not read an otherwise-empty container as a failure. Mimir uploads TSDB blocks only once
a block range closes, two hours by default; Loki flushes chunks only once something ships
it logs, and nothing in this chart does. `mimir-alertmanager` and `mimir-ruler` stay empty
until an Alertmanager config or a rule group exists.

Finally, look at it through Grafana:

```bash
kubectl port-forward -n monitoring svc/grafana 3000:80
```

## Failures that are not storage

With `values-local.yaml` and the two `--set` flags above, a one-node kind cluster comes up
clean: 21 pods Running, the init Job Complete, nothing Pending. What follows is what goes
wrong when one of those is left off, and none of it is the emulator's doing.

| Symptom                                                          | Cause                                                                                       | Handled by |
| ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------- | ---------- |
| Second replicas of `loki-backend`, `loki-write`, `loki-read`, `loki-gateway` `Pending` | `Insufficient memory` — the default profile requests 36 Gi | `values-local.yaml` |
| `mimir-gateway` in `CrashLoopBackOff` with `host not found in resolver` | The wrapper defaults `global.dnsService` to `coredns`, the Service name on a Giant Swarm installation | `values.yaml`, unconditionally — `kube-dns` |
| Operator's `PodMonitor` fails the install                        | Emitted with no guard, so it needs the Prometheus Operator CRDs                              | `observabilityOperator.enabled=false` |

One of that class is left: Tempo's wrapper carries the same `coredns` default with no
override. It is disabled by default, so expect its gateway to fail the same way as Mimir's
did if you turn it on.

## Why the key is empty

The Secret the chart creates here holds `AZURE_STORAGE_KEY: ""`, which looks like a
mistake and is not. Two constraints meet:

- Mimir's storage client **refuses an account key and a connection string together** - the
  underlying Thanos objstore fails validation with `storage_account_key and
  storage_connection_string cannot both be set`. The emulator is only reachable through a
  connection string, so the key has to go.
- The Secret still has to **exist**. Mimir's and Loki's `extraEnvFrom` name it without
  `optional`, and those are static subchart values that Helm will not let this chart
  compute, so they cannot be switched off per install. A missing Secret leaves every Mimir
  and Loki pod in `CreateContainerConfigError`.

Present and empty is the only state that satisfies both. The emulator's key reaches the
components inside the connection string instead.

## Teardown

```bash
helm uninstall observability-platform -n monitoring
kind delete cluster
```

Uninstalling leaves the completed `azurite-init` Job behind, so its log stays readable; the
next install deletes it before creating its replacement.
