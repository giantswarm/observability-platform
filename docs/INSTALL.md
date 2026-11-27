# Installation

This guide installs the Observability Platform on a cluster you own. To try it on your laptop
first, see [LOCAL_DEV.md](./LOCAL_DEV.md).

## Before you install

- **The namespace is `monitoring`.** The chart and the operator both install there, and the
  operator's values in [`values/observability-operator.yaml`](../values/observability-operator.yaml)
  must agree with the chart's. Nothing checks this across the two releases.
- **You bring the Gateway.** The chart creates no Gateway and no TLS certificate. Grafana, the
  external API and the agent write routes attach to a Gateway you provide, and the API and agent
  routes need [Envoy Gateway](https://gateway.envoyproxy.io/). [GATEWAY.md](./GATEWAY.md) sets
  one up.
- **Tenants are not bound to credentials.** A client chooses its tenant with the `X-Scope-OrgID`
  header, so any valid credential can read or write any tenant its route serves.
- **The defaults are sized small.** They fit the minimum profile in
  [Prepare your environment](https://docs.giantswarm.io/overview/observability/standalone/prepare-your-environment/).
  Larger volumes need more capacity in your values.

## Prerequisites

- A conformant Kubernetes cluster with a default StorageClass and metrics-server.
  [Prepare your environment](https://docs.giantswarm.io/overview/observability/standalone/prepare-your-environment/)
  lists the requirements and sizing, and [EKS_CLUSTER.md](./EKS_CLUSTER.md) creates one on AWS.
- Five private buckets in S3, an S3-compatible store or Azure Blob Storage, with credentials.
  [OBJECT_STORAGE.md](./OBJECT_STORAGE.md) creates both.
- `kubectl` and `helm`, with cluster-admin on the cluster.
- Grafana runs on a PostgreSQL cluster by default, which needs the CloudNativePG (CNPG) operator,
  installed below. To skip it, keep Grafana on SQLite (see [GRAFANA_DATABASE.md](./GRAFANA_DATABASE.md))
  and leave out the CNPG and secret key steps.
- A clone of this repository. Run the commands below from its root.

### Network access

The cluster needs outbound HTTPS (port 443) to these endpoints:

| Endpoint | Used for |
| --- | --- |
| Your object storage, `azure` | Mimir, Loki and Tempo data, at `<account>.blob.core.windows.net` |
| Your object storage, `s3` | Mimir, Loki and Tempo data, at the `s3.endpoint` host and `<bucket>.<s3.endpoint>`, for example `<bucket>.s3.eu-west-1.amazonaws.com` |
| `gsoci.azurecr.io` and `*.blob.core.windows.net` | Container images. The registry serves image layers from Azure Blob Storage hosts. |
| `registry-1.docker.io`, `auth.docker.io` and `production.cloudflare.docker.com` | Container images |
| Your OIDC issuer's JWKS URI | Token validation by the Envoy proxy pods, with the external API enabled |
| Your alert receivers | Notifications from Mimir Alertmanager |

The machine that runs `helm install` needs `https://giantswarm.github.io/giantswarm-catalog/` and
`https://giantswarm.github.io/control-plane-catalog/` for the Helm charts.

## Install

Write a `values.yaml` that names your object store:

```yaml
global:
  objectStorage:
    backend: s3                             # or azure
    s3:
      endpoint: s3.eu-west-1.amazonaws.com
      region: eu-west-1
    # On AWS S3, also set your own bucket names under `buckets`.
```

Install the observability-operator first. It brings the CRDs the chart needs. The command installs
the latest operator. The version the chart is tested against is `OPERATOR_VERSION` in
[`hack/local/install.sh`](../hack/local/install.sh): pass it with `--version` to pin it.

```bash
helm install observability-operator observability-operator \
  --repo https://giantswarm.github.io/control-plane-catalog/ \
  --namespace monitoring --create-namespace \
  --values values/observability-operator.yaml
```

Install the CNPG operator for Grafana's PostgreSQL cluster. Skip it if the cluster already runs a
CNPG operator that watches `monitoring` (see [GRAFANA_DATABASE.md](./GRAFANA_DATABASE.md)):

```bash
helm install cloudnative-pg cloudnative-pg \
  --repo https://giantswarm.github.io/control-plane-catalog/ --version 0.1.0 \
  --namespace monitoring \
  --values values/cloudnative-pg.yaml
```

Create Grafana's secret key, once. Keep a copy outside the cluster: restoring Grafana's database
needs the same key, and changing it makes the secrets Grafana stored unreadable.

```bash
kubectl create secret generic grafana-secret-key --namespace monitoring \
  --from-literal=secret-key="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
```

Create the object storage credentials Secret. The name is fixed. For Azure Blob Storage, the key is
`AZURE_STORAGE_KEY` instead:

```bash
kubectl create secret generic observability-platform-object-storage --namespace monitoring \
  --from-literal=AWS_ACCESS_KEY_ID="<access-key-id>" \
  --from-literal=AWS_SECRET_ACCESS_KEY="<secret-access-key>"
```

Fetch the chart's dependencies, then install it:

```bash
helm dependency update helm/observability-platform
```

```bash
helm install observability-platform helm/observability-platform \
  --namespace monitoring --values values.yaml
```

The install notes print how to reach Grafana and log in.

## Next steps

- **Send data:** give your agents [AgentCredentials](./AGENT_CREDENTIALS.md), or turn on the
  [external API](./EXTERNAL_API.md).
- **Expose Grafana:** serve it over HTTPS on your Gateway, as in
  [EXTERNAL_API.md](./EXTERNAL_API.md#expose-grafana-over-https).
- **Route alerts:** provide your own Alertmanager config, as in [ALERTING.md](./ALERTING.md).
- **Back up Grafana:** turn on backups of Grafana's database to your object storage, as in
  [GRAFANA_DATABASE.md](./GRAFANA_DATABASE.md#backups). They need cert-manager and the
  barman-cloud plugin release.

## Uninstall

Uninstall in the opposite order: the chart first, then the operators. Uninstalling the chart
deletes Grafana's PostgreSQL cluster and its volumes.

```bash
helm uninstall observability-platform --namespace monitoring
```

```bash
helm uninstall observability-operator --namespace monitoring
```

```bash
helm uninstall cloudnative-pg --namespace monitoring
```
