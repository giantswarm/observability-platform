# Alerting

The Mimir ruler sends alerts to Mimir Alertmanager. Alertmanager routes them to your receivers.

Each tenant has one Alertmanager config. A tenant without a config uses the fallback config:
one receiver with no integrations. Alerts then show in Grafana but notify no one.

## Provide a config

Create a Secret in any namespace:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: alertmanager-config
  namespace: monitoring
  labels:
    observability.giantswarm.io/kind: alertmanager-config
    observability.giantswarm.io/tenant: default
stringData:
  alertmanager.yaml: |
    route:
      receiver: webhook
      group_by: [alertname]
    receivers:
      - name: webhook
        webhook_configs:
          - url: https://example.com/alerts
```

- `observability.giantswarm.io/tenant` names the tenant. A `GrafanaOrganization` must list it.
  The default organization lists `global.tenant`.
- `alertmanager.yaml` holds the full [Alertmanager config](https://prometheus.io/docs/alerting/latest/configuration/).
  It replaces the fallback config.
- Every other key ending in `.tmpl` is a [notification template](https://prometheus.io/docs/alerting/latest/notifications/).
  Reference it by its key name.

The observability-operator loads the Secret into Mimir Alertmanager. Changes to the Secret load
the same way. Deleting the Secret deletes the tenant's config.

## Check the config

The operator logs every load:

```bash
kubectl logs -n monitoring -l app.kubernetes.io/name=observability-operator | grep alertmanager
```

Read back the loaded config. In Mimir, `GET /api/v1/alerts` returns the tenant's Alertmanager
config, not its alerts:

```bash
kubectl port-forward -n monitoring svc/mimir-alertmanager 8080 &
curl -H "X-Scope-OrgID: default" http://localhost:8080/api/v1/alerts
```

## Known limitations

- The operator's admission webhooks are disabled. The operator rejects an invalid config in its
  logs only.
- One Secret per tenant. Two Secrets for one tenant overwrite each other.
- The operator loads a Secret only if its tenant is listed at that moment. A Secret created
  before its `GrafanaOrganization` stays unloaded until the Secret changes or the operator
  restarts.
