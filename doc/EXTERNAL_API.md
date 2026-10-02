# External API

`observabilityPlatformApi.enabled` exposes Loki and Mimir outside the cluster through the
Observability Platform API. External agents write and read through it. The API chart lives
at https://github.com/giantswarm/observability-platform-api

The API renders Gateway API routes plus Envoy Gateway filters and SecurityPolicies. It
serves plain HTTP for now. Loki and Mimir accept HTTP only.

## What it exposes

All paths are served at `observability.<global.domain>`.

| Backend | Write | Read |
| --- | --- | --- |
| Mimir | `/prometheus/api/v1/push`, `/otlp/v1/metrics` | `/prometheus/api/v1/{query,query_range,series,labels,...}` |
| Loki | `/loki/api/v1/push`, `/otlp/v1/logs` | `/loki/api/v1/{query,query_range,series,labels,...}` |

Every request needs:

- `Authorization: Bearer <JWT>`, signed by one of `auth.jwt.providers`
- `X-Scope-OrgID: <tenant>`

A request missing either one gets a `401`.

The API chart 0.5.0 also renders a Loki GRPCRoute, `loki-write-api-grpc`. It is not part
of the API. Loki serves no OTLP over gRPC. The next API chart release removes the route.
See https://github.com/giantswarm/observability-platform-api/pull/101

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

The render fails if `observabilityPlatformApi.enabled` is set and:

- `global.domain` is empty.
- `auth.jwt.providers` is empty.
- `loki.enabled` or `mimir.enabled` is false, and its API routes are enabled.
- The release namespace differs from the API route namespace, `monitoring` by default.
- The cluster serves no Gateway API or Envoy Gateway CRDs.

`helm template` runs without a cluster. Pass the CRDs with
`--api-versions gateway.networking.k8s.io/v1/HTTPRoute --api-versions gateway.envoyproxy.io/v1alpha1/SecurityPolicy`.

## Send data

Get a JWT from your OIDC issuer. Set the API address and the request headers:

```bash
API=http://observability.<global.domain>
AUTH=(-H "Authorization: Bearer <JWT>" -H "X-Scope-OrgID: <tenant>")
```

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

Both return `200` or `204`.

Read them back:

```bash
curl -sS -G "${AUTH[@]}" "$API/prometheus/api/v1/query" --data-urlencode 'query=external_api_test'
curl -sS -G "${AUTH[@]}" "$API/loki/api/v1/query_range" --data-urlencode 'query={job="external-api-test"}'
```

Without a token, the API rejects the request:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' -H "X-Scope-OrgID: <tenant>" \
  "$API/prometheus/api/v1/query?query=up"
```

```
401
```

## Limitations

- Plain HTTP only. No TLS.
- A client can send any `X-Scope-OrgID`. Nothing binds the tenant to the token.
- Tempo is not exposed.
- Ingest authentication is JWT only.

