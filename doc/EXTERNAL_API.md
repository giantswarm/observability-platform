# External API

`observabilityPlatformApi.enabled` exposes Loki, Mimir and Tempo outside the cluster through the
Observability Platform API. External agents write and read through it. The API chart lives
at https://github.com/giantswarm/observability-platform-api

The API renders Gateway API routes plus Envoy Gateway filters and SecurityPolicies. The chart
creates no Gateway, no listener and no certificate. You provide the Gateway, and TLS terminates
at its HTTPS listener. The routes attach only to that listener.

## What it exposes

All paths are served at `observability.<global.domain>`.

| Backend | Write | Read |
| --- | --- | --- |
| Mimir | `/prometheus/api/v1/push`, `/otlp/v1/metrics` | `/prometheus/api/v1/{query,query_range,series,labels,...}` |
| Loki | `/loki/api/v1/push`, `/otlp/v1/logs` | `/loki/api/v1/{query,query_range,series,labels,...}` |
| Tempo | `/v1/traces`, OTLP gRPC | `/tempo/api/{search,traces,v2/search,v2/traces,...}`, gRPC |

Every request needs:

- `Authorization: Bearer <JWT>`, signed by one of `auth.jwt.providers`
- `X-Scope-OrgID: <tenant>`

A request missing either one gets a `401`.

## Tenants

The JWT only authenticates the request. The tenant is whatever the client sends in
`X-Scope-OrgID`, and it reaches Loki, Mimir and Tempo unchanged. Any valid token can
therefore read and write any tenant.

Loki also answers reads for several tenants at once, joined with `|`
(`X-Scope-OrgID: team-a|team-b`). Each stream comes back with a `__tenant_id__` label.
Pushes take a single tenant.

Do not name a tenant `index` or `rules`. Loki stores those paths in the same container as
the tenants' chunks. See [OBJECT_STORAGE.md](./OBJECT_STORAGE.md#the-loki-container).

## Prerequisites

The chart does not install these, but the Makefile does for local kind setups (`make local-up`).

