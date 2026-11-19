# Grafana database

By default the chart runs Grafana's database on a [CloudNativePG](https://cloudnative-pg.io/)
(CNPG) cluster named `grafana-postgresql`, so Grafana's users, dashboards and folders, alert
rules, service accounts, preferences and annotations survive restarts:

- **Two instances on persistent volumes.** A primary and a streaming replica, so losing a node
  or a volume fails over.
- **Two prerequisites:** the CNPG operator release and the Secret `grafana-secret-key`.
- **No backups yet.** Backups to object storage are planned. Until then, the replica is the only
  copy of the data.

To skip both prerequisites, keep Grafana on SQLite inside its pod instead (see
[Keep Grafana on SQLite](#keep-grafana-on-sqlite)). A restart then loses everything the
observability-operator does not re-create.

## Prerequisites

Both in the `monitoring` namespace:

- **The CNPG operator release**, installed before the Platform chart (see [Install](#install)).
  It installs the CNPG CRDs. Tested with the `cloudnative-pg` chart 0.1.0 from the
  control-plane-catalog, which runs CNPG operator 1.29.1.
- **The Secret `grafana-secret-key`**, key `secret-key`, holding Grafana's secret key (see
  [The secret key](#the-secret-key)).

### A cluster that already runs CNPG

The CNPG CRDs are cluster-scoped, and two CNPG operators on one cluster conflict. If the cluster
already runs a CNPG operator, skip the operator release:

- The existing operator must watch `monitoring`.
- It must be in the tested version range above.

## Install

1. Install the CNPG operator release:

   ```bash
   helm install cloudnative-pg cloudnative-pg \
     --repo https://giantswarm.github.io/control-plane-catalog/ --version 0.1.0 \
     --namespace monitoring --create-namespace \
     --values values/cloudnative-pg.yaml
   ```

   `values/cloudnative-pg.yaml` runs the operator namespaced: it watches only `monitoring` and
   reads Secrets through a Role there, not a ClusterRole. It also turns off the Giant Swarm
   management-cluster pieces: the Cilium policy, the VPA, the PodMonitor and the dashboard.

2. Create the secret key once:

   ```bash
   kubectl create secret generic grafana-secret-key -n monitoring \
     --from-literal=secret-key="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
   ```

3. Install the observability-operator release and the Platform chart as in the
   [installation guide](./INSTALL.md).

On a first install, Grafana restarts until the database is ready, usually for a minute or two.

On a live install or upgrade, the render fails while the cluster serves no CNPG `Cluster`, or
while the Secret `grafana-secret-key` is missing. `helm template`, which talks to no cluster,
skips both checks and renders the PostgreSQL resources:

```text
grafana.postgresqlCluster.enabled is true but the cluster serves no postgresql.cnpg.io/v1 Cluster. Install the CNPG operator release first, with values/cloudnative-pg.yaml, or keep Grafana on SQLite - see docs/GRAFANA_DATABASE.md.
grafana.postgresqlCluster.enabled is true but the Secret grafana-secret-key is missing. Create it first, or keep Grafana on SQLite - see docs/GRAFANA_DATABASE.md.
```

## The secret key

Grafana encrypts the secrets it stores in its database with its secret key:

- datasource passwords;
- alerting contact points, such as Slack webhooks and PagerDuty keys;
- SSO client secrets.

Grafana's built-in key is public. The chart replaces it with the key in `grafana-secret-key`.

- **Keep a copy outside the cluster.** A database restored without the same key has secrets
  Grafana can't read.
- **Never change the key on a running install,** for the same reason.

## Connection

The chart points Grafana at the read-write Service `grafana-postgresql-rw:5432`:

- **Database and user:** `app`.
- **Password:** read from the Secret `grafana-postgresql-app`, which CNPG creates.
- **TLS:** `ssl_mode: require`. CNPG serves TLS but also accepts plain connections, and the
  chart creates no NetworkPolicy.

Grafana stays at one replica.

## Upgrading from SQLite

Earlier releases kept Grafana on SQLite. Before upgrading, install the CNPG operator release and
create `grafana-secret-key` (see [Install](#install)), or keep Grafana on SQLite. After the
upgrade, Grafana starts on PostgreSQL with an empty database.

- **Re-created:** the observability-operator re-creates the organizations, the datasources and
  the provisioned dashboards.
- **Lost:** everything made by hand in the SQLite database. It is not migrated.

## Uninstall

> **Uninstalling the Platform chart, or switching it to SQLite, deletes the
> `grafana-postgresql` cluster, and CNPG deletes its volumes. Grafana's data is gone.**

Uninstall the CNPG operator release after the Platform chart.

## Monitoring

The chart turns off the cluster's `PodMonitor`: it needs the Prometheus Operator CRDs. On a
cluster that has them, turn it on:

```yaml
grafana:
  postgresqlCluster:
    podMonitor:
      enabled: true
```

## Keep Grafana on SQLite

To run without CNPG and without `grafana-secret-key`, set these values on the Platform chart:

```yaml
grafana:
  postgresqlCluster:
    enabled: false
  grafana:
    grafana.ini:
      database: null
    envValueFrom: null
```

- **`envValueFrom: null` clears the whole map.** Setting its two keys,
  `GF_DATABASE_PASSWORD` and `GF_SECURITY_SECRET_KEY`, to `null` instead still renders them,
  with an empty value. A later values file that sets `envValueFrom` brings both back. Pass
  environment variables of your own through `grafana.grafana.env` or
  `grafana.grafana.envFromSecrets` instead.
- **Grafana falls back to its public secret key** and to SQLite inside its pod. A restart loses
  everything the observability-operator does not re-create.
