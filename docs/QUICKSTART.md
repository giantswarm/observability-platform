# Quickstart

[`hack/local/install.sh`](../hack/local/install.sh) installs the platform and the prerequisites
you turn on in [`hack/local/config.env`](../hack/local/config.env), for a first try on kind or
on a cluster you own. It stores data in Garage, an S3-compatible store running in the cluster,
so it needs no buckets. `make local-up` runs the same script with every toggle on (see
[LOCAL_DEV.md](./LOCAL_DEV.md)).

For a production install, follow [INSTALL.md](./INSTALL.md).

## Prerequisites

- A cluster, with `kubectl` and `helm` pointed at it and cluster-admin on it. A kind cluster
  needs Kubernetes 1.32 or newer. To reach the Gateway from your machine, create it with
  [`.ats/kind-config.yaml`](../.ats/kind-config.yaml), which maps the Gateway to
  `127.0.0.1:8080` and `127.0.0.1:8443`.
- Around 6 GiB of memory free
- A clone of this repository. The script installs the chart from it.

## Files

| File | What it is |
| --- | --- |
| `hack/local/config.env` | Which components the script installs, their versions and the kubeconfig context |
| `hack/local/install.sh` | The install script |
| `values/observability-platform.yaml` | Values for the Platform chart, on top of `helm/observability-platform/values-local.yaml`: the external API, the agent write routes, Grafana's backups and Grafana on the Gateway |
| `values/observability-operator.yaml` | Values for the observability-operator release |
| `values/cloudnative-pg.yaml` | Values for the CloudNativePG operator release |
| `values/plugin-barman-cloud.yaml` | Values for the barman-cloud plugin release |
| `hack/local/envoy-gateway/` | The GatewayClass and the Gateway, with a `kind` overlay for NodePorts |
| `hack/local/jwks.yaml`, `jwt.sh`, `tls.sh` | A local JWT issuer and a self-signed certificate for the Gateway. Not for real use. |
| `hack/local/agentcredentials.yaml` | Example AgentCredentials, one per backend. The script does not apply them. |

## Configure

Edit `hack/local/config.env`. These toggles take `true` or `false`. All are off, except
`INSTALL_CNPG` and `CREATE_GRAFANA_SECRET_KEY`:

| Toggle | Installs | Turn it on when |
| --- | --- | --- |
| `INSTALL_ENVOY_GATEWAY` | Envoy Gateway and the Gateway API CRDs | the cluster doesn't run Envoy Gateway |
| `CREATE_GATEWAY` | the Gateway `giantswarm-default` the chart's routes attach to | you have no Gateway of your own |
| `INSTALL_CERT_MANAGER` | cert-manager | the cluster doesn't run cert-manager |
| `DEPLOY_JWT_ISSUER` | a local JWT issuer for the external API | you want to try the external API without an OIDC issuer |
| `CREATE_TLS_SECRET` | a self-signed certificate for the Gateway | you have no certificate in the Secret `local-https-tls` |
| `INSTALL_CNPG` | the CloudNativePG operator, for Grafana's database | the cluster doesn't run one that watches `monitoring` |
| `CREATE_GRAFANA_SECRET_KEY` | the Secret `grafana-secret-key`, unless it exists | you don't create it yourself |
| `INSTALL_PLUGIN_BARMAN_CLOUD` | the barman-cloud plugin, for backups of Grafana's database | you want backups |

The observability-operator and the Platform chart are always installed, in namespace
`monitoring`.

The script stops before it changes anything when the toggles don't fit together: the plugin
needs cert-manager, the Gateway needs Envoy Gateway, and the certificate needs the local issuer.

It turns off the chart features whose prerequisites are missing, so the defaults install:

- **Grafana's route, the agent write routes and the external API** while the cluster serves no
  Envoy Gateway CRDs. Reach Grafana with `kubectl port-forward` instead.
- **The external API** while `DEPLOY_JWT_ISSUER` is off and `values/observability-platform.yaml`
  trusts the local issuer. Point `observability-platform-api.auth.jwt` at your own OIDC issuer
  to keep it on.
- **Grafana's backups** while `INSTALL_PLUGIN_BARMAN_CLOUD` is off, or on the `azure` backend.

`GATEWAY_OVERLAY` picks how the Gateway is exposed: `kind` on NodePorts 30080 and 30443, `base`
through a LoadBalancer Service. `LOCAL_BACKEND` picks the store: `s3` runs Garage, `azure` runs
Azurite.

A variable set in the environment wins over `config.env`, and `LOCAL_CONFIG` names another
config file.

## Install

```bash
hack/local/install.sh
```

The script is safe to run again. Then watch the pods start:

```bash
kubectl get pods -n monitoring
```

With the Gateway, the certificate and the `kind` overlay on, Grafana answers at
<https://grafana.localhost:8443>, and the requests in [LOCAL_DEV.md](./LOCAL_DEV.md#verify) work
as written.

## Push data

The agent write routes need Envoy Gateway. Create the example AgentCredentials:

```bash
kubectl apply -f hack/local/agentcredentials.yaml
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
