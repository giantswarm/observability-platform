# Restore Grafana from a backup

This guide restores Grafana's PostgreSQL database from its backups (see
[GRAFANA_DATABASE.md](./GRAFANA_DATABASE.md#backups)): a dashboard, a folder or alert rules
deleted by mistake, or a lost cluster.

The restore replaces the `grafana-postgresql` cluster with a new one, recovered from the latest
base backup before a point in time, plus the archived WAL up to that point:

- **What's lost:** every change made after that point. Grafana is down while the new cluster
  recovers, a few minutes for a small database.
- **What comes back:** everything as it was at that point, including users, API keys and
  service-account tokens that were deleted or revoked since. Review them at the end (see
  [Review credentials](#7-review-credentials)).

## Before you start

- **Backups work.** At least one `Backup` completed before the point you restore to:

  ```bash
  kubectl get backup.postgresql.cnpg.io -n monitoring --sort-by=.metadata.creationTimestamp
  ```

- **Grafana's secret key is the same.** The Secret `grafana-secret-key` must still hold the key
  Grafana used when the backup was taken. Grafana encrypts datasource passwords, contact-point
  secrets and SSO client secrets with it; restored under another key, they can't be read. If
  the Secret is gone, recreate it from the copy you kept outside the cluster before you start.

- **Pick the point to restore to,** in UTC and RFC 3339, for example `2026-11-24T10:48:46Z`:
  after the end of a completed base backup, and before the mistake. Without one, the restore
  replays the whole WAL archive and brings back the latest state, mistakes included. Use that
  only for a lost cluster.

## 1. Choose the paths

The restore reads the backups from where they are now, and the new cluster writes its own
backups to a **new** path: it starts a new timeline, and barman refuses to archive it on top of
the old one.

| | Value |
| --- | --- |
| Read from | The current backup path: `s3://<bucket>/` by default, where `<bucket>` is `global.objectStorage.buckets.grafanaPostgresql`, or `grafana.postgresqlCluster.backup.destinationPath` if you set it, for example after an earlier restore. |
| Write to | A new path in the same bucket, for example `s3://<bucket>/restore-2026-11-24/`. |

## 2. Add the restore values

Add these values to the Platform chart's values, with your paths and point in time:

```yaml
grafana:
  postgresqlCluster:
    backup:
      # The new path. Keep it after the restore.
      destinationPath: s3://grafana-postgresql/restore-2026-11-24/
    recovery:
      enabled: true
      # The current backup path.
      destinationPath: s3://grafana-postgresql/
      # The point to restore to. Leave it out to restore the latest state.
      recoveryBackupTime: "2026-11-24T10:48:46Z"
```

Don't upgrade the release yet: CNPG recovers only when it creates the cluster.

## 3. Delete the cluster

> **This deletes the cluster and its volumes.** Everything after the point you restore to is
> lost. Grafana fails until the new cluster is up.

```bash
kubectl delete cluster.postgresql.cnpg.io grafana-postgresql -n monitoring --wait
```

## 4. Upgrade the release

Upgrade the Platform chart with the values from step 2, as you install it:

```bash
helm upgrade observability-platform helm/observability-platform --namespace monitoring \
  --values values.yaml
```

Helm recreates the cluster, and CNPG recovers it from the backups. With GitOps, apply the new
values only after step 3, or reconcile the release again after it: an upgrade that runs while
the old cluster exists changes nothing.

Wait for the new cluster:

```bash
kubectl wait cluster.postgresql.cnpg.io/grafana-postgresql -n monitoring \
  --for=condition=Ready --timeout=30m
```

## 5. Restart Grafana

The new cluster has a new password for Grafana's database user. Restart Grafana to read it:

```bash
kubectl rollout restart deployment/grafana -n monitoring
kubectl rollout status deployment/grafana -n monitoring
```

Check what you restored, for example the dashboard you deleted. Grafana's `/api/health` reports
`"database": "ok"`.

## 6. Turn recovery off

Remove `grafana.postgresqlCluster.recovery` from the values, keep the new
`backup.destinationPath`, and upgrade the release again:

```yaml
grafana:
  postgresqlCluster:
    backup:
      destinationPath: s3://grafana-postgresql/restore-2026-11-24/
```

The cluster keeps running. Left on, recovery would restore to the same point in time again the
next time the cluster is recreated.

Check that backups work on the new path (see
[Check that backups work](./GRAFANA_DATABASE.md#check-that-backups-work)). The old path keeps
the backups from before the restore until their retention ends.

## 7. Review credentials

The restore brings back Grafana's state at the point you restored to. Anything deleted or
revoked after it is back, and must be removed again:

- **Users** deleted since: *Administration › Users and access › Users*.
- **API keys and service-account tokens** revoked since: *Administration › Users and access ›
  Service accounts*. A token that was revoked because it leaked is valid again until you revoke
  it.
- **Datasources and contact points** whose secrets changed since: they have their old values.
  Rotate the secrets again.

Changes made after that point, such as new users, dashboards and alert rules, are gone. Recreate
them.
