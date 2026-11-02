# Object Storage

The observability platform stores metrics, alerting state, recording rules, logs and traces
in object storage. Mimir, Loki and Tempo read it.

The chart supports two backends:

- `azure`: Azure Blob Storage.
- `s3`: AWS S3, or an S3-compatible store.

One value, `global.objectStorage.backend`, picks the backend for Mimir, Loki and Tempo
together. It has no default.

For development you need none of this. `localBlobStorage.enabled` runs the Azurite
emulator in the cluster for the `azure` backend. See [LOCAL_DEV.md](./LOCAL_DEV.md).

## Shared model

### Values

All storage values live under `global.objectStorage`:

| Key | Backend | Meaning |
| --- | --- | --- |
| `backend` | both | `azure` or `s3`. Required. No default. |
| `existingSecret` | both | Credentials Secret. Fixed: `observability-platform-object-storage`. |
| `buckets.*` | both | Container (azure) or bucket (s3) names. See [Buckets](#buckets). |
| `azure.accountName` | `azure` | Storage account holding the containers. |
| `azure.connectionString` | `azure` | Full connection string. Not read by Tempo. |
| `s3.endpoint` | `s3` | Store endpoint, `host[:port]`, no scheme. Required. |
| `s3.region` | `s3` | Signing region. Set it for AWS S3, or when the store checks it. |
| `s3.insecure` | `s3` | Plain HTTP. Defaults to `false`. |

`existingSecret` accepts only its fixed name. The Mimir, Loki and Tempo values reference
the Secret from static values, and Helm cannot compute a subchart's values. The values
schema rejects any other name.

The schema also rejects an endpoint with a scheme, such as `https://s3.example.com`.

### Render guards

The render fails when the values cannot reach a store. Each message names the value to fix.

| Guard | Fails when |
| --- | --- |
| 1 | `backend` is unset, or not `azure` or `s3`. |
| 2 | `backend` is `s3` and `s3.endpoint` is empty. |
| 3 | `backend` is `azure` and `azure.accountName` and `azure.connectionString` are empty. Skipped under Azurite. |
| 4 | `backend` is `azure`, Tempo is enabled and `azure.connectionString` is set. Skipped under Azurite. |
| 5 | `backend` is `s3` and `localBlobStorage.enabled` is `true`. |

The messages, as `helm template` prints them:

1. `global.objectStorage.backend is "". Set it to "azure" or "s3" - see doc/OBJECT_STORAGE.md.`
2. `global.objectStorage.backend is "s3" and global.objectStorage.s3.endpoint is empty. Set it to the store endpoint, host[:port] without a scheme - see doc/OBJECT_STORAGE.md.`
3. `global.objectStorage.azure.accountName is empty. Set it to the Azure storage account holding the containers, or set global.objectStorage.azure.connectionString to reach an endpoint of your own, or set localBlobStorage.enabled to run against a local Azurite emulator - see doc/OBJECT_STORAGE.md.`
4. `tempo.enabled is true and global.objectStorage.azure.connectionString is set. Tempo reads no connection string: it needs global.objectStorage.azure.accountName and the account key in the credentials Secret. Set accountName instead of connectionString, or set tempo.enabled to false - see doc/OBJECT_STORAGE.md.`
5. `global.objectStorage.backend is "s3" and localBlobStorage.enabled is true. localBlobStorage runs Azurite, which serves backend "azure" only. Set the backend to "azure" or set localBlobStorage.enabled to false - see doc/LOCAL_DEV.md.`

Each backend reads only its own values. Values of the other backend are ignored.

### Generated ConfigMap

The chart renders the ConfigMap `observability-platform-object-storage` in the release
namespace. It renders while Mimir, Loki or Tempo is enabled. Every key is always present.

| Key | `azure` | `s3` |
| --- | --- | --- |
| `OBS_TENANT` | `global.tenant` | `global.tenant` |
| `OBS_BACKEND` | `azure` | `s3` |
| `OBS_AZURE_ACCOUNT_NAME` | `azure.accountName` | empty |
| `OBS_AZURE_CONNECTION_STRING` | `azure.connectionString` | empty |
| `OBS_BUCKET_MIMIR_BLOCKS` | `buckets.mimirBlocks` | `buckets.mimirBlocks` |
| `OBS_BUCKET_MIMIR_ALERTMANAGER` | `buckets.mimirAlertmanager` | `buckets.mimirAlertmanager` |
| `OBS_BUCKET_MIMIR_RULER` | `buckets.mimirRuler` | `buckets.mimirRuler` |
| `OBS_BUCKET_LOKI` | `buckets.loki` | `buckets.loki` |
| `OBS_BUCKET_TEMPO` | `buckets.tempo` | `buckets.tempo` |
| `OBS_AZURE_ENDPOINT_SUFFIX` | `blob.core.windows.net` | `blob.core.windows.net` |
| `OBS_S3_ENDPOINT` | empty | `s3.endpoint` |
| `OBS_S3_REGION` | empty | `s3.region` |
| `OBS_S3_INSECURE` | `false` | `s3.insecure`, `true` or `false` |

Under `localBlobStorage.enabled` the chart computes the Azurite values instead.
See [LOCAL_DEV.md](./LOCAL_DEV.md).

How the values reach the components:

1. The chart renders the ConfigMap above.
2. The ConfigMap and the credentials Secret reach the Mimir, Loki and Tempo pods as
   environment variables, through `extraEnvFrom`. No other pod gets them.
3. The component configs read `${OBS_*}` references. The Mimir and Loki charts run every
   component with `-config.expand-env=true`. The chart adds the flag to every Tempo
   component.

Every component config carries both an `azure` and an `s3` block. The `backend` fields read
`${OBS_BACKEND}`, so the backend is picked at startup.

### Loki storage client

Loki runs thanos mode on both backends: `storage_config.use_thanos_objstore` is `true`.
Loki reads `storage_config.object_store` for chunks and index, and `ruler_storage` for
rules.

The upstream Loki chart still renders `common.storage.object_store` and `ruler.storage`. Loki
ignores both in thanos mode. The ruler logs a warning about `ruler.storage` at start.

### Credentials Secret

The operator creates one Secret in the release namespace. The chart never renders it.

- Name: `observability-platform-object-storage`, the `existingSecret` value.
- Keys for `azure`: `AZURE_STORAGE_KEY`.
- Keys for `s3`: `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`.

The keys reach the pods as environment variables, so each key name must be a valid variable
name. The pods reference the Secret with `optional: true`.

Under `localBlobStorage.enabled` the chart renders its own dev Secret instead:
`azurite-credentials`, for Tempo.

### What the chart does not set

Set these through the subchart values if you need them:

- **Loki retention.** `compactor.retention_enabled: true` also needs
  `compactor.delete_request_store: ${OBS_BACKEND}`. Otherwise deletion requests have
  nowhere to live.
- **A later schema period.** The chart pins `from: 2024-04-01`. Date a new period forward.
  It cannot start in the past relative to data written under another schema.

## Buckets

The chart uses five containers (azure) or buckets (s3). The names are the same on both
backends:

| Value | Default | Consumer | Contents |
| --- | --- | --- | --- |
| `buckets.mimirBlocks` | `mimir-blocks` | Mimir `blocks_storage` | TSDB blocks, the bulk of the data |
| `buckets.mimirAlertmanager` | `mimir-alertmanager` | Mimir `alertmanager_storage` | Alertmanager state and configs |
| `buckets.mimirRuler` | `mimir-ruler` | Mimir `ruler_storage` | Recording and alerting rule groups |
| `buckets.loki` | `loki` | Loki chunks, index, ruler, admin | Log data |
| `buckets.tempo` | `tempo` | Tempo `storage.trace` | Trace blocks |

Create them before install. The chart creates none, except under
`localBlobStorage.enabled`.

Loki uses one bucket for chunks, ruler and admin. They become key prefixes inside it.

This chart does not deploy Pyroscope yet. Pyroscope will get its own container or bucket.

**AWS S3 bucket names are global.** Every AWS account shares one bucket namespace. The
defaults `mimir-blocks`, `mimir-alertmanager`, `mimir-ruler`, `loki` and `tempo` are
almost certainly taken on AWS. Override all five names before install. Add a prefix, for
example `<org>-<installation>-mimir-blocks`:

```yaml
global:
  objectStorage:
    buckets:
      mimirBlocks: acme-prod-mimir-blocks
      mimirAlertmanager: acme-prod-mimir-alertmanager
      mimirRuler: acme-prod-mimir-ruler
      loki: acme-prod-loki
      tempo: acme-prod-tempo
```

The chart passes the names through unchanged. Create the buckets under these names
before install.

S3-compatible stores and Azure Blob Storage scope names to the account. The defaults
work there.

### Create the buckets

Create the five buckets before install. Use the names from your `buckets` values. The
examples use the `acme-prod-*` names from above on AWS and the defaults elsewhere.

The examples run with an admin identity. The credentials Secret needs no right to create
buckets.

#### AWS S3

```bash
REGION=eu-west-1   # s3.region

for b in acme-prod-mimir-blocks acme-prod-mimir-alertmanager acme-prod-mimir-ruler \
         acme-prod-loki acme-prod-tempo; do
  aws s3api create-bucket --bucket "$b" --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION"
  aws s3api put-public-access-block --bucket "$b" --region "$REGION" \
    --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
done
```

In `us-east-1`, drop `--create-bucket-configuration`. AWS rejects
`LocationConstraint=us-east-1`. Every other region requires it.

Each `create-bucket` call prints the bucket `Location`. A re-run prints
`BucketAlreadyOwnedByYou` for a bucket that exists in your account. `BucketAlreadyExists`
means another AWS account owns the name. Pick another prefix.

#### S3-compatible store

```bash
ENDPOINT=minio.storage.internal:9000   # s3.endpoint

for b in mimir-blocks mimir-alertmanager mimir-ruler loki tempo; do
  aws s3api create-bucket --bucket "$b" --endpoint-url "https://$ENDPOINT"
done
```

Use `http://` with `s3.insecure: true`. Add `--region "$REGION"` with your `s3.region`
when the store checks the signing region.

#### Azure Blob Storage

Create the containers with `az storage container create`. See
[Step 3](#step-3--create-the-containers).

#### List the buckets

```bash
aws s3api list-buckets --query "Buckets[].Name" \
  --endpoint-url "https://$ENDPOINT" --region "$REGION"
```

The output lists the five names. On AWS, set `ENDPOINT` to `s3.<region>.amazonaws.com`.
Drop `--region` on a store that does not check the signing region.

## Credentials

Static keys come from one Secret. The operator creates it in the release namespace. The
chart never renders it, and chart values never hold a key.

- Name: `observability-platform-object-storage`, fixed. `global.objectStorage.existingSecret`
  holds this name.
- The same Secret serves both backends. Only the keys differ.
- Mimir, Loki and Tempo load it through `envFrom`, with `optional: true`.
- The S3 key fields stay empty in every component config. The components read the keys
  from the environment.

Backend `azure`:

```bash
kubectl create secret generic observability-platform-object-storage \
  --namespace monitoring \
  --from-literal=AZURE_STORAGE_KEY="<storage-account-key>"
```

Backend `s3`:

```bash
kubectl create secret generic observability-platform-object-storage \
  --namespace monitoring \
  --from-literal=AWS_ACCESS_KEY_ID="<access-key-id>" \
  --from-literal=AWS_SECRET_ACCESS_KEY="<secret-access-key>"
```

Secret keys:

| Key | Backend | Required | Consumer |
|---|---|---|---|
| `AZURE_STORAGE_KEY` | `azure` | Yes, unless `azure.connectionString` is set | Mimir, Loki, Tempo |
| `AWS_ACCESS_KEY_ID` | `s3` | Optional. Set it together with `AWS_SECRET_ACCESS_KEY`. | Mimir, Loki, Tempo |
| `AWS_SECRET_ACCESS_KEY` | `s3` | Optional. Set it together with `AWS_ACCESS_KEY_ID`. | Mimir, Loki, Tempo |

The S3 key names follow the AWS SDK convention. The observability-operator `LogExport`
reads the same two keys from its `credentialsRef` Secret. See
[`logexport_types.go`](https://github.com/giantswarm/observability-operator/blob/main/api/v1alpha1/logexport_types.go).

### Ambient credentials and IRSA

The S3 keys are optional. Without them, Mimir, Loki and Tempo fall back to **ambient
credentials**: IRSA or the node's instance role.

"Empty keys" means the pods see no `AWS_ACCESS_KEY_ID` and no `AWS_SECRET_ACCESS_KEY`.
Two setups give empty keys:

- Skip the Secret `observability-platform-object-storage`.
- Create the Secret without the two keys.

The pods start in both setups. The `secretRef` is `optional: true`. The chart sets no
AWS key variable and no key field in any component config.

Each component tries the credential sources in this order:

1. Secret keys: `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` from the environment.
2. Web identity (IRSA): the token file and role ARN that the EKS pod identity webhook
   injects into pods of an annotated ServiceAccount.
3. IMDS: the EC2 instance role of the node.

Static keys win over IRSA. Remove both keys from the Secret to use IRSA.

When no source resolves:

- Tempo fails at startup.
- Mimir and Loki fall back to anonymous requests. The store rejects them, and
  the components log access-denied errors.

#### ServiceAccount annotations for IRSA

The Platform chart has no value for IRSA roles. Set the annotation
`eks.amazonaws.com/role-arn` on each subchart's ServiceAccount. The EKS pod identity
webhook then injects the role into the pods.

| Subchart | Values path | ServiceAccount | Notes |
|---|---|---|---|
| Mimir | `mimir.mimir.serviceAccount.annotations` | `mimir` | Shared by all Mimir components. Required. |
| Mimir | `mimir.mimir.alertmanager.serviceAccount.create` and `.annotations` | `mimir-alertmanager` | Optional. Without `create: true`, the Alertmanager uses `mimir`. |
| Mimir | `mimir.mimir.ruler.serviceAccount.create` and `.annotations` | `mimir-ruler` | Optional. Without `create: true`, the ruler uses `mimir`. |
| Loki | `loki.loki.serviceAccount.annotations` | `loki` | Used by `loki-read`, `loki-write` and `loki-backend`. Required. |
| Tempo | `tempo.tempo.serviceAccount.annotations` | `tempo` | Shared by all Tempo components. Required. |

These ServiceAccounts need no annotation. Their pods do not touch the bucket:

- `loki-gateway`: the Loki gateway.
- `loki-memcached`: the Loki chunks and results caches.
- `obs-grafana-agent-operator`: the Grafana Agent operator from the Mimir chart.
- `grafana`: Grafana.

Values example with one role for all components:

```yaml
mimir:
  mimir:
    serviceAccount:
      annotations:
        eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/example
    alertmanager:
      serviceAccount:
        create: true
        annotations:
          eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/example
    ruler:
      serviceAccount:
        create: true
        annotations:
          eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/example
loki:
  loki:
    serviceAccount:
      annotations:
        eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/example
tempo:
  tempo:
    serviceAccount:
      annotations:
        eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/example
```

Drop the `alertmanager` and `ruler` blocks to keep both on the shared `mimir`
ServiceAccount. The role's trust policy must allow each ServiceAccount in the release
namespace, for example `system:serviceaccount:monitoring:mimir`.

## Azure Blob Storage

This section provisions an Azure storage account with the Azure CLI and hands it to the
chart.

Use **a single storage account** with **one container per bucket** from
[Buckets](#buckets). Containers are already an isolation boundary within an account.

### Account settings

| Setting            | Value          | Why                                                      |
| ------------------ | -------------- | -------------------------------------------------------- |
| Kind               | `StorageV2`    | Required for blob access tiers                           |
| SKU                | `Standard_LRS` | Locally redundant; cheapest tier Mimir supports. Use `Standard_ZRS` if you need zone redundancy |
| Access tier        | `Hot`          | Blocks are read constantly by queriers and the compactor |
| Minimum TLS        | `TLS1_2`       | Reject legacy TLS                                        |
| HTTPS only         | `true`         | No plaintext access                                      |
| Blob public access | `false`        | No container is ever public                              |
| Shared key access  | `true`         | Mimir, Loki and Tempo authenticate with the account key  |

Shared key access means a long-lived credential in a Kubernetes secret with no built-in
rotation. If your environment supports it, prefer Azure Workload Identity and disable
shared key access — see [Workload identity](#workload-identity).

### Prerequisites

- `az` CLI, logged in (`az login`)
- `Contributor` on the target resource group
- An existing resource group, or permission to create one

### Step 1 — Set variables

Adjust these to your environment:

```bash
SUBSCRIPTION=<your-subscription-id>
RESOURCE_GROUP=observability-platform
LOCATION=westeurope
ACCOUNT=obsplatform          # must be globally unique — see below
```

Pin the subscription, so a stale CLI context cannot direct writes elsewhere:

```bash
az account set --subscription "$SUBSCRIPTION"
```

Storage account names are **globally unique across all of Azure**, 3–24 characters,
lowercase letters and digits only — no hyphens. Check availability before committing to
a name:

```bash
az storage account check-name --name "$ACCOUNT" -o json
```

```json
{
  "message": null,
  "nameAvailable": true,
  "reason": null
}
```

If `nameAvailable` is `false` the name is taken, possibly in an Azure tenant you have
nothing to do with. Pick another.

Create the resource group if you do not have one:

```bash
az group create --name "$RESOURCE_GROUP" --location "$LOCATION"
```

### Step 2 — Create the storage account

```bash
az storage account create \
  --name "$ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --access-tier Hot \
  --min-tls-version TLS1_2 \
  --https-only true \
  --allow-blob-public-access false \
  --allow-shared-key-access true \
  --tags app=observability-platform
```

This takes ~30 seconds. Confirm it landed as intended:

```bash
az storage account show --name "$ACCOUNT" --resource-group "$RESOURCE_GROUP" \
  --query "{sku:sku.name,kind:kind,tier:accessTier,tls:minimumTlsVersion,publicBlob:allowBlobPublicAccess,blob:primaryEndpoints.blob,state:provisioningState}" \
  -o json
```

```json
{
  "blob": "https://obsplatform.blob.core.windows.net/",
  "kind": "StorageV2",
  "publicBlob": false,
  "sku": "Standard_LRS",
  "state": "Succeeded",
  "tier": "Hot",
  "tls": "TLS1_2"
}
```

### Step 3 — Create the containers

Fetch the account key once and reuse it:

```bash
KEY=$(az storage account keys list \
  --account-name "$ACCOUNT" --resource-group "$RESOURCE_GROUP" \
  --query "[0].value" -o tsv)
```

```bash
for c in mimir-blocks mimir-alertmanager mimir-ruler loki tempo; do
  az storage container create \
    --name "$c" \
    --account-name "$ACCOUNT" \
    --account-key "$KEY" \
    --public-access off
done
```

Each call prints `{"created": true}`. It is idempotent — re-running against an existing
container returns `created: false` rather than failing.

Verify all five exist and none is public:

```bash
az storage container list --account-name "$ACCOUNT" --account-key "$KEY" \
  --query "[].{name:name,publicAccess:properties.publicAccess}" -o json
```

```json
[
  { "name": "loki",               "publicAccess": null },
  { "name": "mimir-alertmanager", "publicAccess": null },
  { "name": "mimir-blocks",       "publicAccess": null },
  { "name": "mimir-ruler",        "publicAccess": null },
  { "name": "tempo",              "publicAccess": null }
]
```

`publicAccess: null` means private. Anything else is a misconfiguration.

### Step 4 — Create the Kubernetes secret

Skip this step under `localBlobStorage.enabled`. See
[Credentials Secret](#credentials-secret).

One secret, in the namespace you install the platform into. The name is fixed:

```bash
NAMESPACE=monitoring

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic observability-platform-object-storage \
  --namespace "$NAMESPACE" \
  --from-literal=AZURE_STORAGE_KEY="$KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
```

The key name matters. `envFrom` skips any key that is not a valid environment variable
name. A key called `account-key` is dropped silently, and the components come up with no
credentials at all.

The account name is not in the secret. It is not a credential, and the chart needs it at
render time.

### Step 5 — Point the platform chart at it

Set the backend and the account name:

```yaml
global:
  objectStorage:
    backend: azure
    azure:
      accountName: obsplatform
    buckets:
      mimirBlocks: mimir-blocks
      mimirAlertmanager: mimir-alertmanager
      mimirRuler: mimir-ruler
      loki: loki
      tempo: tempo
```

The `buckets` values above are the defaults. With the container names from this guide,
only `backend` and `accountName` are required.

`accountName` has one alternative: `global.objectStorage.azure.connectionString` takes a
full connection string — see [LOCAL_DEV.md](./LOCAL_DEV.md). Tempo does not support it.
With `tempo.enabled`, set `accountName` and the secret from Step 4. The render fails on
`connectionString` with Tempo enabled outside `localBlobStorage`.

Install into the namespace holding the secret from Step 4:

```bash
helm install observability-platform helm/observability-platform \
  --namespace monitoring --values values.yaml
```

### Workload identity

To avoid a long-lived key, give the Mimir, Loki and Tempo service accounts a federated identity
with the **Storage Blob Data Contributor** role on the account, then create it with
`--allow-shared-key-access false` and drop the key from every config. Mimir uses
`azure.user_assigned_id`; Loki uses `object_store.azure.user_assigned_id` with an empty
`account_key`.
This requires an OIDC-enabled cluster, so it is not the default here.

The chart has no interface for this yet — `global.objectStorage` always wires up an
account key. Getting there means overriding the Mimir, Loki and Tempo storage values directly
through raw pass-through, which also means dropping the `${AZURE_STORAGE_KEY}`
references the chart puts in.

## AWS S3 and S3-compatible stores

The `s3` backend covers AWS S3 and any S3-compatible store. These values reach the store:

- `s3.endpoint`: the store endpoint, `host[:port]`, no scheme. Required.
- `s3.region`: the signing region. Set it for AWS S3, or when the store checks the
  signing region.
- `s3.insecure`: `true` reaches the endpoint over plain HTTP. Defaults to `false`.

The credentials Secret holds `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`. See
[Credentials Secret](#credentials-secret).

### AWS S3

```yaml
global:
  objectStorage:
    backend: s3
    s3:
      endpoint: s3.eu-west-1.amazonaws.com
      region: eu-west-1
```

Set `endpoint` to the regional endpoint, `s3.<region>.amazonaws.com`.
Override the bucket names. See [Buckets](#buckets).

### S3-compatible store

```yaml
global:
  objectStorage:
    backend: s3
    s3:
      endpoint: minio.storage.internal:9000
```

Add `region` when the store checks the signing region. Add `insecure: true` when the
endpoint serves plain HTTP.

Install into the namespace holding the credentials Secret:

```bash
helm install observability-platform helm/observability-platform \
  --namespace monitoring --values values.yaml
```

## Custom CA

Use this section when the store presents a certificate from a private CA. The chart has
no CA value. Mount the CA bundle through the subchart values.

Create a ConfigMap with the PEM bundle in the release namespace:

```bash
kubectl create configmap object-storage-ca \
  --namespace monitoring --from-file=ca.crt=./ca.crt
```

Mount it into Mimir and set `SSL_CERT_DIR`:

```yaml
mimir:
  global:
    extraEnv:
      - name: SSL_CERT_DIR
        value: /etc/ssl/object-storage-ca
    extraVolumes:
      - name: object-storage-ca
        configMap:
          name: object-storage-ca
    extraVolumeMounts:
      - name: object-storage-ca
        mountPath: /etc/ssl/object-storage-ca
        readOnly: true
```

Set the same three keys for Loki and Tempo:

| Subchart | Values path |
| --- | --- |
| Mimir | `mimir.global` |
| Loki | `loki.global` |
| Tempo | `tempo.tempo.defaults` |

`SSL_CERT_DIR` adds the bundle to the system roots. Do not set `SSL_CERT_FILE`. Do not
mount the ConfigMap over `/etc/ssl/certs`. Either one removes the system roots. TLS to AWS
S3 and to the AWS STS endpoint then fails with `x509: certificate signed by unknown
authority`.

Restart the pods after a change to the ConfigMap.

## Subchart overrides

The Platform chart sets `backend`, `s3.endpoint`, `s3.region`, `s3.insecure`,
the buckets and the Secret. Set every other S3 option through the subchart values. Examples
are path style, SSE, storage class and signature version.

Each subchart takes its raw component config under `structuredConfig`:

| Subchart | Values path |
| --- | --- |
| Mimir | `mimir.mimir.mimir.structuredConfig` |
| Loki | `loki.loki.loki.structuredConfig` |
| Tempo | `tempo.tempo.tempo.structuredConfig` |

The chart writes its S3 blocks below these paths:

- Mimir: `common.storage.s3`.
- Loki: `storage_config.object_store.s3` and `ruler_storage.s3`.
- Tempo: `storage.trace.s3`.

Helm merges your values into these blocks key by key. Your keys land next to the chart's
keys. A list replaces the chart's list. Leave the chart's own keys unset.

Mimir, Loki and Tempo pick path style by themselves for non-AWS endpoints.

Example: server-side encryption on every component.

```yaml
mimir:
  mimir:
    mimir:
      structuredConfig:
        common:
          storage:
            s3:
              sse:
                type: SSE-S3
loki:
  loki:
    loki:
      structuredConfig:
        storage_config:
          object_store:
            s3:
              sse:
                type: SSE-S3
        ruler_storage:
          s3:
            sse:
              type: SSE-S3
tempo:
  tempo:
    tempo:
      structuredConfig:
        storage:
          trace:
            s3:
              sse:
                type: SSE-S3
```

Check the rendered configs:

```bash
helm template observability-platform helm/observability-platform \
  --namespace monitoring --values values.yaml --values overrides.yaml \
  --show-only charts/mimir/charts/mimir/templates/mimir-config.yaml \
  --show-only charts/loki/charts/loki/templates/config.yaml \
  --show-only charts/tempo/charts/tempo/templates/configmap-tempo.yaml \
  | grep -A 1 'sse:'
```

## Verification

### The chart

Check the storage values the components read:

```bash
kubectl get configmap observability-platform-object-storage \
  --namespace monitoring -o yaml
```

`OBS_BACKEND` names the backend.

Once the platform is running, `mimir-blocks` and `loki` fill within a few minutes.
`mimir-alertmanager` and `mimir-ruler` stay empty until an Alertmanager config or a rule
group exists. Empty is not a failure signal there.

### Azure Blob Storage

Round-trip a blob to prove the credentials work end to end:

```bash
echo ok | az storage blob upload \
  --account-name "$ACCOUNT" --account-key "$KEY" \
  --container-name mimir-blocks --name .connectivity-check \
  --data @- --overwrite

az storage blob download \
  --account-name "$ACCOUNT" --account-key "$KEY" \
  --container-name mimir-blocks --name .connectivity-check \
  --file /tmp/connectivity-check && cat /tmp/connectivity-check

az storage blob delete \
  --account-name "$ACCOUNT" --account-key "$KEY" \
  --container-name mimir-blocks --name .connectivity-check
```

The `cat` prints `ok`. Download needs a seekable target, so `--file /dev/stdout` does
not work — it fails with `Target stream handle must be seekable`.

### AWS S3 and S3-compatible stores

Round-trip an object with the keys from the credentials Secret:

```bash
export AWS_ACCESS_KEY_ID=<access-key-id>
export AWS_SECRET_ACCESS_KEY=<secret-access-key>
ENDPOINT=s3.eu-west-1.amazonaws.com   # s3.endpoint
REGION=eu-west-1                      # s3.region

echo ok | aws s3 cp - s3://mimir-blocks/.connectivity-check \
  --endpoint-url "https://$ENDPOINT" --region "$REGION"

aws s3 cp s3://mimir-blocks/.connectivity-check - \
  --endpoint-url "https://$ENDPOINT" --region "$REGION"

aws s3 rm s3://mimir-blocks/.connectivity-check \
  --endpoint-url "https://$ENDPOINT" --region "$REGION"
```

The second command prints `ok`. Use `http://` with `s3.insecure: true`.