- [Envoy Gateway](https://gateway.envoyproxy.io/). It brings the Gateway API CRDs.
- A Gateway with an HTTPS listener. Its hostname covers `observability.<global.domain>`, or it
  has none. It accepts routes from the release namespace. See [Serve HTTPS](#serve-https).
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

You also have to set the routes' `parentRefs` to your Gateway. See the next section.

To check your values are valid, you can run `helm template` without a cluster. Pass the CRDs with
`--api-versions gateway.networking.k8s.io/v1/HTTPRoute --api-versions gateway.envoyproxy.io/v1alpha1/SecurityPolicy`.

## Point the routes at your Gateway

> [!IMPORTANT]
> The default `parentRefs` name a Gateway called `giantswarm-default` in the
> `envoy-gateway-system` namespace, with a listener called `https`. That is the Gateway on
> Giant Swarm installations and in the [local setup](./LOCAL_DEV.md). On your cluster, set the
> `parentRefs` of **every** component (`loki`, `mimir`, `tempo` and `basicAuth`) to the name
> and namespace of your Gateway, and to the name of its HTTPS listener in `sectionName`. If they
> don't match, the routes are never attached and the API doesn't answer.

Each component has its own `parentRefs`, so each can use a different Gateway. Setting
`parentRefs` replaces the whole default list, so give every field:

```yaml
observability-platform-api:
  loki:
    parentRefs:
      - name: my-gateway             # your Gateway's name
        namespace: my-gateway-ns     # your Gateway's namespace
        sectionName: https           # your HTTPS listener's name
  mimir:
    parentRefs:
      - name: my-gateway
        namespace: my-gateway-ns
        sectionName: https
  tempo:
    parentRefs:
      - name: my-gateway
        namespace: my-gateway-ns
        sectionName: https
  basicAuth:
    parentRefs:
      - name: my-gateway
        namespace: my-gateway-ns
        sectionName: https
```

Keep `sectionName` on an HTTPS listener. Without it, a route attaches to every listener of the
Gateway, including a plain HTTP one, and bearer tokens and telemetry travel unencrypted.

### Check that the routes are attached

```bash
kubectl get httproute,grpcroute -n monitoring \
  -o custom-columns='ROUTE:.metadata.name,PARENT:.status.parents[*].parentRef.name,LISTENER:.status.parents[*].parentRef.sectionName,ACCEPTED:.status.parents[*].conditions[?(@.type=="Accepted")].status'
```

Every route should show `ACCEPTED` as `True`. `False` with the reason `NoMatchingParent`
(`kubectl describe httproute <name> -n monitoring`) means no listener of that Gateway has the
name in `sectionName`. `NotAllowedByListeners` means the listener doesn't accept routes from
this namespace.

## Serve HTTPS

A minimal Gateway with an HTTPS listener named `https`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: my-gateway
  namespace: my-gateway-ns
spec:
  gatewayClassName: envoy-gateway    # your Envoy Gateway GatewayClass
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      hostname: "*.example.com"
      tls:
        mode: Terminate
        certificateRefs:
          - name: my-gateway-https-tls
      allowedRoutes:
        namespaces:
          from: All
```

The certificate Secret is a `kubernetes.io/tls` Secret. Put it in the Gateway's namespace. A
Secret in another namespace also needs a `ReferenceGrant` there that allows the Gateway to read
it.

### Certificate from cert-manager

cert-manager can issue the certificate from an annotation on the Gateway:

```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: my-cluster-issuer
```

It creates the Secret named in the listener's `certificateRefs`. Its Gateway API support is a
beta feature that is **off by default**: enable it in the cert-manager controller with
`--enable-gateway-api`, or `gatewayAPI.enabled: true` in the controller configuration. See the
[cert-manager documentation](https://cert-manager.io/docs/usage/gateway/).

### Certificate from a file

```bash
kubectl create secret tls my-gateway-https-tls -n my-gateway-ns --cert=tls.crt --key=tls.key
```

## Send data

Get a JWT from your OIDC issuer. Set the API address and the request headers:

```bash
API=https://observability.<global.domain>
AUTH=(-H "Authorization: Bearer <JWT>" -H "X-Scope-OrgID: <tenant>")
```

In the [local setup](./LOCAL_DEV.md#send-data-through-the-external-api), use its `API` and
`AUTH` instead. They point at the local certificate and token.

Push a metric through OTLP:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' "${AUTH[@]}" \
  -H "Content-Type: application/json" \
  "$API/otlp/v1/metrics" \
  -d '{"resourceMetrics":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"external-api-test"}}]},"scopeMetrics":[{"metrics":[{"name":"external_api_test","gauge":{"dataPoints":[{"asDouble":42,"timeUnixNano":"'"$(date +%s)"'000000000"}]}}]}]}]}'
```

Push a log line:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' "${AUTH[@]}" \
  -H "Content-Type: application/json" \
  "$API/loki/api/v1/push" \
  -d '{"streams":[{"stream":{"job":"external-api-test"},"values":[["'"$(date +%s)"'000000000","hello from the external API"]]}]}'
```

Push a span:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' "${AUTH[@]}" \
  -H "Content-Type: application/json" \
  "$API/v1/traces" \
  -d '{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"external-api-test"}}]},"scopeSpans":[{"spans":[{"traceId":"5b8efff798038103d269b633813fc60c","spanId":"eee19b7ec3c1b174","name":"external-api-test","kind":1,"startTimeUnixNano":"'"$(date +%s)"'000000000","endTimeUnixNano":"'"$(date +%s)"'100000000"}]}]}]}'
```

All three return `200` or `204`.

Read them back:

```bash
curl -sS -G "${AUTH[@]}" "$API/prometheus/api/v1/query" --data-urlencode 'query=external_api_test'
curl -sS -G "${AUTH[@]}" "$API/loki/api/v1/query_range" --data-urlencode 'query={job="external-api-test"}'
curl -sS "${AUTH[@]}" "$API/tempo/api/v2/traces/5b8efff798038103d269b633813fc60c"
```

Without a token, the API rejects the request:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' -H "X-Scope-OrgID: <tenant>" \
  "$API/prometheus/api/v1/query?query=up"
```

```
401
```

For a Prometheus `remote_write` or an OpenTelemetry Collector, use
`$API/prometheus/api/v1/push` or `$API/otlp/v1/metrics` with the same two headers. For traces,
use `$API/v1/traces`.

## From inside the cluster

Pods in the cluster can call the gateways directly, without the API and without a token.
They still need `X-Scope-OrgID`, or Loki and Mimir answer `401` with `no org id`. These URLs
assume the release runs in `monitoring`:

| Backend | URL |
| --- | --- |
| Loki | `http://loki-gateway.monitoring.svc` |
| Mimir | `http://mimir-gateway.monitoring.svc/prometheus` |

Push a log line and read it back from a throwaway pod:

```bash
kubectl run loki-check -n monitoring --rm -i --restart=Never --image=curlimages/curl:8.11.1 -- \
  -sS -o /dev/null -w '%{http_code}\n' -H "X-Scope-OrgID: default" -H "Content-Type: application/json" \
  http://loki-gateway.monitoring.svc/loki/api/v1/push \
  -d '{"streams":[{"stream":{"job":"in-cluster-test"},"values":[["'"$(date +%s)"'000000000","hello from inside the cluster"]]}]}'
kubectl run loki-check -n monitoring --rm -i --restart=Never --image=curlimages/curl:8.11.1 -- \
  -sS -G -H "X-Scope-OrgID: default" \
  http://loki-gateway.monitoring.svc/loki/api/v1/query_range --data-urlencode 'query={job="in-cluster-test"}'
```

The push prints `204`, the query `"status":"success"` with the line.

A Grafana datasource uses the same URL, with `X-Scope-OrgID` as a custom HTTP header. The
datasources that the observability-operator provisions already set it.

## Read-only basic auth

For clients that can't send a JWT, such as an external Grafana, the API can also expose the
Mimir and Loki **read** paths with basic auth, on a hostname of their own. Writes and Tempo stay
JWT-only. Set `observability-platform-api.basicAuth.enabled`, `basicAuth.hostname`, and an
htpasswd Secret you create yourself. The format is in the
[API chart's basic auth docs](https://github.com/giantswarm/observability-platform-api/blob/main/docs/basic-auth.md).
That hostname must also be covered by the listener in `basicAuth.parentRefs`.

## Expose Grafana over HTTPS

The chart doesn't expose Grafana. To serve it on the same Gateway, enable the Grafana chart's
route and set Grafana's public URL:

```yaml
grafana:
  grafana:
    route:
      main:
        enabled: true
        hostnames:
          - grafana.example.com
        parentRefs:
          - name: my-gateway
            namespace: my-gateway-ns
            sectionName: https
    grafana.ini:
      server:
        root_url: https://grafana.example.com
```

As for the API, the `parentRefs` must name your Gateway, its namespace and its HTTPS listener.
`root_url` must be the HTTPS address, or Grafana builds redirects and links with the wrong
scheme.

## Limitations

- A client can send any `X-Scope-OrgID`. Nothing binds the tenant to the token. See
  [Tenants](#tenants).
- Loki's Prometheus-compatible rules API is not reachable. Loki and Mimir share the
  hostname, and `/prometheus/api/v1/rules` goes to Mimir. `/prometheus/api/v1/alerts` has no
  route. So a Grafana Loki datasource pointed at the API shows no Loki-managed alert rules.
  Loki's own `/loki/api/v1/rules` works.
- Ingest authentication is JWT only.
