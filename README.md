<p align="center">

  # Observability Platform

</p>

<div align="center">

  [![CircleCI](https://dl.circleci.com/status-badge/img/gh/giantswarm/observability-platform/tree/main.svg?style=shield)](https://dl.circleci.com/status-badge/redirect/gh/giantswarm/observability-platform/tree/main)
  [![GitHub Release](https://img.shields.io/github/v/release/giantswarm/observability-platform)](https://github.com/giantswarm/observability-platform/releases/latest)
  [![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/giantswarm/observability-platform/badge)](https://scorecard.dev/viewer/?uri=github.com/giantswarm/observability-platform)

</div>

[Guide about how to manage an app on Giant Swarm](https://handbook.giantswarm.io/docs/dev-and-releng/app-developer-processes/adding_app_to_appcatalog/)

# observability-platform chart

Giant Swarm offers a observability-platform App which can be installed in workload clusters.
Here, we define the observability-platform chart with its templates and default configuration.

**Work in progress.** Tracked internally in [giantswarm/giantswarm#36783](https://github.com/giantswarm/giantswarm/issues/36783),
part of the Standalone Observability Platform epic ([#36346](https://github.com/giantswarm/giantswarm/issues/36346)).

**What is this app?**

A self-hosted observability stack packaged as a single umbrella chart: Mimir for metrics, Loki for
logs, Grafana to look at them, `observability-operator` to manage organizations, datasources and
dashboards, and Alloy to collect the platform's own telemetry. Tempo, the observability platform API
and Alertmanager ship with the chart but are disabled by default.

**Why did we add it?**

To offer the Giant Swarm observability stack as a runtime-independent, self-hosted product: one
`helm install` on any Kubernetes cluster, configured in a handful of lines rather than the ~300 a custom setup made from multiple independent charts would require.

**Who can use it?**

Anyone with a Kubernetes cluster and object storage. It does not require a Giant Swarm management
cluster.

## Installing

There are several ways to install this app onto a workload cluster.

- [Using GitOps to instantiate the App](https://docs.giantswarm.io/tutorials/continuous-deployment/apps/add-appcr/)
- By creating an [App resource](https://docs.giantswarm.io/reference/platform-api/crd/apps.application.giantswarm.io) using the platform API as explained in [Getting started with App Platform](https://docs.giantswarm.io/tutorials/fleet-management/app-platform/).

On a standalone cluster the chart is installed directly with Helm.

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

- Azure Blob is the only supported object storage backend. On-premises installations have no storage
  story yet.
- One sizing profile, tuned for a small cluster. There is no answer yet for real ingest volume.
- Exposing Grafana is the customer's responsibility — the chart creates no ingress and no TLS.
- Turning Mimir or Loki off leaves Grafana with a datasource pointing at nothing.
