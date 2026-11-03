# External API

`observabilityPlatformApi.enabled` exposes Loki, Mimir and Tempo outside the cluster through the
Observability Platform API. External agents write and read through it. The API chart lives
at https://github.com/giantswarm/observability-platform-api

The API renders Gateway API routes plus Envoy Gateway filters and SecurityPolicies. The chart
creates no Gateway, no listener and no certificate. You provide the Gateway, and TLS terminates
at its HTTPS listener. The routes attach only to that listener.

## What it exposes

Two hostnames, one per authentication method. Envoy Gateway can't accept a JWT and basic
auth on the same route, so each method has its own:

- `observability.<global.domain>`: JWT, for writes and reads. The table below lists its paths.
- `observability-basic.<global.domain>`: basic auth. Agents push with
  [AgentCredentials](#push-with-agentcredentials), and clients can read Mimir and Loki with
  [an htpasswd Secret of your own](#read-only-basic-auth).

All paths below are served at `observability.<global.domain>`.

| Backend | Write | Read |
| --- | --- | --- |
| Mimir | `/prometheus/api/v1/push`, `/otlp/v1/metrics` | `/prometheus/api/v1/{query,query_range,series,labels,...}` |
| Loki | `/loki/api/v1/push`, `/otlp/v1/logs` | `/loki/api/v1/{query,query_range,series,labels,...}` |
| Tempo | `/v1/traces`, OTLP gRPC | `/tempo/api/{search,traces,v2/search,v2/traces,...}`, gRPC |

Every request needs:

- `Authorization: Bearer <JWT>`, signed by one of `auth.jwt.providers`
- `X-Scope-OrgID: <tenant>`

A request missing either one gets a `401`.

## Prerequisites

The chart does not install these, but the Makefile does for local kind setups (`make local-up`).

- [Envoy Gateway](https://gateway.envoyproxy.io/). It brings the Gateway API CRDs.
- A Gateway with an HTTPS listener. Its hostname covers `observability.<global.domain>`, or it
  has none. It accepts routes from the release namespace. See [Serve HTTPS](#serve-https).
- An OIDC issuer. Envoy fetches its JWKS, so the JWKS URI must be reachable from the
  Envoy pods. See [Allow JWKS egress](#allow-jwks-egress).

[GATEWAY.md](./GATEWAY.md) installs Envoy Gateway and creates this Gateway on EKS.

### Allow JWKS egress

The Envoy proxy pods fetch the JWKS URI over HTTPS and refresh it every 5 minutes. They run
in the Envoy Gateway namespace, `envoy-gateway-system` by default. They keep the last JWKS when
a refresh fails. A proxy pod without a JWKS answers every request with a `401`. This affects new
pods, restarted pods and issuer key rotations.

If a NetworkPolicy restricts egress there, allow the proxy pods to reach:

- DNS
- the JWKS URI, on TCP 443
- the Envoy Gateway controller, on TCP 18000 for xDS
- the backends, in the `monitoring` namespace

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: envoy-proxy-egress
  namespace: envoy-gateway-system
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: envoy
      app.kubernetes.io/component: proxy
  policyTypes:
    - Egress
  egress:
    # DNS
    - ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    # JWKS
    - ports:
        - protocol: TCP
          port: 443
    # xDS from the Envoy Gateway controller
    - to:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: gateway-helm
      ports:
        - protocol: TCP
          port: 18000
    # Backends
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
```

This policy covers the proxy pods only. The Envoy Gateway controller also needs egress to the
Kubernetes API server.

A NetworkPolicy selects IP ranges, not host names. To allow only the JWKS host, use a policy
with FQDN rules, such as a CiliumNetworkPolicy with `toFQDNs`. An egress proxy or firewall
outside the cluster must allow the host of the JWKS URI.

Check that a proxy pod reaches the JWKS URI:

```bash
kubectl -n envoy-gateway-system debug -q -i --image=curlimages/curl:8.16.0 \
  "$(kubectl -n envoy-gateway-system get pod -l app.kubernetes.io/component=proxy -o name | head -1)" \
  -- sh -c "sleep 2; curl -sS -o /dev/null -w '%{http_code}\n' https://issuer.example.com/keys"
```

```
200
```

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
> don't match, the routes are never attached and the API doesn't answer. Or create a Gateway
> that matches the defaults with [GATEWAY.md](./GATEWAY.md).

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

[GATEWAY.md](./GATEWAY.md) creates a Gateway that matches the default `parentRefs`, with a
Let's Encrypt certificate. This section lists what any Gateway needs.

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

Let's Encrypt issues the wildcard hostname of the example above through a DNS-01 solver only. An
HTTP-01 solver needs one hostname per listener and a plain HTTP listener for the challenge, as in
[GATEWAY.md](./GATEWAY.md).

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

## Push with AgentCredentials

Agents that can't fetch a JWT push with basic auth instead, on
`observability-basic.<global.domain>`. You create one AgentCredential per agent and per
backend. The observability-operator generates its password and adds it to that backend's
htpasswd Secret. The Mimir, Loki and Tempo charts each route their write paths on that
hostname, behind a SecurityPolicy that checks their backend's Secret.

An AgentCredential can **only push, and only to its own backend**. On another backend's
paths, on the read paths and on the JWT hostname it gets a `401`.

| Backend | `spec.backend` | Write paths |
| --- | --- | --- |
| Mimir | `metrics` | `/prometheus/api/v1/push`, `/otlp/v1/metrics` |
| Loki | `logs` | `/loki/api/v1/push`, `/otlp/v1/logs` |
| Tempo | `traces` | `/v1/traces`, OTLP gRPC |

The paths are the same as on the JWT hostname.

### Turn it on

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

The routes attach to the same Gateway listener as the API, and its hostname must cover
`observability-basic.<global.domain>`. To use another Gateway, set the `parentRefs` under each
of the four keys, as for the [API routes](#point-the-routes-at-your-gateway).

The observability-operator release must run its AgentCredential controller and write the
htpasswd Secrets into `monitoring`. [values/observability-operator.yaml](../values/observability-operator.yaml)
does both.

These routes don't need the API itself. Without it, agents can push, but nothing outside the
cluster can query. To enable the API you still need an OIDC issuer: basic auth is an addition
for agents, not a replacement for JWT.

### Create a credential

Create the AgentCredential in any namespace, with kubectl or GitOps:

```yaml
apiVersion: observability.giantswarm.io/v1alpha1
kind: AgentCredential
metadata:
  name: alloy-metrics
  namespace: my-team
spec:
  backend: metrics    # metrics, logs or traces
```

The operator creates a Secret with the same name and namespace. It holds three keys:
`username`, `password` and `htpasswd`. The username is `<namespace>/<name>` of the
AgentCredential, here `my-team/alloy-metrics`. Kubernetes keeps namespace and name unique, so no
two credentials share a username. `spec.agentName` is deprecated and ignored.

```bash
kubectl get agentcredential alloy-metrics -n my-team
kubectl get secret alloy-metrics -n my-team -o jsonpath='{.data.username}' | base64 -d; echo
kubectl get secret alloy-metrics -n my-team -o jsonpath='{.data.password}' | base64 -d; echo
```

The gateway accepts a new credential within a few seconds.

### Configure an agent

Each Alloy component below reads the username and password from environment variables. Set
them from the generated Secret, for example with `secretKeyRef`.

Metrics, through Prometheus remote-write:

```alloy
prometheus.remote_write "platform" {
  endpoint {
    url     = "https://observability-basic.example.com/prometheus/api/v1/push"
    headers = { "X-Scope-OrgID" = "<tenant>" }
    basic_auth {
      username = sys.env("METRICS_USERNAME")
      password = sys.env("METRICS_PASSWORD")
    }
  }
}
```

Logs, through the Loki push API:

```alloy
loki.write "platform" {
  endpoint {
    url     = "https://observability-basic.example.com/loki/api/v1/push"
    headers = { "X-Scope-OrgID" = "<tenant>" }
    basic_auth {
      username = sys.env("LOGS_USERNAME")
      password = sys.env("LOGS_PASSWORD")
    }
  }
}
```

Traces, through OTLP over gRPC. For OTLP over HTTP, use `otelcol.exporter.otlphttp` with
`endpoint = "https://observability-basic.example.com"`. The same exporter sends metrics or logs
over OTLP, with `endpoint = "https://observability-basic.example.com/otlp"` and that backend's
credential.

```alloy
otelcol.auth.basic "traces" {
  username = sys.env("TRACES_USERNAME")
  password = sys.env("TRACES_PASSWORD")
}

otelcol.exporter.otlp "platform" {
  client {
    endpoint = "observability-basic.example.com:443"
    headers  = { "X-Scope-OrgID" = "<tenant>" }
    auth     = otelcol.auth.basic.traces.handler
  }
}
```

Try a credential with `curl`. A `401` means the credential is wrong or belongs to another
backend:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' -u "$USERNAME:$PASSWORD" -H "X-Scope-OrgID: <tenant>" \
  -H "Content-Type: application/json" \
  "https://observability-basic.example.com/loki/api/v1/push" \
  -d '{"streams":[{"stream":{"job":"basic-auth-test"},"values":[["'"$(date +%s)"'000000000","hello"]]}]}'
```

```
204
```

Clients that put credentials in a URL must percent-encode the `/` of the username, as `%2F`.
Alloy and Prometheus take the username in a separate field and need nothing.

### Rotate and revoke

- **Rotate:** delete the generated Secret. The operator creates it again with a new password, and
  the old one stops working. Agents need the new password, so restart them if they read the
  Secret only at startup.
- **Revoke:** delete the AgentCredential. Its Secret goes with it, and its access ends within
  a few seconds.

### No credentials yet

A backend with **no AgentCredentials** answers `500` on its write paths. The operator writes a
backend's htpasswd Secret only once its first credential exists, and leaves it empty after the
last one is deleted, and Envoy Gateway fails closed on a missing or empty Secret. Create an
AgentCredential for that backend.

### Tenants

A credential doesn't bind a tenant. The client chooses it with `X-Scope-OrgID`, as with a JWT.
Without the header, HTTP paths answer `401` and gRPC calls match no route and fail.

### AgentCredentials or OAuth2

Alloy can also fetch a JWT itself, through the OAuth2 client credentials flow, and push to the JWT
hostname. Use the `oauth2` block of `prometheus.remote_write` or `loki.write`, or
`otelcol.auth.oauth2`. Choose:

- **AgentCredentials** for per-agent, per-backend credentials that you create, rotate and revoke
  through Kubernetes or GitOps, with no change in your identity provider. They can only push.
- **OAuth2 client credentials** when you manage agents as clients in your identity provider, or
  when an agent also needs to read.

## Read-only basic auth

For clients that can't send a JWT, such as an external Grafana, the API can also expose the
Mimir and Loki **read** paths with basic auth, on `observability-basic.<global.domain>`, next to
the AgentCredential writes. Tempo reads stay JWT-only. Set
`observability-platform-api.basicAuth.enabled` and create an htpasswd Secret yourself. The format
is in the
[API chart's basic auth docs](https://github.com/giantswarm/observability-platform-api/blob/main/docs/basic-auth.md).
Its users can only read: they get a `401` on the write paths, and AgentCredentials get a `401` on
the read paths.

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

- A client can send any `X-Scope-OrgID`. Nothing binds the tenant to the token.
- An AgentCredential can't be limited to a tenant, or to some of its backend's paths.
