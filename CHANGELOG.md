# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Add `localBlobStorage.enabled`, running the Azurite emulator in-cluster as the blob backend for development — see `doc/LOCAL_DEV.md`.
- Add `global.objectStorage.azure.connectionString`, delivered to Mimir and Loki as `connection_string`, which sets the blob endpoint they connect to.
- Add `values-local.yaml`, a development sizing profile taking the release from 36 Gi of memory requests down to 5 Gi so it fits on a single-node cluster.
- Add `doc/LOCAL_DEV.md`, covering the local Azurite backend, the sizing profile and their limitations.
- Add `doc/OBJECT_STORAGE.md`, walking through provisioning the Azure Blob Storage account, containers and credentials secret that Mimir and Loki need.
- Add `doc/EKS_CLUSTER.md`, walking through creating the AWS EKS cluster the platform runs on with `eksctl` — node sizing, the `gp3` default StorageClass the CSI driver needs, metrics-server, measured resource usage and teardown.
- Add Artifact Hub metadata (`artifacthub.io/license`, `artifacthub.io/links`) in the chart template ([roadmap#3940](https://github.com/giantswarm/roadmap/issues/3940)).
- Add the `observability-platform` umbrella chart skeleton.

### Changed

- Set project description and update header of the README
- Regenerated `.circleci` config with `devctl gen circleci` — adopt the dynamic-config setup workflow (`config.yml` + `workflows.yml`) and bump the architect orb to v9.5.2.
- Rename `app.giantswarm.io` label to `application.giantswarm.io`

### Fixed

- Set `mimir.global.dnsService` back to `kube-dns` — the wrapper's `coredns` is a Giant Swarm installation's DNS Service name, and left the Mimir gateway's nginx exiting with `host not found in resolver` on kind and EKS.
- Fixed failing build-artifact CI job, added `.ats/main.yaml` skipping all app-test-suite scenarios
- Fixed the failing `build-chart` CI job, added `.abs/.kube-linter.yaml` excluding the checks that the vendored `mimir`, `loki` and `grafana` wrappers trip.

[Unreleased]: https://github.com/giantswarm/observability-platform/tree/main
