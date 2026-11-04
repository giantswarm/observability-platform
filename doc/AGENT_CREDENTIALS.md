# Push with AgentCredentials

Agents that can't fetch a JWT push with basic auth instead. You create one AgentCredential per agent
and per backend. The observability-operator generates its password and adds it to that backend's
htpasswd Secret. The Mimir, Loki and Tempo charts each serve their push paths on a hostname of their
own, through their own gateway route, behind a SecurityPolicy that checks their backend's Secret.

These pushes don't go through the [Observability Platform API](./EXTERNAL_API.md). Agents that
also need to read use the API for that, with a JWT or its
[read-only basic auth](./EXTERNAL_API.md#read-only-basic-auth).

An AgentCredential can **only push, and only to its own backend**. It gets a `401` on the API, and
on another backend's hostname while that backend has at least one AgentCredential. A backend with
none answers `500` to every push: see [No credentials yet](#no-credentials-yet).

| Backend | `spec.backend` | Hostname | Push paths |
| --- | --- | --- | --- |
| Mimir | `metrics` | `mimir.<global.domain>` | `/api/v1/push`, `/otlp/v1/metrics` |
| Loki | `logs` | `write.loki.<global.domain>` | `/loki/api/v1/push`, `/otlp/v1/logs` |
| Tempo | `traces` | `tempo.<global.domain>` | OTLP/gRPC on port 443, OTLP/HTTP at `/tempo/v1/traces` |

## Turn it on

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

These routes need Envoy Gateway, as the API does, but not the API itself.

## Point the routes at your Gateway

> [!IMPORTANT]
> The default `parentRefs` of the four routes name a Gateway called `giantswarm-default` in the
> `envoy-gateway-system` namespace, with a listener called `https`. That is the Gateway on Giant
> Swarm installations and in the [local setup](./LOCAL_DEV.md). On your cluster, update the
> **observability-platform chart's values**: set the `parentRefs` of **every** backend route,
> for Mimir (`mimir.routes.gateway`), Loki (`loki.gatewayRoute`) and Tempo (`tempo.routes.https`
> and `tempo.routes.grpc`), to the name and namespace of the Gateway you deployed, and to the name
> of its HTTPS listener in `sectionName`. If they don't match, the routes are never attached and
> agents get no answer.

Add this to the values you install the observability-platform chart with, next to the
`enabled: true` lines above. Setting `parentRefs` replaces the whole default list, so give every
field:

```yaml
mimir:
  routes:
    gateway:
      parentRefs:
        - name: my-gateway             # your Gateway's name
          namespace: my-gateway-ns     # your Gateway's namespace
          sectionName: https           # your HTTPS listener's name
loki:
  gatewayRoute:
    parentRefs:
      - name: my-gateway
        namespace: my-gateway-ns
        sectionName: https
tempo:
  routes:
    https:
      parentRefs:
        - name: my-gateway
          namespace: my-gateway-ns
          sectionName: https
    grpc:
      parentRefs:
        - name: my-gateway
          namespace: my-gateway-ns
          sectionName: https
```

The listener's hostname must cover `mimir.<global.domain>`, `write.loki.<global.domain>` and
`tempo.<global.domain>`, for example with `*.<global.domain>`, or it has none. It must accept
routes from the release namespace. Keep `sectionName` on an HTTPS listener: without it, a route
attaches to every listener of the Gateway, including a plain HTTP one, and credentials and
telemetry travel unencrypted. The [API docs](./EXTERNAL_API.md#serve-https) show a minimal
Gateway and how to get its certificate.

Check that the routes are attached:

```bash
kubectl get httproute/mimir-gateway httproute/loki-gateway httproute/tempo-https grpcroute/tempo-grpc \
  -n monitoring -o custom-columns='ROUTE:.metadata.name,PARENT:.status.parents[*].parentRef.name,LISTENER:.status.parents[*].parentRef.sectionName,ACCEPTED:.status.parents[*].conditions[?(@.type=="Accepted")].status'
```

Every route should show `ACCEPTED` as `True`. `NoMatchingParent` means no listener of that Gateway
has the name in `sectionName`, and `NotAllowedByListeners` means the listener doesn't accept routes
from this namespace.

## Operator

The observability-operator release must run its AgentCredential controller and write the
htpasswd Secrets into `monitoring`. [values/observability-operator.yaml](../values/observability-operator.yaml)
does both.

## Create a credential

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

## Configure an agent

Each Alloy component below reads the username and password from environment variables. Set
them from the generated Secret, for example with `secretKeyRef`. The URLs are the ones the
observability-operator gives agents on Giant Swarm installations.

Metrics, through Prometheus remote-write:

```alloy
prometheus.remote_write "platform" {
  endpoint {
    url     = "https://mimir.example.com/api/v1/push"
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
    url     = "https://write.loki.example.com/loki/api/v1/push"
    headers = { "X-Scope-OrgID" = "<tenant>" }
    basic_auth {
      username = sys.env("LOGS_USERNAME")
      password = sys.env("LOGS_PASSWORD")
    }
  }
}
```

Traces, through OTLP over gRPC:

```alloy
otelcol.auth.basic "traces" {
  username = sys.env("TRACES_USERNAME")
  password = sys.env("TRACES_PASSWORD")
}

otelcol.exporter.otlp "platform" {
  client {
    endpoint = "tempo.example.com:443"
    headers  = { "X-Scope-OrgID" = "<tenant>" }
    auth     = otelcol.auth.basic.traces.handler
  }
}
```

Over OTLP/HTTP, use `otelcol.exporter.otlphttp` with that backend's credential and one of these
endpoints. The exporter appends `/v1/metrics`, `/v1/logs` or `/v1/traces`:

- metrics: `https://mimir.example.com/otlp`
- logs: `https://write.loki.example.com/otlp`
- traces: `https://tempo.example.com/tempo`

Try a credential with `curl`. A `401` means the credential is wrong or belongs to another
backend:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' -u "$USERNAME:$PASSWORD" -H "X-Scope-OrgID: <tenant>" \
  -H "Content-Type: application/json" \
  "https://write.loki.example.com/loki/api/v1/push" \
  -d '{"streams":[{"stream":{"job":"agent-credential-test"},"values":[["'"$(date +%s)"'000000000","hello"]]}]}'
```

```
204
```

Clients that put credentials in a URL must percent-encode the `/` of the username, as `%2F`.
Alloy and Prometheus take the username in a separate field and need nothing.

## Rotate and revoke

- **Rotate:** delete the generated Secret. The operator creates it again with a new password, and
  the old one stops working. Agents need the new password, so restart them if they read the
  Secret only at startup.
- **Revoke:** delete the AgentCredential. Its Secret goes with it, and its access ends within
  a few seconds.

## No credentials yet

A backend with **no AgentCredentials** answers `500` on its push paths. The operator writes a
backend's htpasswd Secret only once its first credential exists, and leaves it empty after the
last one is deleted, and Envoy Gateway fails closed on a missing or empty Secret. Create an
AgentCredential for that backend.

## Tenants

A credential doesn't bind a tenant. The client chooses it with `X-Scope-OrgID`, as with a JWT.
Without the header, the HTTP paths answer `400` and Tempo rejects gRPC calls with `no org id`, as
on Giant Swarm installations.

## AgentCredentials or OAuth2

Alloy can also fetch a JWT itself, through the OAuth2 client credentials flow, and push through
the API. Use the `oauth2` block of `prometheus.remote_write` or `loki.write`, or
`otelcol.auth.oauth2`. Choose:

- **AgentCredentials** for per-agent, per-backend credentials that you create, rotate and revoke
  through Kubernetes or GitOps, with no change in your identity provider. They can only push.
- **OAuth2 client credentials** when you manage agents as clients in your identity provider, or
  when an agent also needs to read.

To enable the API you still need an OIDC issuer: AgentCredentials are an addition for agents,
not a replacement for JWT.

## Limitations

- An AgentCredential can't be limited to a tenant, or to some of its backend's paths.
- A client can send any `X-Scope-OrgID`.
