# Gateway

The external API and Grafana are served through a Gateway you provide. This guide prepares
one on the cluster from [EKS_CLUSTER.md](EKS_CLUSTER.md):

- Envoy Gateway
- cert-manager, with Gateway API support
- a Gateway with an HTTPS listener named `https` for `observability.<domain>`
- a Let's Encrypt certificate for that listener
- a DNS record for `observability.<domain>`

The chart configures the API itself. See [EXTERNAL_API.md](EXTERNAL_API.md).

## What you get

| Component | Value |
| --- | --- |
| Envoy Gateway | 1.9.2, in `envoy-gateway-system`, with the Gateway API CRDs |
| cert-manager | v1.21.2, in `cert-manager`, started with `--enable-gateway-api` |
| GatewayClass | `envoy-gateway` |
| Gateway | `giantswarm-default` in `envoy-gateway-system` |
| Listeners | `http` on port 80, `https` on port 443, both for `observability.<domain>` |
| Certificate | Let's Encrypt, HTTP-01, Secret `observability-https-tls` |
| Load balancer | AWS Classic Load Balancer, created for the Envoy Service |

The Gateway name, namespace and listener name match the chart's default `parentRefs`. The
chart's routes attach to it without overrides. See
[Point the routes at your Gateway](EXTERNAL_API.md#point-the-routes-at-your-gateway).

The `http` listener serves the ACME HTTP-01 challenge. It accepts routes from the
`envoy-gateway-system` namespace only. The chart's routes attach to `https` only.

## Prerequisites

- A cluster from [EKS_CLUSTER.md](EKS_CLUSTER.md), with `kubectl` pointed at it
- `helm` 3.8 or later
- `aws` CLI, authenticated
- A domain with a Route53 hosted zone. Another DNS provider works: create the record by hand
  in [Step 6](#step-6--create-the-dns-record).
- An email address for the Let's Encrypt account

## Step 1 — Set variables

```bash
REGION=eu-west-1
DOMAIN=example.com
OBS_HOST=observability.$DOMAIN
HOSTED_ZONE_ID=<route53-hosted-zone-id>
ACME_EMAIL=<you@example.com>
```

`DOMAIN` is the chart's `global.domain`.

## Step 2 — Install Envoy Gateway

```bash
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm --version 1.9.2 \
  --namespace envoy-gateway-system --create-namespace --wait --timeout 10m
```

The chart installs the Gateway API CRDs and the Envoy Gateway CRDs.

Reference: [Install with Helm](https://gateway.envoyproxy.io/docs/install/install-helm/).

```bash
kubectl get crd gateways.gateway.networking.k8s.io securitypolicies.gateway.envoyproxy.io
kubectl -n envoy-gateway-system rollout status deploy/envoy-gateway
```

## Step 3 — Install cert-manager

Install cert-manager after Envoy Gateway. cert-manager detects the Gateway API CRDs at
start-up only. `--enable-gateway-api` turns on its Gateway API support. See
[Certificate from cert-manager](EXTERNAL_API.md#certificate-from-cert-manager).

Reference: [Helm installation](https://cert-manager.io/docs/installation/helm/),
[Gateway API usage](https://cert-manager.io/docs/usage/gateway/).

```bash
helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager --version v1.21.2 \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true \
  --set 'extraArgs={--enable-gateway-api}' \
  --wait --timeout 10m
```

Check the flag reached the controller:

```bash
kubectl -n cert-manager get deploy cert-manager \
  -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | grep gateway
```

```
"--enable-gateway-api"
```

If the Gateway API CRDs were installed after cert-manager, restart it:

```bash
kubectl -n cert-manager rollout restart deploy/cert-manager
```

## Step 4 — Create the ClusterIssuer

```bash
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: $ACME_EMAIL
    privateKeySecretRef:
      name: letsencrypt-account-key
    solvers:
      - http01:
          gatewayHTTPRoute:
            parentRefs:
              - kind: Gateway
                name: giantswarm-default
                namespace: envoy-gateway-system
                sectionName: http
EOF
```

```bash
kubectl wait --for=condition=Ready clusterissuer/letsencrypt --timeout=120s
```

For a dry run, use the staging server `https://acme-staging-v02.api.letsencrypt.org/directory`.
Staging certificates are not trusted by clients.

Reference: [HTTP01 solver](https://cert-manager.io/docs/configuration/acme/http01/),
[Let's Encrypt staging](https://letsencrypt.org/docs/staging-environment/).

## Step 5 — Create the Gateway

```bash
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: envoy-gateway
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: giantswarm-default
  namespace: envoy-gateway-system
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
spec:
  gatewayClassName: envoy-gateway
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      hostname: $OBS_HOST
      allowedRoutes:
        namespaces:
          from: Same
    - name: https
      protocol: HTTPS
      port: 443
      hostname: $OBS_HOST
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: observability-https-tls
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
EOF
```

cert-manager creates the Certificate `observability-https-tls` in `envoy-gateway-system`. See
[Certificate from cert-manager](EXTERNAL_API.md#certificate-from-cert-manager).

Reference: [Secure Gateways using cert-manager](https://gateway.envoyproxy.io/docs/tasks/security/tls-cert-manager/).

Wait for the load balancer:

```bash
kubectl -n envoy-gateway-system wait --for=condition=Programmed gateway/giantswarm-default --timeout=300s
LB=$(kubectl -n envoy-gateway-system get gateway giantswarm-default -o jsonpath='{.status.addresses[0].value}')
echo "$LB"
```

```
a1b2c3d4e5f6...eu-west-1.elb.amazonaws.com
```

## Step 6 — Create the DNS record

Point `observability.<domain>` at the load balancer with a CNAME record:

```bash
aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch "{\"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"$OBS_HOST\",\"Type\":\"CNAME\",\"TTL\":60,\"ResourceRecords\":[{\"Value\":\"$LB\"}]}}]}"
```

Reference: [Creating records](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/resource-record-sets-creating.html).

Check the record resolves:

```bash
dig +short "$OBS_HOST"
```

The first line is the load balancer name. The lines after it are its IP addresses.

## Step 7 — Check the certificate

Let's Encrypt validates the challenge once the record resolves. Issuance takes one to three
minutes.

```bash
kubectl -n envoy-gateway-system wait --for=condition=Ready certificate/observability-https-tls --timeout=600s
```

Check the listener serves it:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' "https://$OBS_HOST/"
```

```
404
```

A `404` means TLS works. No route is attached yet.

Check both listeners are programmed:

```bash
kubectl -n envoy-gateway-system get gateway giantswarm-default \
  -o jsonpath='{range .status.listeners[*]}{.name}{": "}{.conditions[?(@.type=="Programmed")].status}{"\n"}{end}'
```

```
http: True
https: True
```

The Gateway is ready. Install the chart with `global.domain` set to `$DOMAIN`. See
[EXTERNAL_API.md](EXTERNAL_API.md).

## Troubleshooting

### The Certificate stays not Ready

Read the challenge:

```bash
kubectl -n envoy-gateway-system get certificaterequest,order,challenge
kubectl -n envoy-gateway-system describe challenge
```

- `no such host` or a DNS error: the record from Step 6 does not resolve yet.
- `connection refused` or a timeout on port 80: the `http` listener is missing or not
  programmed.
- No `HTTPRoute` in `envoy-gateway-system` during the challenge: cert-manager runs without
  `--enable-gateway-api`, or started before the Gateway API CRDs. Restart it, as in Step 3.

### The `https` listener is not programmed

Before issuance, the listener reports `ResolvedRefs: False` with the reason
`InvalidCertificateRef`: the Secret `observability-https-tls` does not exist yet. It turns
`True` once the Certificate is Ready.

### The Gateway has no address

```bash
kubectl -n envoy-gateway-system get svc -l gateway.envoyproxy.io/owning-gateway-name=giantswarm-default
kubectl -n envoy-gateway-system describe svc -l gateway.envoyproxy.io/owning-gateway-name=giantswarm-default
```

`EXTERNAL-IP` stays `<pending>` while AWS creates the load balancer. The Service events show
AWS errors.

## Teardown

Delete the Gateway before the cluster. The Gateway owns the load balancer. A load balancer
left behind blocks the VPC deletion in `eksctl delete cluster`.

```bash
aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch "{\"Changes\":[{\"Action\":\"DELETE\",\"ResourceRecordSet\":{\"Name\":\"$OBS_HOST\",\"Type\":\"CNAME\",\"TTL\":60,\"ResourceRecords\":[{\"Value\":\"$LB\"}]}}]}"

kubectl -n envoy-gateway-system delete gateway giantswarm-default
kubectl -n envoy-gateway-system wait --for=delete svc -l gateway.envoyproxy.io/owning-gateway-name=giantswarm-default --timeout=300s
```

Then follow the [EKS teardown](EKS_CLUSTER.md#teardown).
