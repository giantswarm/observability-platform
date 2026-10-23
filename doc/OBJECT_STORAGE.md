# Object Storage

The observability platform stores metrics, alerting state, recording rules, logs and traces
in object storage. Mimir, Loki and Tempo read it.

The chart supports two backends:

- `azure`: Azure Blob Storage.
- `s3`: AWS S3, or an S3-compatible store.

One value, `global.objectStorage.backend`, picks the backend for Mimir, Loki and Tempo
together. It has no default.

For development you need none of this. `localObjectStorage.enabled` runs a store in the
cluster: Garage for `s3`, Azurite for `azure`. See [LOCAL_DEV.md](./LOCAL_DEV.md).

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
| `s3.store` | `s3` | `aws` or `compatible`. Required. No default. |
| `s3.endpoint` | `s3` | Store endpoint, `host[:port]`, no scheme. Required. |
| `s3.region` | `s3` | Signing region. Required with `store: aws`. Optional with `store: compatible`. |
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
| 2 | `backend` is `s3` and `s3.store` is unset, or not `aws` or `compatible`. |
| 3 | `backend` is `s3` and `s3.endpoint` is empty. Skipped under Garage. |
| 4 | `s3.store` is `aws` and `s3.region` is empty. |
| 5 | `localObjectStorage.enabled` is set and `s3.store` is `aws`. |
| 6 | `backend` is `s3` and `azure.accountName` or `azure.connectionString` is set. |
| 7 | `backend` is `azure` and `s3.store`, `s3.endpoint` or `s3.region` is set, or `s3.insecure` is `true`. |
| Garage | Garage runs and `s3.endpoint` or `s3.region` is set. |

Empty strings and `insecure: false` count as unset. The defaults never trip guards 6 and 7.

The messages, as `helm template` prints them:

1. `global.objectStorage.backend is "". Set it to "azure" or "s3" - see doc/OBJECT_STORAGE.md.`
2. `global.objectStorage.s3.store must be "aws" or "compatible" with backend "s3", but it is "" - see doc/OBJECT_STORAGE.md.`
3. `global.objectStorage.backend is "s3" and global.objectStorage.s3.endpoint is empty. Set it to the store endpoint, host[:port] without a scheme - see doc/OBJECT_STORAGE.md.`
4. `global.objectStorage.s3.store is "aws" and global.objectStorage.s3.region is empty. Set it to the AWS region of the buckets - see doc/OBJECT_STORAGE.md.`
5. `localObjectStorage.enabled runs Garage, an S3-compatible store, but global.objectStorage.s3.store is "aws". Set it to "compatible", or unset localObjectStorage.enabled - see doc/LOCAL_DEV.md.`
6. `global.objectStorage.backend is "s3", but global.objectStorage.azure.accountName is set. Unset it: the s3 backend reads no Azure values - see doc/OBJECT_STORAGE.md.`
7. `global.objectStorage.backend is "azure", but global.objectStorage.s3.region is set. Unset it: the azure backend reads no S3 values - see doc/OBJECT_STORAGE.md.`
8. Garage: `localObjectStorage.enabled runs Garage and computes global.objectStorage.s3.endpoint, but it is set as well and would be ignored. Unset one of the two - see doc/LOCAL_DEV.md.`

Guards 6, 7 and the Garage guard name the key that is set: `accountName` or
`connectionString`; `store`, `endpoint`, `region` or `insecure`; `endpoint` or `region`.

With `backend: azure`, the Azure guards run as well:

- `global.objectStorage.azure.accountName is empty. Set it to the Azure storage account holding the containers, or set global.objectStorage.azure.connectionString to reach an endpoint of your own, or set localObjectStorage.enabled to run against a local Azurite emulator - see doc/OBJECT_STORAGE.md.`
- `tempo.enabled is true and global.objectStorage.azure.connectionString is set. Tempo reads no connection string: it needs global.objectStorage.azure.accountName and the account key in the credentials Secret. Set accountName instead of connectionString, or set tempo.enabled to false - see doc/OBJECT_STORAGE.md.`
- Two Azurite guards fail on `azure.accountName` or `azure.connectionString` set next to
  `localObjectStorage.enabled`. See [LOCAL_DEV.md](./LOCAL_DEV.md).

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
| `OBS_LOKI_THANOS` | `false` | `true` with `store: compatible`, else `false` |

Under `localObjectStorage.enabled` the chart computes the Azurite or Garage values instead.
See [LOCAL_DEV.md](./LOCAL_DEV.md).

How the values reach the components:

1. The chart renders the ConfigMap above.
2. The ConfigMap and the credentials Secret reach the Mimir, Loki and Tempo pods as
   environment variables, through `extraEnvFrom`. No other pod gets them.
3. The component configs read `${OBS_*}` references. The Mimir and Loki charts run every
   component with `-config.expand-env=true`. The chart adds the flag to every Tempo
   component.

Every component config carries both an `azure` and an `s3` block. The `backend` fields read
`${OBS_BACKEND}`, so the backend is picked at startup. Mimir and Tempo ignore `s3.store`.

### Loki storage client

Loki has two storage clients. `s3.store` picks one through `OBS_LOKI_THANOS`:

| Backend | Store | Loki client | `OBS_LOKI_THANOS` |
| --- | --- | --- | --- |
| `azure` | Azure Blob Storage, Azurite | Loki's default client | `false` |
| `s3` | `aws` | Loki's default client | `false` |
| `s3` | `compatible`, Garage | Loki thanos mode | `true` |

