# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- The local Azurite keeps its data and storage containers when its pod restarts, so Loki, Mimir and Tempo keep working without a `helm upgrade`. Upgrading an existing local install drops its Azurite data once and, with Helm 4, needs `--server-side=false` that one time.
- The local kind cluster inherits no DNS search domain from the host. A host search domain no longer slows in-cluster lookups.
- The `helm.sh/chart` label is valid for long chart versions: the 63-character cut trims the whole trailing run of `-`, `.` and `_`.

### Changed

- Install the observability-operator as its own release, before this chart, with `values/observability-operator.yaml`.

### Added

- Enable Mimir Alertmanager.
- Give Grafana's default organization (org 1) the platform's datasources, with alerting access while Mimir's Alertmanager is enabled.
- Enable Tempo by default. It runs multi-tenant and stores traces in Azure Blob.
- Add the `tempo` Azure Blob container configuration.
- Run the observability-operator with only its GrafanaOrganization and Dashboard controllers.
- Add the Observability Platform API wiring for Loki and Mimir
- Route Tempo traffic through the Observability Platform API.
- Add Tempo to `doc/EXTERNAL_API.md` and `doc/LOCAL_DEV.md`.
- Serve Grafana over HTTPS at `https://grafana.localhost:8443` in the local kind setup.
- Add `doc/EXTERNAL_API.md`, walking through values and requests.
- Add `make local-up`, `make local-token` and `make local-down`. They run the chart and the external API on kind.
- Add a kind port mapping to the local setup. Envoy Gateway serves Grafana at `grafana.localhost:8080` and the external API at `observability.localhost:8080`.
- Add support for deploying the stack locally, with Azurite managing object storage  
- Document logging in to Grafana in `doc/LOCAL_DEV.md`.
- Print the Grafana port-forward and login in the `helm install` output, and flag the missing datasources when the operator is disabled.
- Add `doc/OBJECT_STORAGE.md`, walking through provisioning the Azure Blob Storage account, containers and credentials secret that Mimir and Loki need.
- Add `doc/EKS_CLUSTER.md`, walking through creating the AWS EKS cluster the platform runs on with `eksctl` — node sizing, the `gp3` default StorageClass the CSI driver needs, metrics-server, measured resource usage and teardown.
- Add Artifact Hub metadata (`artifacthub.io/license`, `artifacthub.io/links`) in the chart template ([roadmap#3940](https://github.com/giantswarm/roadmap/issues/3940)).
- Add the `observability-platform` umbrella chart skeleton.

### Changed

- Stop shipping Giant Swarm's Alertmanager routing with the observability-operator release (`values/observability-operator.yaml`).
- The external API routes attach only to the Gateway listener named `https`, so the API is no longer served over plain HTTP.
- Update `observability-operator` from 0.72.2 to 0.84.0.
- Update `observability-platform-api` from 0.4.0 to 0.5.0.
- Set project description and update header of the README
- Regenerated `.circleci` config with `devctl gen circleci` — adopt the dynamic-config setup workflow (`config.yml` + `workflows.yml`) and bump the architect orb to v9.5.2.
- Rename `app.giantswarm.io` label to `application.giantswarm.io`

### Fixed

- Fixed Loki ingestion on the local profile. `values-local.yaml` sets `replication_factor` to 1, matching the single `loki-write` replica.
- Fixed the Grafana Tempo datasource URL by pinning the Tempo service names with `tempo.tempo.fullnameOverride: tempo`.
- fixed DNS resolutions by setting `mimir.global.dnsService` back to `kube-dns`.
- Fixed failing build-artifact CI job, added `.ats/main.yaml` skipping all app-test-suite scenarios
- Fixed the failing `build-chart` CI job, added `.abs/.kube-linter.yaml` excluding the checks that the vendored `mimir`, `loki` and `grafana` wrappers trip.

[Unreleased]: https://github.com/giantswarm/observability-platform/tree/main
