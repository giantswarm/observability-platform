# Installation

This guide installs the Observability Platform on a cluster you own, step by step. To try it on
your laptop first, see [LOCAL_DEV.md](./LOCAL_DEV.md).

1. Check the [required prerequisites](#required-prerequisites).
2. Pick the [optional features](#optional-features) you want.
3. [Write the platform values](#step-1--write-the-platform-values).
4. [Create the Secrets](#step-2--create-the-secrets).
5. [Configure and install](#step-3--configure-and-install).
6. Optional: [verify](#step-4--verify-optional).
7. Optional: [send data](#step-5--send-data-optional).

> [!IMPORTANT]
> **The namespace is `monitoring`.** The chart and its operators all install there.

## Prerequisites

[Prepare your environment](https://docs.giantswarm.io/overview/observability/standalone/prepare-your-environment/)
lists the requirements in detail: sizing, cluster add-ons, network access and provider guidance.

### Required prerequisites

| Prerequisite | Check | Details |
| --- | --- | --- |
| A conformant cluster with a default StorageClass | `kubectl get storageclass` shows one `(default)` | [Prepare your environment](https://docs.giantswarm.io/overview/observability/standalone/prepare-your-environment/), [EKS_CLUSTER.md](./EKS_CLUSTER.md) |
| metrics-server | `kubectl top nodes` prints usage | [Prepare your environment](https://docs.giantswarm.io/overview/observability/standalone/prepare-your-environment/) |
| `kubectl` and `helm`, with cluster-admin | `kubectl auth can-i '*' '*' --all-namespaces` prints `yes` | |
| A clone of this repository | Run every command from its root | It holds the chart, the values of the other releases, the install script and the checks |
| Five private buckets, in S3, an S3-compatible store or Azure Blob Storage | Your store lists them | [OBJECT_STORAGE.md](./OBJECT_STORAGE.md#buckets) |
| Credentials with read and write access to the buckets | | [OBJECT_STORAGE.md](./OBJECT_STORAGE.md#credentials) |

### Optional features

Each feature needs the items in its row. Pick them now: step 1 sets their values, and step 3
installs their releases.

| Feature | What it gives you | What it needs | Details |
| --- | --- | --- | --- |
| **Gateway** | HTTPS access from outside the cluster. The three features below need it. | Envoy Gateway, a Gateway with an HTTPS listener, a TLS certificate, a DNS record, a base domain | [GATEWAY.md](./GATEWAY.md) (example on EKS) |
| ↳ Grafana route | Grafana over HTTPS, at a hostname you choose | The Gateway | [EXTERNAL_API.md](./EXTERNAL_API.md#expose-grafana-over-https) |
| ↳ Agent write routes | Agents push metrics, logs and traces with AgentCredentials | The Gateway. A certificate that covers `write.loki.<domain>` | [AGENT_CREDENTIALS.md](./AGENT_CREDENTIALS.md) |
| ↳ External API | Reads and writes from outside the cluster, with JWTs | The Gateway. An OIDC issuer | [EXTERNAL_API.md](./EXTERNAL_API.md) |
| **Grafana backups** | Hourly backups of Grafana's database to your object storage | The `s3` backend. A sixth bucket. cert-manager and the barman-cloud plugin | [GRAFANA_DATABASE.md](./GRAFANA_DATABASE.md#backups) |
| **Alert routing** | Alerts reach your receivers | Your Alertmanager config | [ALERTING.md](./ALERTING.md) |
| **IRSA or workload identity** | Object storage access without static keys | An IAM role or a managed identity | [OBJECT_STORAGE.md](./OBJECT_STORAGE.md#ambient-credentials-and-irsa) |

## Step 1 — Write the platform values

The install script installs the chart with the configuration defined in
[`values/observability-platform.yaml`](../values/observability-platform.yaml). Copy it, and the
script's configuration [`hack/local/config.env`](../hack/local/config.env), outside the
repository. Your changes then stay out of the files that `make local-up` uses and `git pull`
updates:

```bash
mkdir -p "$HOME/observability-platform"
cp values/observability-platform.yaml hack/local/config.env "$HOME/observability-platform/"
```

Edit your copy, `$HOME/observability-platform/observability-platform.yaml`. Its defaults use
example hostnames under `localhost` and an example JWT issuer: replace them with yours.

Add the required values. The example uses AWS S3. For an S3-compatible store, set its
`endpoint` and keep the default bucket names. For Azure Blob Storage, see
[OBJECT_STORAGE.md](./OBJECT_STORAGE.md#azure-blob-storage).

```yaml
global:
  objectStorage:
    backend: s3
    s3:
      endpoint: s3.eu-west-1.amazonaws.com
      region: eu-west-1
    # AWS S3 bucket names are global: set your own.
    buckets:
      mimirBlocks: <prefix>-mimir-blocks
      mimirAlertmanager: <prefix>-mimir-alertmanager
      mimirRuler: <prefix>-mimir-ruler
      loki: <prefix>-loki
      tempo: <prefix>-tempo
```

The file already turns on the Grafana route, the agent write routes, the external API and
Grafana backups. Set the hostnames and the issuer of the features you picked, as below, and
set `enabled: false` on the ones you didn't. The routes attach to the Gateway
`giantswarm-default` in `envoy-gateway-system`, on its listener `https`.
[GATEWAY.md](./GATEWAY.md) creates that Gateway. For another Gateway, set the `parentRefs` as the
linked page shows.

<details>
<summary>Gateway: the base domain</summary>

```yaml
global:
  domain: example.com
```

</details>

<details>
<summary>Grafana route</summary>

```yaml
grafana:
  grafana:
    route:
      main:
        enabled: true
        hostnames:
          - grafana.example.com
        parentRefs:
          - name: giantswarm-default
            namespace: envoy-gateway-system
            sectionName: https
    grafana.ini:
      server:
        root_url: https://grafana.example.com
```

See [EXTERNAL_API.md](./EXTERNAL_API.md#expose-grafana-over-https).

</details>

<details>
<summary>Agent write routes</summary>

```yaml
mimir:
  routes:
    gateway:
      enabled: true
loki:
  gatewayRoute:
    enabled: true
tempo:
  routes:
    https:
      enabled: true
    grpc:
      enabled: true
```

See [AGENT_CREDENTIALS.md](./AGENT_CREDENTIALS.md#turn-it-on).

</details>

<details>
<summary>External API</summary>

```yaml
observabilityPlatformApi:
  enabled: true
observability-platform-api:
  auth:
    jwt:
      providers:
        - name: my-issuer
          issuer: https://issuer.example.com
          remoteJWKS:
            uri: https://issuer.example.com/keys
          extractFrom:
            headers:
              - name: Authorization
                valuePrefix: "Bearer "
```

See [EXTERNAL_API.md](./EXTERNAL_API.md#values).

</details>

<details>
<summary>Grafana backups</summary>

```yaml
global:
  objectStorage:
    buckets:
      grafanaPostgresql: <prefix>-grafana-postgresql
grafana:
  postgresqlCluster:
    backup:
      enabled: true
```

See [GRAFANA_DATABASE.md](./GRAFANA_DATABASE.md#enable-backups).

</details>

<details>
<summary>Alert routing</summary>

```yaml
defaultAlertmanagerConfig:
  enabled: false
```

Then create your Alertmanager config Secret. See [ALERTING.md](./ALERTING.md).

</details>

Grafana stores its data in PostgreSQL, run by the CloudNativePG (CNPG) operator. To keep it on
SQLite instead, see [GRAFANA_DATABASE.md](./GRAFANA_DATABASE.md#keep-grafana-on-sqlite).

To keep some settings apart, for example per environment, write them in more values files.
Step 3 passes them to the script after this one.

## Step 2 — Create the Secrets

Create the namespace:

```bash
kubectl create namespace monitoring
```

Create the S3 credentials Secret. The name is fixed. With IRSA, skip this Secret.

```bash
kubectl create secret generic observability-platform-object-storage --namespace monitoring \
  --from-literal=AWS_ACCESS_KEY_ID="<access-key-id>" \
  --from-literal=AWS_SECRET_ACCESS_KEY="<secret-access-key>"
```

## Step 3 — Configure and install

Your copy of `config.env` configures the install script. Set:

- `PLATFORM_VALUES` to your values file, then any other values files, separated by spaces.
  Later files win.
- `KUBE_CONTEXT` to your cluster's context, or leave it empty for the current context.

```bash
PLATFORM_VALUES="$HOME/observability-platform/observability-platform.yaml"
KUBE_CONTEXT=my-cluster
```

The other settings toggle the releases and resources the script installs, with `true` or
`false`. Turn on the ones your optional features need and your cluster doesn't run yet:

| Toggle | Default | Installs | Needed by |
| --- | --- | --- | --- |
| `INSTALL_ENVOY_GATEWAY` | `false` | Envoy Gateway and the Gateway API CRDs | the Gateway |
| `CREATE_GATEWAY` | `false` | the Gateway `giantswarm-default` in `envoy-gateway-system`. `GATEWAY_OVERLAY=base` exposes it through a LoadBalancer Service. | the Gateway, when you have none |
| `CREATE_TLS_SECRET` | `false` | a self-signed certificate for the Gateway. Not for real use. Needs `DEPLOY_JWT_ISSUER`. | |
| `DEPLOY_JWT_ISSUER` | `false` | a local JWT issuer. Not for real use. | |
| `INSTALL_CERT_MANAGER` | `false` | cert-manager | Grafana backups |
| `INSTALL_PLUGIN_BARMAN_CLOUD` | `false` | the barman-cloud plugin release, with [`values/plugin-barman-cloud.yaml`](../values/plugin-barman-cloud.yaml) | Grafana backups |
| `INSTALL_CNPG` | `true` | the CNPG operator release, with [`values/cloudnative-pg.yaml`](../values/cloudnative-pg.yaml) | Grafana on PostgreSQL. Turn it off when the cluster already runs a CNPG operator that watches `monitoring`. |
| `CREATE_GRAFANA_SECRET_KEY` | `true` | the Secret `grafana-secret-key`, when it is missing | Grafana on PostgreSQL |

The comments in `config.env` describe each setting, with the release versions. Before it
changes anything, the script checks that the toggles fit together, and that Grafana's database
will have the CNPG operator and the Secret `grafana-secret-key`.

Run the install script with your copy of `config.env`:

```bash
LOCAL_CONFIG="$HOME/observability-platform/config.env" hack/local/install.sh
```

The script installs, in this order:

1. Envoy Gateway, cert-manager, the Gateway and its certificate, as toggled.
2. The observability-operator release, with [`values/observability-operator.yaml`](../values/observability-operator.yaml). It is always installed.
3. The CNPG operator and the barman-cloud plugin releases, as toggled.
4. The Secret `grafana-secret-key`, as toggled.
5. The observability-platform chart, with the values files in `PLATFORM_VALUES`.

The script turns off the chart features whose prerequisites the cluster lacks, and prints a note
for each: the routes and the external API without Envoy Gateway, the external API while it
trusts the local issuer without `DEPLOY_JWT_ISSUER`, and Grafana backups without the barman-cloud
plugin. The script is safe to run again.

Keep a copy of Grafana's secret key outside the cluster. Restoring Grafana's database needs the
same key.

```bash
kubectl get secret grafana-secret-key --namespace monitoring -o jsonpath='{.data.secret-key}' | base64 -d; echo
```

Check that every pod runs:

```bash
kubectl get pods --namespace monitoring
```

The install notes print how to reach Grafana and log in.

## Step 4 — Verify (optional)

The checks need [`uv`](https://docs.astral.sh/uv/). They read the target from `.env.verify` at the
repository root, or from the same variables in the environment.

The health checks only read the cluster and work on any install. They check that the PVCs are
bound, that no container was OOMKilled, and that the routes and Gateways are accepted. Without
`.env.verify`, they use the current kubectl context:

```bash
make verify-health
```

The full checks also write and read data through every route. They need the Gateway, the Grafana
route, the agent write routes and the external API.

> [!WARNING]
> The full checks change the platform. They write test data to the `default` tenant, create a
> namespace with AgentCredentials and rule groups, and restart Grafana.

Write `.env.verify`:

```bash
KUBE_CONTEXT=<your-kube-context>
# A command that prints a JWT from your OIDC issuer.
OBS_TOKEN_COMMAND=<command>
# Only when your Gateway certificate comes from a private CA.
# OBS_CA_BUNDLE=/path/to/ca.crt
```

Run the full checks:

```bash
make verify
```

## Step 5 — Send data (optional)

Agents push with AgentCredentials, through the agent write routes. Create one per agent and
backend:

```yaml
apiVersion: observability.giantswarm.io/v1alpha1
kind: AgentCredential
metadata:
  name: alloy-metrics
  namespace: my-team
spec:
  backend: metrics    # metrics, logs or traces
```

The operator creates a Secret with the same name and namespace. It holds the `username` and
`password` of the agent:

```bash
kubectl get secret alloy-metrics -n my-team -o jsonpath='{.data.password}' | base64 -d; echo
```

[AGENT_CREDENTIALS.md](./AGENT_CREDENTIALS.md#configure-an-agent) configures Alloy with it.

## Uninstall

Uninstall in the opposite order: the chart first, then the operators. Uninstalling the chart
deletes Grafana's PostgreSQL cluster and its volumes.

```bash
helm uninstall observability-platform --namespace monitoring
helm uninstall cloudnative-pg --namespace monitoring
helm uninstall observability-operator --namespace monitoring
```

Then uninstall the releases of the optional features you installed.
