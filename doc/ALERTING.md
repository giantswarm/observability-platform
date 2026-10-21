# Alerting

The Mimir ruler sends alerts to Mimir Alertmanager. Alertmanager routes them to your receivers.
Grafana shows the alerts of `global.tenant` in the default organization.

Each tenant has one Alertmanager config, stored in one Secret. A tenant without a Secret uses
the fallback config: one receiver with no integrations.

## Default config

The chart creates the Secret `alertmanager-config` for `global.tenant`. It needs these values:

- `defaultAlertmanagerConfig.enabled`
- `defaultOrganization.enabled`
- `observabilityOperator.enabled`
- `mimir.enabled`
- `mimir.mimir.alertmanager.enabled`

Each file in `helm/observability-platform/files/alertmanager` becomes one key of the Secret. The
default `alertmanager.yaml` routes every alert to the `default` receiver. That receiver has no
integrations.

To use your own config, follow [Provide a config](#provide-a-config).

## Provide a config

Create a Secret in any namespace. For `global.tenant`, set `defaultAlertmanagerConfig.enabled: false`
first.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: my-alertmanager-config
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

- `observability.giantswarm.io/tenant` holds the Mimir tenant the config applies to. The
  operator loads the Secret only when a `GrafanaOrganization` names this tenant under
  `spec.tenants`. The chart creates the default organization. It adds `global.tenant` to the
  organization's `spec.tenants`.
- `alertmanager.yaml` holds the full [Alertmanager config](https://prometheus.io/docs/alerting/latest/configuration/).
  It replaces the fallback config.
- Every other key ending in `.tmpl` is a [notification template](https://prometheus.io/docs/alerting/latest/notifications/).
  Reference it by its key name.

Create the `GrafanaOrganization` before the Secret. The observability-operator loads the Secret
into Mimir Alertmanager. It reloads the Secret on every change. Deleting the Secret deletes the
tenant's config.

## Check the config

The operator logs every load and every rejected config:

```bash
kubectl logs -n monitoring -l app.kubernetes.io/name=observability-operator | grep alertmanager
```

Read back the loaded config. In Mimir, `GET /api/v1/alerts` returns the tenant's Alertmanager
config:

```bash
kubectl port-forward -n monitoring svc/mimir-alertmanager 8080 &
curl -H "X-Scope-OrgID: default" http://localhost:8080/api/v1/alerts
```
