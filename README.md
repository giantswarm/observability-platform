<div align="center">

  # Observability Platform

</div>

<div align="center">

  [![CircleCI](https://dl.circleci.com/status-badge/img/gh/giantswarm/observability-platform/tree/main.svg?style=shield)](https://dl.circleci.com/status-badge/redirect/gh/giantswarm/observability-platform/tree/main)
  [![GitHub Release](https://img.shields.io/github/v/release/giantswarm/observability-platform)](https://github.com/giantswarm/observability-platform/releases/latest)
  [![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/giantswarm/observability-platform/badge)](https://scorecard.dev/viewer/?uri=github.com/giantswarm/observability-platform)

</div>

Giant Swarm offers a observability-platform App which can be installed in workload clusters.
Here, we define the observability-platform chart with its templates and default configuration.

**Work in progress.** This chart is under active development and its interface may still change.

**What is this app?**

A self-hosted observability stack packaged as an umbrella chart: Mimir for metrics, Loki for
logs, and Grafana to look at them. The `observability-operator`, installed as its own release next to
it, manages organizations, datasources and dashboards. Tempo, the observability platform API
and Alertmanager ship with the chart but are disabled by default.

**Why did we add it?**

To offer the Giant Swarm Observability Platform as a self-hosted observability stack: one
`helm install` on any Kubernetes cluster, configured in a handful of lines rather than the ~300 a custom setup made from multiple independent charts would require.

**Who can use it?**

Anyone with a Kubernetes cluster and object storage. It does not require a Giant Swarm management
cluster.

**Known limitations of the observability-operator with this chart**

- The observability-operator is a separate release that must be installed before this chart, with
  [`values/observability-operator.yaml`](values/observability-operator.yaml). See [Installing](#installing).
- The release installs into the `monitoring` namespace while `observabilityOperator.enabled` is on.
  The operator rebuilds Grafana organizations and dashboards after a Grafana restart only there, so
  the render fails in any other namespace.
- The operator values must agree with this chart's: `tracing.enabled` with `tempo.enabled`,
  `defaultTenant` with `global.tenant`, and the Grafana and datasource URLs with the `monitoring`
  namespace. Nothing checks this across the two releases.
- The operator's admission webhooks are disabled, so mistakes in `GrafanaOrganization` resources or
  dashboard ConfigMaps show up only in the operator's logs and the resources' status.
- Disabling Loki or Mimir leaves their datasources in Grafana, pointing at nothing.

## Installing

There are several ways to install this app onto a workload cluster.

- [Using GitOps to instantiate the App](https://docs.giantswarm.io/tutorials/continuous-deployment/apps/add-appcr/)
- By creating an [App resource](https://docs.giantswarm.io/reference/platform-api/crd/apps.application.giantswarm.io) using the platform API as explained in [Getting started with App Platform](https://docs.giantswarm.io/tutorials/fleet-management/app-platform/).

On a standalone cluster, install two releases with Helm, the observability-operator first. It
installs the CRDs this chart's resources need:

```bash
helm install observability-operator observability-operator \
  --repo https://giantswarm.github.io/control-plane-catalog/ \
  --namespace monitoring --create-namespace \
  --values values/observability-operator.yaml
helm install observability-platform helm/observability-platform --namespace monitoring
```

Uninstall in the opposite order: the platform first, then the operator.

## Configuring

### values.yaml

**This is an example of a values file you could upload using our web interface.**

```yaml
# values.yaml

```

### Sample App CR and ConfigMap for the management cluster

If you have access to the Kubernetes API on the management cluster, you could create the App CR and ConfigMap directly.

Here is an example that would install the app to workload cluster `abc12`:

```yaml
# appCR.yaml

```

```yaml
# user-values-configmap.yaml

```

See our [full reference on how to configure apps](https://docs.giantswarm.io/tutorials/fleet-management/app-platform/app-configuration/) for more details.

## Compatibility

This app has been tested to work with the following workload cluster release versions:

- _add release version_

Standalone, it has been installed and verified on a vanilla EKS cluster.

## Limitations

Some apps have restrictions on how they can be deployed.
Not following these limitations will most likely result in a broken deployment.

- Azure Blob is the only supported object storage backend for now. For development,
  `localBlobStorage.enabled` runs the Azurite emulator in-cluster instead of a real
  storage account — see [doc/LOCAL_DEV.md](doc/LOCAL_DEV.md).
- One sizing profile, tuned for a small cluster. There is no answer yet for real ingest volume.
- The chart creates no Gateway and no TLS certificate. The external API and Grafana are
  exposed over HTTPS on a Gateway you provide, and you must set the name and namespace of that
  Gateway in each component's `parentRefs`. The external API also needs Envoy Gateway and an
  OIDC issuer installed beforehand — see [doc/EXTERNAL_API.md](doc/EXTERNAL_API.md).
- Turning Mimir or Loki off leaves Grafana with a datasource pointing at nothing.
