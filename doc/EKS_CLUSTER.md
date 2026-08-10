# EKS Cluster

The observability platform needs a Kubernetes cluster with persistent volume support
and enough headroom for Mimir, Loki, Grafana and their caches. This guide creates one
on AWS EKS with `eksctl`.

Object storage is provisioned separately — see [OBJECT_STORAGE.md](OBJECT_STORAGE.md).

## What you get

| Component     | Value                                                     |
| ------------- | --------------------------------------------------------- |
| Control plane | EKS 1.36                                                  |
| Nodes         | 3 × t3.xlarge (12 vCPU / 48 GiB total), managed node group |
| Networking    | Dedicated VPC, 3 AZs, public + private subnets, 1 NAT gateway |
| IAM           | OIDC provider enabled, required for IRSA                  |
| Addons        | `vpc-cni`, `coredns`, `kube-proxy`, `aws-ebs-csi-driver`, plus `metrics-server` that `eksctl` adds on its own (see Step 6) |
| Storage       | `gp3` default StorageClass (created manually, see Step 5)  |

Three nodes across three AZs is the minimum that lets Mimir and Loki spread their
ingesters and still tolerate losing one AZ.

### Cost

Roughly **$0.57/hour, about $13–14/day** if left running:

| Item                       | Approx. hourly |
| -------------------------- | -------------- |
| EKS control plane          | $0.10          |
| 3 × t3.xlarge (on-demand)  | $0.40          |
| NAT gateway                | $0.045 + data  |
| 3 × 50 GiB gp3 node volumes| $0.017         |

