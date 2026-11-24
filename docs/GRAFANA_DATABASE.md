# Grafana database

By default the chart runs Grafana's database on a [CloudNativePG](https://cloudnative-pg.io/)
(CNPG) cluster named `grafana-postgresql`, so Grafana's users, dashboards and folders, alert
rules, service accounts, preferences and annotations survive restarts:

- **Two instances on persistent volumes.** A primary and a streaming replica, so losing a node
  or a volume fails over.
- **Two prerequisites:** the CNPG operator release and the Secret `grafana-secret-key`.
- **Backups are opt-in.** With them on, the database is backed up hourly to the platform's
  `s3` object storage (see [Backups](#backups)). With them off, the replica is the only copy of
  the data.

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

## Backups

With backups on, the [barman-cloud plugin](https://github.com/cloudnative-pg/plugin-barman-cloud)
backs up Grafana's database to the platform's object storage:

- **What:** a base backup every hour and continuous WAL archiving, kept for 30 days. Every one
  of these defaults can be overridden under `grafana.postgresqlCluster.backup`.
- **Where:** the bucket `global.objectStorage.buckets.grafanaPostgresql` (default
  `grafana-postgresql`). Create it like the platform's other buckets (see
  [OBJECT_STORAGE.md](./OBJECT_STORAGE.md)).
- **Credentials:** the platform's credentials Secret, `observability-platform-object-storage`,
  unless you set dedicated ones (see [Dedicated credentials](#dedicated-credentials)).

Backups support the `s3` backend only, AWS S3 or an S3-compatible store.

### Enable backups

1. Install [cert-manager](https://cert-manager.io/). The plugin and the CNPG operator talk
   over mTLS, and the plugin chart has cert-manager issue both certificates from a self-signed
   `Issuer` it creates in `monitoring`. That Issuer is named `letsencrypt-giantswarm` for
   historical reasons; it is not Let's Encrypt. [GATEWAY.md](./GATEWAY.md) installs
   cert-manager too.

2. Install the plugin release, in `monitoring` next to the CNPG operator:

   ```bash
   helm install plugin-barman-cloud plugin-barman-cloud \
     --repo https://giantswarm.github.io/control-plane-catalog/ --version 0.4.0 \
     --namespace monitoring \
     --values values/plugin-barman-cloud.yaml
   ```

3. Turn backups on in the Platform chart's values, and upgrade it:

   ```yaml
   grafana:
     postgresqlCluster:
       backup:
         enabled: true
   ```

The grafana subchart takes the store's endpoint, region, `insecure` and bucket from
`global.objectStorage`. On upgrade, CNPG restarts the PostgreSQL instances one at a time to add
the plugin.

The render fails with a pointer to this page when backups are on and:

- the backend isn't `s3`;
- Grafana's secret key doesn't come from the Secret `grafana-secret-key`. A restore needs the
  same key, so backups need it to be yours;
- on a live install, the cluster serves no `barmancloud.cnpg.io/v1` `ObjectStore`. Install the
  plugin release first.

### Dedicated credentials

By default, the PostgreSQL instances use the platform's keys, which can also write and delete
Mimir, Loki and Tempo data. In production, give backups their own keys, allowed only on the
`grafanaPostgresql` bucket, in a Secret in `monitoring`:

```yaml
grafana:
  postgresqlCluster:
    objectStorage:
      s3:
        existingSecret:
          name: grafana-backup-credentials
          accessKeyIdKey: AWS_ACCESS_KEY_ID
          secretAccessKeyKey: AWS_SECRET_ACCESS_KEY
```

### A store behind a private CA

Put the CA bundle in a Secret in `monitoring` and reference it:

```yaml
grafana:
  postgresqlCluster:
    objectStorage:
      s3:
        endpointCA:
          name: object-store-ca
          key: ca.crt
```

### Server-side encryption

For a store that supports it, encrypt base backups and WAL files with `AES256` or `aws:kms`.
Empty uses the bucket's policy:

```yaml
grafana:
  postgresqlCluster:
    backup:
      encryption:
        data: AES256
        wal: AES256
```

### Check that backups work

No alert watches backups by default: the PostgreSQL cluster's PodMonitor is off (see
[Monitoring](#monitoring)). Check them by hand:

```bash
kubectl get cluster.postgresql.cnpg.io grafana-postgresql -n monitoring \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'
kubectl get backup.postgresql.cnpg.io -n monitoring --sort-by=.metadata.creationTimestamp
```

- **Cluster conditions:** `ContinuousArchiving` and `LastBackupSucceeded` must be `True`.
- **Backups:** the hourly `Backup`s must reach phase `completed`.

Backups also stop when the plugin's mTLS certificates expire. cert-manager renews them, so check
that it does:

```bash
kubectl get certificate -n monitoring barman-cloud-server barman-cloud-client \
  -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,NOT_AFTER:.status.notAfter,RENEWAL:.status.renewalTime'
```

Both must be `Ready` (`True`), with `NOT_AFTER` in the future.

## Uninstall

> **Uninstalling the Platform chart, or switching it to SQLite, deletes the
> `grafana-postgresql` cluster, and CNPG deletes its volumes. Grafana's data is gone.** With
> backups on, the bucket keeps the backups.

Uninstall the plugin and the CNPG operator releases after the Platform chart.

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
