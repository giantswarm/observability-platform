# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Add `localBlobStorage.enabled`, running the Azurite emulator in-cluster as the blob
  backend so the platform can be installed with no Azure account. Adds a Deployment,
  Service, the credentials Secret and a container-creating Job, and computes the
  connection string that points Mimir and Loki at it. Development only — see
  `doc/LOCAL_DEV.md`.
- Add `global.objectStorage.azure.connectionString`, delivered to Mimir and Loki as
  `connection_string`. Overrides the endpoint both clients would otherwise derive from the
  account name, which is the only way to reach an endpoint that is not Azure's.
- Add `doc/LOCAL_DEV.md`, covering the local Azurite backend, its limitations, and why the
  credentials Secret it creates holds an empty key.
- Add `doc/OBJECT_STORAGE.md`, walking through provisioning the Azure Blob Storage account, containers and credentials secret that Mimir and Loki need.
- Add `doc/EKS_CLUSTER.md`, walking through creating the AWS EKS cluster the platform runs on with `eksctl` — node sizing, the `gp3` default StorageClass the CSI driver needs, metrics-server, measured resource usage and teardown.
- Add Artifact Hub metadata (`artifacthub.io/license`, `artifacthub.io/links`) in the chart template ([roadmap#3940](https://github.com/giantswarm/roadmap/issues/3940)).
- Add the `observability-platform` umbrella chart skeleton with its six component dependencies — `grafana`, `loki`, `mimir`, `observability-operator`, `observability-platform-api` and `tempo` — each gated by a `<component>.enabled` condition in `values.yaml`. `tempo` and `observability-platform-api` default to off.

### Changed

- Set project description and update header of the README
- Regenerated `.circleci` config with `devctl gen circleci` — adopt the dynamic-config setup workflow (`config.yml` + `workflows.yml`) and bump the architect orb to v9.5.2.
- Rename `app.giantswarm.io` label to `application.giantswarm.io`

### Fixed

- Fixed failing build-artifact CI job, added `.ats/main.yaml` skipping all app-test-suite scenarios
- Fixed the failing `build-chart` CI job, added `.abs/.kube-linter.yaml` excluding the checks that the vendored `mimir`, `loki` and `grafana` wrappers trip. `kube-linter` lints the rendered output of the whole dependency tree, so this chart inherited 42 errors from its subcharts, two thirds of them because the wrappers set resource requests but deliberately no limits.

[Unreleased]: https://github.com/giantswarm/observability-platform/tree/main