Loki's `storage_config.use_thanos_objstore` reads `${OBS_LOKI_THANOS}`. Loki thanos mode
avoids the forced trailing checksums of Loki's default client. Many S3-compatible stores
reject them ([grafana/loki#21926](https://github.com/grafana/loki/issues/21926)).

Loki validates both client configs at every start. The ruler logs a warning about the
unused one.

### Credentials Secret

The operator creates one Secret in the release namespace. The chart never renders it.

- Name: `observability-platform-object-storage`, the `existingSecret` value.
- Keys for `azure`: `AZURE_STORAGE_KEY`.
- Keys for `s3`: `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`.

The keys reach the pods as environment variables, so each key name must be a valid variable
name. The pods reference the Secret with `optional: true`.

Under `localObjectStorage.enabled` the chart renders its own dev Secret instead:
`garage-credentials` for Garage, `azurite-credentials` for Tempo on Azurite.

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
`localObjectStorage.enabled`.

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

Under `localObjectStorage.enabled` the chart renders the dev Secret `garage-credentials`
with the same two key names. The local setup exercises the same path.

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
- Mimir and Loki thanos mode fall back to anonymous requests. The store rejects them, and
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

#### EKS Pod Identity

EKS Pod Identity is untested with this chart
([thanos-io/objstore#131](https://github.com/thanos-io/objstore/issues/131)). IRSA is
the supported path.

The Pod Identity agent injects `AWS_CONTAINER_CREDENTIALS_FULL_URI` and
`AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE` into the pods. The minio-go IAM provider and the
aws-sdk-go-v2 default chain both read these two variables. Remove both keys from the
Secret before you try it.

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

Skip this step under `localObjectStorage.enabled`. See
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
`connectionString` with Tempo enabled outside `localObjectStorage`.

Install into the namespace holding the secret from Step 4:

```bash
helm install observability-platform helm/observability-platform \
  --namespace monitoring --values values.yaml
```

Loki runs its default client against Azure Blob Storage.

### Workload identity

To avoid a long-lived key, give the Mimir, Loki and Tempo service accounts a federated identity
with the **Storage Blob Data Contributor** role on the account, then create it with
`--allow-shared-key-access false` and drop the key from every config. Mimir uses
`azure.user_assigned_id`; Loki uses `azure.useManagedIdentity` with `userAssignedId`.
This requires an OIDC-enabled cluster, so it is not the default here.

The chart has no interface for this yet — `global.objectStorage` always wires up an
account key. Getting there means overriding the Mimir, Loki and Tempo storage values directly
through raw pass-through, which also means dropping the `${AZURE_STORAGE_KEY}`
references the chart puts in.

## AWS S3 and S3-compatible stores

The `s3` backend covers AWS S3 and any S3-compatible store. `s3.store` names which one:

| `s3.store` | Store | Loki client |
| --- | --- | --- |
| `aws` | AWS S3 | Loki's default client |
| `compatible` | Any other S3 API, for example an on-prem store | Loki thanos mode |

`s3.store` picks Loki's client only. Mimir and Tempo use the same client for both stores.

The other values reach the store:

- `s3.endpoint`: the store endpoint, `host[:port]`, no scheme. Required.
- `s3.region`: the signing region. Required with `store: aws`. Set it with
  `store: compatible` when the store checks the signing region.
- `s3.insecure`: `true` reaches the endpoint over plain HTTP. Defaults to `false`.

The credentials Secret holds `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`. See
[Credentials Secret](#credentials-secret).

### AWS S3

```yaml
global:
  objectStorage:
    backend: s3
    s3:
      store: aws
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
      store: compatible
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

Use this section when the store presents a certificate from a private CA.

The Platform chart has no CA value, no CA ConfigMap and no CA mount. Mount the CA bundle
through the subchart values of Mimir, Loki and Tempo.

Create a ConfigMap with the PEM bundle in the release namespace:

```bash
kubectl create configmap object-storage-ca \
  --namespace monitoring --from-file=ca.crt=./ca.crt
```

The bundle may hold several PEM certificates, for example a root and an intermediate CA.

Mount the ConfigMap into each subchart. `SSL_CERT_DIR` points the components at the mount:

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
loki:
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
tempo:
  tempo:
    defaults:
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

| Subchart | Values path | Workloads reached | Mount path |
| --- | --- | --- | --- |
| Mimir | `mimir.global.extraVolumes`, `.extraVolumeMounts`, `.extraEnv` | All Mimir workloads, including `mimir-gateway` and the `mimir-smoke-test` Job | `/etc/ssl/object-storage-ca` |
| Loki | `loki.global.extraVolumes`, `.extraVolumeMounts`, `.extraEnv` | `loki-read`, `loki-write`, `loki-backend` | `/etc/ssl/object-storage-ca` |
| Tempo | `tempo.tempo.defaults.extraVolumes`, `.extraVolumeMounts`, `.extraEnv` | All Tempo components except `tempo-memcached` | `/etc/ssl/object-storage-ca` |

Workloads without bucket access ignore the mount and the variable:

- `mimir-gateway`: nginx. It gets the mount and the variable.
- `loki-chunks-cache` and `loki-results-cache`: memcached. They get the variable only.
- `loki-gateway` and `tempo-memcached`: they get neither.

Helm merges the subchart maps. The chart's `extraEnvFrom` under `mimir.global`,
`loki.global` and `tempo.tempo.defaults` stays in place.

The Mimir, Loki and Tempo images keep their system roots in
`/etc/ssl/certs/ca-certificates.crt`. The mount uses a separate directory and leaves that
file in place.

`SSL_CERT_DIR` adds the CA bundle to the system roots. It does not replace them. Go reads
the roots from two sources:

- The roots file `/etc/ssl/certs/ca-certificates.crt`. `SSL_CERT_FILE` replaces it.
- Every file in the roots directories. `SSL_CERT_DIR` replaces the default directories.

The guide sets `SSL_CERT_DIR` only. Go reads the roots file and every file in
`/etc/ssl/object-storage-ca`. Public endpoints keep working, for example the AWS STS
endpoint that IRSA calls for credentials.

Keep the system roots in place:

- Do not set `SSL_CERT_FILE`. Together with `SSL_CERT_DIR`, it leaves the CA bundle as the
  only root. TLS to STS and to AWS S3 then fails with `x509: certificate signed by unknown
  authority`.
- Do not mount the ConfigMap over `/etc/ssl/certs`. The mount hides the roots file.
- Do not set the components' own CA fields. Each one replaces the system roots for the
  storage client. The IRSA credential client ignores them.

| Component | CA field |
| --- | --- |
| Mimir | `common.storage.s3.http.tls_ca_path` |
| Loki thanos mode | `storage_config.object_store.s3.http.tls_ca_path` |
| Loki's default client | `storage_config.aws.http_config.ca_file` |
| Tempo | `storage.trace.s3.tls_ca_path` |

Restart the pods after a change to the ConfigMap. The components read the roots at startup.

## Subchart overrides

The Platform chart sets `backend`, `s3.store`, `s3.endpoint`, `s3.region`, `s3.insecure`,
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
- Loki's default client: `storage_config.aws`.
- Loki thanos mode: `storage_config.object_store.s3`.
- Tempo: `storage.trace.s3`.

Helm merges your values into these blocks key by key. Your keys land next to the chart's
keys. A list replaces the chart's list. Leave the chart's own keys unset.

Example: force path style on Mimir.

```yaml
mimir:
  mimir:
    mimir:
      structuredConfig:
        common:
          storage:
            s3:
              bucket_lookup_type: path
```

Check the rendered Mimir config:

```bash
helm template observability-platform helm/observability-platform \
  --namespace monitoring --values values.yaml --values overrides.yaml \
  --show-only charts/mimir/charts/mimir/templates/mimir-config.yaml \
  | grep -A 3 bucket_lookup_type
```

```text
          bucket_lookup_type: path
          endpoint: ${OBS_S3_ENDPOINT}
          insecure: ${OBS_S3_INSECURE}
          region: ${OBS_S3_REGION}
```

Mimir, Tempo and Loki thanos mode pick path style by themselves for non-AWS endpoints.
Loki's default client needs `s3forcepathstyle: true` on an S3-compatible store.

<!-- Story 25 adds the per-component override table here. -->

<!-- Story 29 adds "## Switching backend" here. -->

## Verification

### The chart

Check the storage values the components read:

```bash
kubectl get configmap observability-platform-object-storage \
  --namespace monitoring -o yaml
```

`OBS_BACKEND` names the backend. `OBS_LOKI_THANOS` is `true` only with
`store: compatible`.

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

Confirm the account is not reachable without credentials:

```bash
curl -s "https://$ACCOUNT.blob.core.windows.net/loki/probe"
curl -s "http://$ACCOUNT.blob.core.windows.net/loki/probe"
```

Expect `PublicAccessNotPermitted` for the first and `AccountRequiresHttps` for the
second. Any other response means `--allow-blob-public-access false` or `--https-only`
did not take effect.

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

## Teardown

### Azure Blob Storage

Deleting the account deletes every container and all data in it:

```bash
az storage account delete --name "$ACCOUNT" --resource-group "$RESOURCE_GROUP" --yes
```

To drop a single component's data without touching the rest:

```bash
az storage container delete --name mimir-ruler \
  --account-name "$ACCOUNT" --account-key "$KEY"
```

A deleted container name stays unavailable for up to 30 seconds afterwards, so a
scripted delete-then-recreate needs a retry.

### AWS S3 and S3-compatible stores

Deleting a bucket with `--force` deletes every object in it first:

```bash
for b in mimir-blocks mimir-alertmanager mimir-ruler loki tempo; do
  aws s3 rb "s3://$b" --force \
    --endpoint-url "https://$ENDPOINT" --region "$REGION"
done
```

Use the bucket names from your `buckets` values. To drop a single component's data, delete
only its bucket.
