# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

- added: Artifact Hub metadata (`artifacthub.io/license`, `artifacthub.io/links`) in the chart template ([roadmap#3940](https://github.com/giantswarm/roadmap/issues/3940)).
- added: `doc/OBJECT_STORAGE.md`, walking through provisioning the Azure Blob Storage account, containers and credentials secret that Mimir and Loki need.

- changed: Regenerated `.circleci` config with `devctl gen circleci` — adopt the dynamic-config setup workflow (`config.yml` + `workflows.yml`) and bump the architect orb to v9.5.2.
- changed: `app.giantswarm.io` label group was changed to `application.giantswarm.io`

- fixed: Added `.ats/main.yaml` skipping all app-test-suite scenarios, so the `execute-chart-tests` job no longer fails on an unset `--smoke-tests-cluster-type`. The chart has no `tests/ats` suite yet.

[Unreleased]: https://github.com/giantswarm/observability-platform/tree/main
