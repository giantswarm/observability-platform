# External API

`observabilityPlatformApi.enabled` exposes Loki and Mimir outside the cluster through the
[Observability Platform API](https://github.com/giantswarm/observability-platform-api).
External agents write and read through it.

The API renders Gateway API routes plus Envoy Gateway filters and SecurityPolicies. It
serves plain HTTP for now.

## What it exposes

All paths are served at `observability.<global.domain>`.

| Backend | Write | Read |
| --- | --- | --- |
| Mimir | `/prometheus/api/v1/push`, `/otlp/v1/metrics` | `/prometheus/api/v1/{query,query_range,series,labels,...}` |
| Loki | `/loki/api/v1/push`, `/otlp/v1/logs`, OTLP gRPC | `/loki/api/v1/{query,query_range,series,labels,...}` |

Every request needs:

- `Authorization: Bearer <JWT>`, signed by one of `auth.jwt.providers`
- `X-Scope-OrgID: <tenant>`

A request missing either one gets a `401`.

## Prerequisites

The chart does not install these. Install them yourself.

- [Envoy Gateway](https://gateway.envoyproxy.io/). It brings the Gateway API CRDs.
- A Gateway named `giantswarm-default` in `envoy-gateway-system`. Its listener accepts
  routes from the release namespace.
- An OIDC issuer. Envoy fetches its JWKS, so the JWKS URI must be reachable from the
  Envoy pods.

## Values

```yaml
global:
  domain: example.com

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

The render fails if `observabilityPlatformApi.enabled` is set without `global.domain` or
without a provider.

## Local setup on kind

This builds on [LOCAL_DEV.md](./LOCAL_DEV.md). Additional prerequisites: `openssl`, `xxd`,
`curl`.

The steps below replace the OIDC issuer with a static JWKS served in the cluster. You sign
tokens with a local key. Do not use this anywhere real.

Commands run from the repository root. Scratch files go to `/tmp/observability-platform-api`:

```bash
export WORKDIR=/tmp/observability-platform-api
mkdir -p "$WORKDIR"
```

### 1. Envoy Gateway and the Gateway

```bash
helm install eg oci://docker.io/envoyproxy/gateway-helm \
  --version 1.9.1 \
  --namespace envoy-gateway-system --create-namespace \
  --wait --timeout 10m

kubectl apply -f - <<'EOF'
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
spec:
  gatewayClassName: envoy-gateway
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All
EOF
```

Kind has no LoadBalancer. The Gateway stays `PROGRAMMED False` with
`AddressNotAssigned`. Routing works regardless. Step 5 reaches Envoy through a
port-forward.

### 2. Signing key and JWKS

```bash
b64url() { base64 | tr -d '\n=' | tr '+/' '-_'; }

openssl genrsa -out "$WORKDIR/key.pem" 2048
N=$(openssl rsa -in "$WORKDIR/key.pem" -noout -modulus | cut -d= -f2 | xxd -r -p | b64url)
printf '{"keys":[{"kty":"RSA","use":"sig","alg":"RS256","kid":"dev","n":"%s","e":"AQAB"}]}' "$N" \
  > "$WORKDIR/jwks.json"
```

### 3. JWKS server

```bash
kubectl create namespace jwt-issuer
kubectl create configmap jwks -n jwt-issuer --from-file=jwks.json="$WORKDIR/jwks.json"

kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jwks
  namespace: jwt-issuer
spec:
  selector:
    matchLabels:
      app: jwks
  template:
    metadata:
      labels:
        app: jwks
    spec:
      containers:
        - name: nginx
          image: nginx:1.29-alpine
          ports:
            - containerPort: 80
          volumeMounts:
            - name: jwks
              mountPath: /usr/share/nginx/html
      volumes:
        - name: jwks
          configMap:
            name: jwks
---
apiVersion: v1
kind: Service
metadata:
  name: jwks
  namespace: jwt-issuer
spec:
  selector:
    app: jwks
  ports:
    - port: 80
EOF
```

### 4. Install the chart

```bash
cat > "$WORKDIR/values.yaml" <<'EOF'
global:
  domain: local.test
observabilityPlatformApi:
  enabled: true
observability-platform-api:
  auth:
    jwt:
      providers:
        - name: dev
          issuer: http://jwks.jwt-issuer.svc.cluster.local
          remoteJWKS:
            uri: http://jwks.jwt-issuer.svc.cluster.local/jwks.json
          extractFrom:
            headers:
              - name: Authorization
                valuePrefix: "Bearer "
EOF

helm upgrade --install observability-platform helm/observability-platform \
  --namespace monitoring \
  --values helm/observability-platform/values-local.yaml \
  --values "$WORKDIR/values.yaml"
```

Check the routes and policies:

```bash
kubectl get httproute,grpcroute,securitypolicy -n monitoring
```

Expect four HTTPRoutes, one GRPCRoute and two SecurityPolicies.

### 5. Send data

Sign a token valid for one hour:

```bash
NOW=$(date +%s)
HEADER=$(printf '{"alg":"RS256","typ":"JWT","kid":"dev"}' | b64url)
PAYLOAD=$(printf '{"iss":"http://jwks.jwt-issuer.svc.cluster.local","sub":"dev-agent","iat":%d,"exp":%d}' \
  "$NOW" "$((NOW + 3600))" | b64url)
SIGNATURE=$(printf '%s.%s' "$HEADER" "$PAYLOAD" | openssl dgst -sha256 -sign "$WORKDIR/key.pem" -binary | b64url)
TOKEN="$HEADER.$PAYLOAD.$SIGNATURE"
```

Forward the Envoy Service in a second terminal:

```bash
kubectl port-forward -n envoy-gateway-system \
  "$(kubectl get service -n envoy-gateway-system -o name \
    -l gateway.envoyproxy.io/owning-gateway-name=giantswarm-default)" \
  8080:80
```

Set the request basics:

```bash
API=http://localhost:8080
AUTH=(-H "Host: observability.local.test" -H "Authorization: Bearer $TOKEN" -H "X-Scope-OrgID: default")
```

Push a metric through OTLP:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' "${AUTH[@]}" \
  -H "Content-Type: application/json" \
  "$API/otlp/v1/metrics" \
  -d '{"resourceMetrics":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"kind-test"}}]},"scopeMetrics":[{"metrics":[{"name":"external_api_test","gauge":{"dataPoints":[{"asDouble":42,"timeUnixNano":"'"$(date +%s)"'000000000"}]}}]}]}]}'
```

Push a log line:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' "${AUTH[@]}" \
  -H "Content-Type: application/json" \
  "$API/loki/api/v1/push" \
  -d '{"streams":[{"stream":{"job":"kind-test"},"values":[["'"$(date +%s)"'000000000","hello from the external API"]]}]}'
```

Both return `200` or `204`.

Read them back:

```bash
curl -sS -G "${AUTH[@]}" "$API/prometheus/api/v1/query" --data-urlencode 'query=external_api_test'
curl -sS -G "${AUTH[@]}" "$API/loki/api/v1/query_range" --data-urlencode 'query={job="kind-test"}'
```

Without a token, the API rejects the request:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' -H "Host: observability.local.test" -H "X-Scope-OrgID: default" \
  "$API/prometheus/api/v1/query?query=up"
```

```
401
```

## Limitations

- Plain HTTP only. No TLS.
- A client can send any `X-Scope-OrgID`. Nothing binds the tenant to the token.
- Tempo is not exposed. Its Service names are not pinned.
- Ingest authentication is JWT only.

## Teardown

```bash
helm uninstall observability-platform -n monitoring
kubectl delete namespace jwt-issuer
kubectl delete gateway giantswarm-default -n envoy-gateway-system
kubectl delete gatewayclass envoy-gateway
helm uninstall eg -n envoy-gateway-system
rm -rf "$WORKDIR"
```