This is not a cluster to leave running unattended. See [Teardown](#teardown).

## Prerequisites

- `eksctl`
- `aws` CLI, authenticated
- `kubectl`
- IAM permissions to create VPCs, IAM roles, CloudFormation stacks and EKS clusters

Confirm which account you are pointed at before creating anything — cluster creation is
slow and expensive to get wrong:

```bash
aws sts get-caller-identity --output json
aws iam list-account-aliases --output json
```

## Step 1 — Set variables

```bash
CLUSTER=observability-platform
REGION=eu-west-1
K8S_VERSION=1.36
```

Check the version is currently supported, and note its end-of-support date:

```bash
aws eks describe-cluster-versions --region "$REGION" \
  --query "clusterVersions[].{version:clusterVersion,status:versionStatus,eol:endOfStandardSupportDate}" \
  --output table
```

Pick a version in `STANDARD_SUPPORT` with a comfortable runway. Anything in
`EXTENDED_SUPPORT` costs more per hour and is on its way out.

## Step 2 — Write the cluster config

`eksctl` can do this from flags, but a config file is reproducible and reviewable:

```yaml
# cluster.yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: observability-platform
  region: eu-west-1
  version: "1.36"

# Required for IRSA, which the EBS CSI driver depends on — and which you will
# want later if you move object storage off static credentials.
iam:
  withOIDC: true

addons:
  - name: vpc-cni
  - name: coredns
  - name: kube-proxy
  # Without this, PersistentVolumeClaims stay Pending forever. Mimir and Loki
  # both need volumes.
  - name: aws-ebs-csi-driver
    wellKnownPolicies:
      ebsCSIController: true

managedNodeGroups:
  - name: default
    instanceType: t3.xlarge
    desiredCapacity: 3
    minSize: 3
    maxSize: 4
    volumeSize: 50
    volumeType: gp3
    amiFamily: AmazonLinux2023
```

Validate it without creating anything:

```bash
eksctl create cluster -f cluster.yaml --dry-run
```

The dry run prints the fully-defaulted config. Check the availability zones and that
your `addons` and `managedNodeGroups` survived — a typo in a nested key is silently
dropped rather than rejected.

## Step 3 — Create the cluster

```bash
eksctl create cluster -f cluster.yaml
```

**This takes 15–20 minutes and cannot be safely interrupted.** The control plane is
~10 minutes, then addons, then the node group. If you kill `eksctl` partway, the
CloudFormation stacks keep going and you are left with a partial cluster — see
[Recovering from an interrupted create](#recovering-from-an-interrupted-create).

Progress is written as CloudFormation stack events. To watch from another shell:

```bash
eksctl utils describe-stacks --region "$REGION" --cluster "$CLUSTER"
```

## Step 4 — Verify access

`eksctl` writes the kubeconfig entry itself, but to do it explicitly:

```bash
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER"
```

```bash
kubectl get nodes
```

```
NAME                                           STATUS   ROLES    AGE   VERSION
ip-192-168-0-40.eu-west-1.compute.internal     Ready    <none>   2m9s  v1.36.2-eks-bca9cf6
ip-192-168-49-186.eu-west-1.compute.internal   Ready    <none>   2m9s  v1.36.2-eks-bca9cf6
ip-192-168-80-129.eu-west-1.compute.internal   Ready    <none>   2m10s v1.36.2-eks-bca9cf6
```

Confirm you actually have permission on Kubernetes objects, not just on the EKS API:

```bash
kubectl auth can-i '*' '*' --all-namespaces
```

This prints `yes` for the principal that created the cluster, because `eksctl`
defaults to `authenticationMode: API_AND_CONFIG_MAP` and grants the creator admin.

If you adopt a cluster created by **someone else** — or through the AWS console — you
may instead see *"Your current IAM principal doesn't have access to Kubernetes objects
on this cluster."* Grant yourself access:

```bash
aws eks create-access-entry --region "$REGION" --cluster-name "$CLUSTER" \
  --principal-arn "$(aws sts get-caller-identity --query Arn --output text)"

aws eks associate-access-policy --region "$REGION" --cluster-name "$CLUSTER" \
  --principal-arn "$(aws sts get-caller-identity --query Arn --output text)" \
  --access-scope type=cluster \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy
```

Check the addons and the CSI driver registered:

```bash
aws eks list-addons --region "$REGION" --cluster-name "$CLUSTER" --query addons
kubectl get csidrivers
```

```
["aws-ebs-csi-driver","coredns","kube-proxy","vpc-cni"]

NAME              ATTACHREQUIRED   MODES        AGE
ebs.csi.aws.com   true             Persistent   1m
efs.csi.aws.com   false            Persistent   6h
```

The provisioner name is **`ebs.csi.aws.com`**. Do not confuse it with
`ebs.csi.eks.amazonaws.com`, which belongs to EKS Auto Mode — a StorageClass naming the
wrong one leaves every PVC `Pending` with no obvious error.

## Step 5 — Create a default StorageClass

EKS gives you a `gp2` StorageClass that is **not usable**:

```bash
kubectl get sc -o custom-columns='NAME:.metadata.name,PROVISIONER:.provisioner,DEFAULT:.metadata.annotations.storageclass\.kubernetes\.io/is-default-class'
```

```
NAME   PROVISIONER             DEFAULT
gp2    kubernetes.io/aws-ebs   <none>
```

Two problems: `kubernetes.io/aws-ebs` is the in-tree provisioner, removed from
Kubernetes well before 1.36, so nothing will service it; and there is no default class
at all, so a PVC without an explicit `storageClassName` never binds.

Create a `gp3` class and make it the default:

```bash
kubectl apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  encrypted: "true"
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
allowVolumeExpansion: true
EOF
```

`WaitForFirstConsumer` matters on a multi-AZ cluster: it delays provisioning until the
pod is scheduled, so the volume is created in the AZ that actually needs it. Binding
immediately can strand a volume in an AZ with no room for the pod.

Verify a volume really provisions end to end, rather than assuming:

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: storage-check
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
EOF

kubectl run storage-check --image=public.ecr.aws/docker/library/busybox:latest \
  --overrides='{"spec":{"containers":[{"name":"c","image":"public.ecr.aws/docker/library/busybox:latest","command":["sh","-c","echo ok > /data/f && cat /data/f && sleep 5"],"volumeMounts":[{"name":"v","mountPath":"/data"}]}],"volumes":[{"name":"v","persistentVolumeClaim":{"claimName":"storage-check"}}]}}' \
  --restart=Never

kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/storage-check --timeout=120s
kubectl logs storage-check
kubectl delete pod storage-check; kubectl delete pvc storage-check
```

A `Bound` PVC and `ok` in the logs means dynamic provisioning, attachment and mount all
work. If the PVC stays `Pending`, run
`kubectl describe pvc storage-check` and read the events — that is where the real error
appears, including KMS failures (see below).

## Step 6 — Confirm metrics-server

Check before installing anything — `eksctl` 0.229 adds a `metrics-server` addon on its
own, even though `cluster.yaml` does not ask for one:

```bash
aws eks list-addons --region "$REGION" --cluster-name "$CLUSTER" --query addons
kubectl top nodes
```

If `metrics-server` is in that list and `kubectl top nodes` prints numbers, this step is
already done — skip to [What the platform actually uses](#what-the-platform-actually-uses).
Applying the upstream manifest over the addon gives you two managers of the same
Deployment.

The rest of this step is for clusters where it is absent, which includes older `eksctl`
and any cluster not created by `eksctl`.

Nothing in such a cluster serves `metrics.k8s.io`, and that is not only a missing
convenience:

- **The platform's HorizontalPodAutoscalers cannot work without it.** Loki's write, read,
  backend and gateway components are autoscaled, as are Mimir's distributor and querier.
  With no metrics API their targets read `<unknown>` and they never scale in either
  direction — they simply sit at `minReplicas` forever, silently.
- **`kubectl top` fails**, so you cannot see what the platform actually consumes against
  what it requests, which is how the chart's sizing was decided.

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

kubectl -n kube-system rollout status deploy/metrics-server --timeout=180s
```

No extra flags are needed on EKS — the kubelet serving certificates are signed by the
cluster CA, so the usual `--kubelet-insecure-tls` workaround does not apply here.

Confirm it serves:

```bash
kubectl top nodes
```

```
NAME                                           CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
ip-192-168-26-241.eu-west-1.compute.internal   156m         3%       1104Mi          7%
ip-192-168-63-253.eu-west-1.compute.internal   358m         9%       1374Mi          9%
ip-192-168-73-108.eu-west-1.compute.internal   138m         3%       1471Mi          9%
```

`error: Metrics API not available` means it is not up yet — it takes 15-30 seconds after
the rollout finishes before the first scrape lands.

Once the platform is installed, the same check confirms the autoscalers have real numbers
to work with:

```bash
kubectl get hpa -n monitoring
```

Any HPA showing `<unknown>` in its targets column is not autoscaling. A missing metrics
API is one cause; the other is an HPA whose `scaleTargetRef` names a workload that does
not exist, which looks identical here. `REPLICAS 0` alongside `<unknown>` points at the
second, and the condition names it:

```bash
kubectl get hpa -n monitoring -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.status.conditions[?(@.type=="AbleToScale")].reason}{"\n"}{end}'
```

`FailedGetScale` is a broken reference, not a metrics problem — the message names the
workload it cannot find. Any other reason is healthy: `ReadyForNewScale` and
`ScaleDownStabilized` both mean the target was read fine. All seven HPAs should report one
of those.

## What the platform actually uses

Measured on this cluster with the platform installed and idle — nothing writing to Mimir or
Loki yet. Keep these honest about each other: if the chart's requests grow past what three
nodes allocate, this guide is what has to change.

| | 3 × t3.xlarge allocatable | Platform requests | Observed, idle |
|---|---|---|---|
| CPU | 11.76 vCPU | 4.20 vCPU | 0.18 vCPU |
| Memory | 43.3 GiB | 26.4 GiB | 1.2 GiB |

29 pods, all Ready, nothing Pending. Allocatable is what is left after the kubelet reserve —
3920m and 14.4 GiB per node, not the 4 vCPU and 16 GiB the instance type advertises.

Observed is a floor, not a sizing basis: with no ingest, Mimir's ingesters use 90 MiB against
the 12 GiB they request. The requests exist for when data flows.

Two things about this measurement that are easy to get wrong:

- **`kubectl top` needs metrics-server** (Step 6). Without it there are no numbers at all.
- **Do not estimate from `helm template`.** The rendered manifests omit `spec.replicas` for
  every Loki component, so summing them undercounts: the template implies one replica each
  while the cluster runs two. The floor comes from HPA `minReplicas`, and the ceiling from
  `maxReplicas` — which the chart caps, because the defaults allowed one component to grow to
  30 GiB on a 43 GiB cluster.

Headroom is roughly 7.5 vCPU and 17 GiB. That is what self-monitoring, an ingress controller
and any query load have to fit into.

## Troubleshooting

### Nodes launch and immediately terminate

Symptom: the node group sits in `CREATE_IN_PROGRESS` for far longer than the usual 3–5
minutes, `aws eks describe-nodegroup` reports no health issues, and EC2 shows waves of
instances that all reach `terminated`.

Read an instance's termination reason — the node group status will not tell you:

```bash
aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:eks:cluster-name,Values=$CLUSTER" \
  --query "Reservations[].Instances[].{id:InstanceId,state:State.Name,reason:StateReason.Message}" \
  --output json
```

If the reason is `Client.InvalidKMSKey.InvalidState`, the region has EBS
encryption-by-default enabled pointing at a KMS key that is disabled, pending deletion,
or gone. Every EBS volume creation fails, so no instance can boot:

```bash
aws ec2 get-ebs-encryption-by-default --region "$REGION"
KEYID=$(aws ec2 get-ebs-default-kms-key-id --region "$REGION" --query KmsKeyId --output text)
aws kms describe-key --region "$REGION" --key-id "$KEYID"
```

A `NotFoundException` on that last command confirms it.

The clean fix is to repoint the region's default at the AWS-managed EBS key. This is an
account-wide, per-region setting, so it needs whoever owns the account:

```bash
aws ec2 reset-ebs-default-kms-key-id --region "$REGION"
```

If you cannot change the account setting, scope a workaround to your node group by
pinning a key you know is valid. Add to the `managedNodeGroups` entry:

```yaml
    volumeEncrypted: true
    volumeKmsKeyID: arn:aws:kms:<region>:<account-id>:key/<aws-managed-ebs-key-id>
```

Resolve the AWS-managed key's ARN with:

```bash
aws kms describe-key --region "$REGION" --key-id alias/aws/ebs \
  --query KeyMetadata.Arn --output text
```

This only covers node root volumes. **Dynamically provisioned PVCs go through the EBS
CSI driver and will hit the same broken default key**, so also set `kmsKeyId` in the
StorageClass `parameters` — otherwise nodes boot but every PVC fails to provision.

### Recovering from an interrupted create

Killing `eksctl` does not stop CloudFormation. To see what survived:

```bash
aws cloudformation list-stacks --region "$REGION" \
  --query "StackSummaries[?starts_with(StackName,'eksctl-$CLUSTER') && StackStatus!='DELETE_COMPLETE'].{name:StackName,status:StackStatus}" \
  --output table
```

A control plane in `CREATE_COMPLETE` is worth keeping — it is the slowest part. You can
add the rest separately:

```bash
eksctl create nodegroup -f cluster.yaml   # node group only
eksctl create addon -f cluster.yaml       # addons only; skips ones already present
```

Two traps here:

- **Addons declared in the config are not installed if the interruption happened before
  the addon phase.** Always re-run `eksctl create addon -f cluster.yaml` and re-check
  `aws eks list-addons` after an interrupted create. A missing `aws-ebs-csi-driver` does
  not surface until the first PVC hangs.
- **A node group stack in `ROLLBACK_COMPLETE` must be deleted before retrying**, and
  `eksctl` enables termination protection on it:

```bash
aws cloudformation update-termination-protection --region "$REGION" \
  --stack-name "eksctl-$CLUSTER-nodegroup-default" --no-enable-termination-protection
aws cloudformation delete-stack --region "$REGION" \
  --stack-name "eksctl-$CLUSTER-nodegroup-default"
```

### PVCs stay Pending

Check, in order: that `ebs.csi.aws.com` appears in `kubectl get csidrivers`; that a
default StorageClass exists; that the StorageClass provisioner is `ebs.csi.aws.com` and
not `ebs.csi.eks.amazonaws.com`; then `kubectl describe pvc <name>` for the provisioner's
own error.

## Teardown

Deletes the cluster, node group, VPC, NAT gateway and IAM roles:

```bash
eksctl delete cluster --name "$CLUSTER" --region "$REGION" --wait
```

Confirm nothing is left, since orphaned NAT gateways and volumes keep billing:

```bash
aws cloudformation list-stacks --region "$REGION" \
  --query "StackSummaries[?starts_with(StackName,'eksctl-$CLUSTER') && StackStatus!='DELETE_COMPLETE'].StackName" \
  --output json

aws ec2 describe-volumes --region "$REGION" \
  --filters "Name=status,Values=available" --query "Volumes[].VolumeId" --output json
```

Object storage lives outside the cluster and is **not** removed by this — delete it
separately if you are done with the data.
