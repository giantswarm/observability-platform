# Send data with Alloy

[Grafana Alloy](https://grafana.com/docs/alloy/latest/) runs in the kind cluster and
pushes to the in-cluster gateways:

- Metrics go to `mimir-gateway`.
- Logs go to `loki-gateway`.

## Prerequisites

- The local stack from [doc/LOCAL_DEV.md](./LOCAL_DEV.md), running
- Commands run from the repository root

## Install

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update grafana
```

The Alloy config lives in [doc/examples/alloy/config.alloy](./examples/alloy/config.alloy).
Edit it to tune what Alloy collects.

```bash
helm install alloy grafana/alloy \
  --namespace monitoring \
  --skip-crds \
  --set-file alloy.configMap.content=doc/examples/alloy/config.alloy
```

`--skip-crds`: the platform already installs the `PodLogs` CRD that the Alloy chart ships.
Drop the flag when you install Alloy on a cluster without the platform.

## Verify

```bash
kubectl get pods -n monitoring -l app.kubernetes.io/name=alloy
```

Open Grafana with the Mimir and Loki datasources (see [doc/LOCAL_DEV.md](./LOCAL_DEV.md)):

- Drilldown → Metrics: the `alloy_*` metrics are listed.
- Drilldown → Logs: the `monitoring` namespace lists its pods.

## Apply config changes

```bash
helm upgrade alloy grafana/alloy \
  --namespace monitoring \
  --set-file alloy.configMap.content=doc/examples/alloy/config.alloy
```

## Not supported yet

- Agents outside the cluster: the chart ships no endpoint for them, and no `AgentCredential`
  CRD to authenticate them.

## Teardown

```bash
helm uninstall alloy -n monitoring
```
