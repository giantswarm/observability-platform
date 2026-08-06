# Object Storage

The observability platform stores metrics, alerting state, recording rules and logs in
Azure Blob Storage, which is the only backend it supports. This guide provisions that
storage with the Azure CLI and hands it to the platform chart, which configures Mimir
and Loki from it.

## Layout

Use **a single storage account** with **one container per component that needs one**.
Containers are already an isolation boundary within an account, so splitting across
several accounts only adds key sets to rotate and endpoints to manage.

| Container            | Consumer                     | Contents                           |
| -------------------- | ---------------------------- | ---------------------------------- |
| `mimir-blocks`       | Mimir `blocks_storage`       | TSDB blocks (the bulk of the data) |
| `mimir-alertmanager` | Mimir `alertmanager_storage` | Alertmanager state and configs     |
| `mimir-ruler`        | Mimir `ruler_storage`        | Recording and alerting rule groups |
| `loki`               | Loki chunks, index, ruler, admin | Log data                       |

Tempo and Pyroscope are not covered here. When you add them, give each its own
container in the same account.

### Account settings

| Setting            | Value          | Why                                                      |
| ------------------ | -------------- | -------------------------------------------------------- |
| Kind               | `StorageV2`    | Required for blob access tiers                           |
| SKU                | `Standard_LRS` | Locally redundant; cheapest tier Mimir supports. Use `Standard_ZRS` if you need zone redundancy |
| Access tier        | `Hot`          | Blocks are read constantly by queriers and the compactor |
| Minimum TLS        | `TLS1_2`       | Reject legacy TLS                                        |
| HTTPS only         | `true`         | No plaintext access                                      |
| Blob public access | `false`        | No container is ever public                              |
| Shared key access  | `true`         | Mimir and Loki authenticate with the account key         |

Shared key access means a long-lived credential in a Kubernetes secret with no built-in
rotation. If your environment supports it, prefer Azure Workload Identity and disable
shared key access — see [Alternative: workload identity](#alternative-workload-identity).

## Prerequisites

- `az` CLI, logged in (`az login`)
- `Contributor` on the target resource group
- An existing resource group, or permission to create one

## Step 1 — Set variables

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

## Step 2 — Create the storage account

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

## Step 3 — Create the containers

Fetch the account key once and reuse it:

```bash
KEY=$(az storage account keys list \
  --account-name "$ACCOUNT" --resource-group "$RESOURCE_GROUP" \
  --query "[0].value" -o tsv)
```

```bash
for c in mimir-blocks mimir-alertmanager mimir-ruler loki; do
  az storage container create \
    --name "$c" \
    --account-name "$ACCOUNT" \
    --account-key "$KEY" \
    --public-access off
done
```

Each call prints `{"created": true}`. It is idempotent — re-running against an existing
container returns `created: false` rather than failing.

Verify all four exist and none is public:

```bash
az storage container list --account-name "$ACCOUNT" --account-key "$KEY" \
  --query "[].{name:name,publicAccess:properties.publicAccess}" -o json
```

```json
[
  { "name": "loki",               "publicAccess": null },
  { "name": "mimir-alertmanager", "publicAccess": null },
  { "name": "mimir-blocks",       "publicAccess": null },
  { "name": "mimir-ruler",        "publicAccess": null }
]
```

`publicAccess: null` means private. Anything else is a misconfiguration.

## Step 4 — Create the Kubernetes secret

One secret, in the namespace you install the platform into. The name is fixed:

```bash
NAMESPACE=monitoring

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic observability-platform-object-storage \
  --namespace "$NAMESPACE" \
  --from-literal=AZURE_STORAGE_KEY="$KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
```

Both the secret name and the key name matter:

- **`observability-platform-object-storage`** — the Mimir and Loki subcharts name this
  secret from static values, and Helm will not let the umbrella chart compute a
  subchart's values, so the name cannot be configurable. Setting
  `global.objectStorage.existingSecret` to anything else fails the render.
- **`AZURE_STORAGE_KEY`** — the key reaches the pods through `envFrom`, which skips any
  key that is not a valid environment variable name. A key called `account-key` is
  dropped silently and the components come up with no credentials at all.

The account name is deliberately not in the secret. It is not a credential, and the
chart needs it at render time.

## Step 5 — Point the platform chart at it

The chart configures Mimir and Loki for you. All it needs is the account name and, if
you renamed anything, the container names:

```yaml
global:
  objectStorage:
    azure:
      accountName: obsplatform
    buckets:
      mimirBlocks: mimir-blocks
      mimirAlertmanager: mimir-alertmanager
      mimirRuler: mimir-ruler
      loki: loki
```

The `buckets` values above are the defaults, so with the container names from this guide
only `accountName` is actually required. Leave it out and the render fails rather than
installing something that cannot reach its storage.

Install into the namespace holding the secret from Step 4:

```bash
helm install observability-platform . --namespace monitoring
```

What the chart does with this, so it is not a black box: it renders the container names
and account name into a ConfigMap, injects that ConfigMap and your secret as environment
variables into the Mimir and Loki pods only, and points
`blocks_storage`, `alertmanager_storage`, `ruler_storage` and Loki's `storage`,
`schemaConfig` and `bucketNames` at them. Both charts already run every component with
`-config.expand-env=true`, so nothing extra is needed to expand the references.

All three Loki `bucketNames` point at the same `loki` container. They become key prefixes
inside the container rather than separate containers, so one serves all three without
collision.

Two things the chart does not set, and you may want through raw subchart pass-through:

- **Loki retention.** `compactor.retention_enabled: true` also requires
  `compactor.delete_request_store: azure`, otherwise deletion requests have nowhere to
  live.
- **A later schema period.** The chart pins `from: 2024-04-01`. A new period cannot start
  in the past relative to data already written under a different schema, so if you add
  one, date it forward.

## Verification

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

Once the platform is running, `mimir-blocks` and `loki` fill within a few minutes.
`mimir-alertmanager` and `mimir-ruler` stay empty until an Alertmanager config or a rule
group exists — empty is not a failure signal there.

## Alternative: workload identity

To avoid a long-lived key, give the Mimir and Loki service accounts a federated identity
with the **Storage Blob Data Contributor** role on the account, then create it with
`--allow-shared-key-access false` and drop the key from both configs. Mimir uses
`azure.user_assigned_id`; Loki uses `azure.useManagedIdentity` with `userAssignedId`.
This requires an OIDC-enabled cluster, so it is not the default here.

The chart has no interface for this yet — `global.objectStorage` always wires up an
account key. Getting there means overriding the Mimir and Loki storage values directly
through raw pass-through, which also means dropping the `${AZURE_STORAGE_KEY}`
references the chart puts in.

## Teardown

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
