# Quickstart

[`quickstart/install.sh`](../quickstart/install.sh) installs the platform and its prerequisites
in one run, for a first try on kind or on a cluster you own. It stores data in Garage, an
S3-compatible store running in the cluster, so it needs no buckets.

For a production install, follow [INSTALL.md](./INSTALL.md).

## Prerequisites

- A cluster, with `kubectl` and `helm` pointed at it and cluster-admin on it. A kind cluster
  needs Kubernetes 1.32 or newer. To reach the Gateway from your machine, create it with
  [`.ats/kind-config.yaml`](../.ats/kind-config.yaml), which maps the Gateway to
  `127.0.0.1:8080` and `127.0.0.1:8443`.
- Around 6 GiB of memory free
- A clone of this repository. The script installs the chart from it.

## What is in the folder

| File | What it is |
| --- | --- |
| `config.env` | Which components the script installs, their versions and the kubeconfig context |
| `install.sh` | The install script |
| `values-observability-platform.yaml` | Values for the Platform chart: a small profile, Garage, the external API, the agent write routes and Grafana on the Gateway |
| `values-observability-operator.yaml` | Values for the observability-operator release |
| `values-cloudnative-pg.yaml` | Values for the CloudNativePG operator release |
| `values-plugin-barman-cloud.yaml` | Values for the barman-cloud plugin release |
| `envoy-gateway/` | The GatewayClass and the Gateway, with a `kind` overlay for NodePorts |
| `jwks.yaml`, `jwt.sh`, `tls.sh` | A local JWT issuer and a self-signed certificate for the Gateway. Not for real use. |
| `agentcredentials.yaml` | Example AgentCredentials, one per backend. The script does not apply them. |

## Configure

Edit [`quickstart/config.env`](../quickstart/config.env). These toggles take `true` or `false`:

| Toggle | Installs | Turn it off when |
| --- | --- | --- |
| `INSTALL_ENVOY_GATEWAY` | Envoy Gateway and the Gateway API CRDs | the cluster already runs Envoy Gateway |
| `CREATE_GATEWAY` | the Gateway `giantswarm-default` the chart's routes attach to | you bring your own Gateway |
| `INSTALL_CERT_MANAGER` | cert-manager | the cluster already runs cert-manager |
| `DEPLOY_JWT_ISSUER` | a local JWT issuer for the external API | you use your own OIDC issuer |
| `CREATE_TLS_SECRET` | a self-signed certificate for the Gateway | you create the Secret `local-https-tls` yourself |
| `INSTALL_CNPG` | the CloudNativePG operator, for Grafana's database | the cluster already runs one that watches `monitoring` |
| `CREATE_GRAFANA_SECRET_KEY` | the Secret `grafana-secret-key`, unless it exists | you create it yourself |
| `INSTALL_PLUGIN_BARMAN_CLOUD` | the barman-cloud plugin, for backups of Grafana's database. Off by default: turn it on with `grafana.postgresqlCluster.backup.enabled` in `values-observability-platform.yaml`. | you don't need backups |

The observability-operator and the Platform chart are always installed, in namespace
`monitoring`.

The script stops before it changes anything when the toggles don't fit together: the plugin
needs cert-manager, the Gateway needs Envoy Gateway, and the certificate needs the local issuer.

`GATEWAY_OVERLAY` picks how the Gateway is exposed: `kind` on NodePorts 30080 and 30443, `base`
through a LoadBalancer Service.

## Install

```bash
quickstart/install.sh
```

To keep several configurations, pass the config file:

```bash
quickstart/install.sh path/to/config.env
```

The script is safe to run again. Then watch the pods start:

```bash
kubectl get pods -n monitoring
```

On kind, Grafana answers at <https://grafana.localhost:8443>. The login and the requests from
[LOCAL_DEV.md](./LOCAL_DEV.md#verify) work the same, with `quickstart/.keys/tls.crt` in place of
`hack/local/.keys/tls.crt`.

## Push data

Create the example AgentCredentials:

```bash
kubectl apply -f quickstart/agentcredentials.yaml
```

Then push as in [LOCAL_DEV.md](./LOCAL_DEV.md#push-with-an-agentcredential). See
[AGENT_CREDENTIALS.md](./AGENT_CREDENTIALS.md) for your own credentials.

## Uninstall

Uninstall the chart first, then the releases the script installed. `--ignore-not-found` skips the ones you toggled off:

```bash
helm uninstall observability-platform plugin-barman-cloud cloudnative-pg observability-operator --namespace monitoring --ignore-not-found
```

```bash
helm uninstall cert-manager --namespace cert-manager --ignore-not-found
```

```bash
helm uninstall eg --namespace envoy-gateway-system --ignore-not-found
```
