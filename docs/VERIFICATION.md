# Verification

The verification proves that a running observability-platform works, on any cluster. A **check**
is one pytest test of the platform. A **run** is one invocation of the checks. The **target** is
the platform under verification: a kube context, a release namespace and the hostnames of its
routes.

The checks live in `tests/ats`, the app-test-suite directory. `make verify` runs them against the
target that [the inputs](#inputs) name. The same checks run with the same command on kind, on EKS
or on any other cluster.

## Markers

A pytest marker selects a set of checks. `make verify` selects `smoke` and `verify` by default.
`VERIFY_MARKERS` selects others. See [Run](#run).

| Marker | Checks | Purpose | Default |
| --- | --- | --- | --- |
| `smoke` | 12 | Proves that the platform is up: workloads ready, Grafana up on PostgreSQL, one write and read per signal | yes |
| `verify` | 31 | Proves that the platform works: health, rejections, AgentCredentials, Grafana, rulers | yes |
| `slow` | 3 | Proves that Mimir, Loki and Tempo serve reads from the object store | no |
| `disruptive` | 1 | Proves that a Grafana dashboard survives a restart of Grafana | no |

What each marker checks:

| Feature | `smoke` | `verify` | `slow` | `disruptive` |
| --- | --- | --- | --- | --- |
| Workloads ready | yes | | | |
| Health: PersistentVolumeClaims, OOMKills, routes, Gateways | | yes | | |
| External API: one write and read per signal | yes | | | |
| External API: rejections | no token | garbage token, no tenant, AgentCredential | | |
| AgentCredentials | `logs` | `metrics`, `traces`, rejections | | |
| Grafana | health, login, PostgreSQL | datasources, queries, wrong password | | dashboard after a restart |
| Rulers | | yes | | |
| Reads from the object store | | | yes | |

The checks write and read in tenant `default`. The `slow` checks also write in a second tenant,
the backfill tenant. See [What a run changes](#what-a-run-changes). No check proves the isolation
of one tenant from another.

Run times, measured on a warm kind cluster with Garage and on a cloud cluster with S3:

| Markers | Run time |
| --- | --- |
| `smoke` | about 15 s |
| `smoke or verify` | about 2 min |
| `smoke or verify or slow` | 17 to 23 min |

Four full runs, with all three markers, took 17 min 23 s, 19 min 58 s and 22 min 13 s on kind,
and 22 min 42 s on a cloud cluster with S3. A run with `slow` lasts as long as its slowest read
from the object store. See [`slow`](#slow).

## What a run changes

A run installs, upgrades and deletes no release. Without the `disruptive` marker, a run restarts
no workload and deletes no pod. It writes:

- test data in tenant `default`: samples, log lines and traces, labelled with the run id
- one AgentCredential per backend, in the **run's namespace**: a Kubernetes namespace named after
  the run id
- one rule group per ruler, in tenant `default` and the rule namespace of the run
- with the `slow` marker: samples in the backfill tenant, and a flush of the Mimir, Loki and Tempo
  ingesters. Mimir flushes the backfill tenant only, Tempo tenant `default` only, Loki every
  tenant.
- with the `disruptive` marker: one Grafana dashboard, and a restart of the Grafana Deployment.
  The restart replaces the Grafana pod.

The **backfill tenant** is the Mimir tenant `<run id>-backfill`. It holds only the run's 14 h old
samples. Mimir accepts samples that old only in a tenant with no other data.

The **run id** is `verify-<epoch>-<4 hex characters>`, for example `verify-1794785113-6dba`.
The 4 random hex characters tell apart two runs that start in the same second.

- It names the run's namespace and the rule namespace of the run.
- It is the `job` label of the test data and the `service.name` resource attribute of its OTLP
  writes, or their prefix: `<run id>-agent`, `<run id>-backfill`, `<run id>-basic` and
  `<run id>-store`.
- The recording rules of the run carry the label `run=<run id>`.

Teardown deletes:

- the run's namespace, with its AgentCredentials and their Secrets
- the rule namespace of the run in each ruler the run posted the rule group to. A ruler can
  store the group without its `202` answer reaching the run, so teardown deletes it there too.

A failed deletion fails the run. Pytest reports an `ERROR` at the setup or the teardown of a check.
The message names what stayed. For a ruler that never answered `202`, it names what may have
stayed.

These stay on the platform:

- the test data in tenant `default`
- one backfill tenant per `slow` run
- one Grafana dashboard per `disruptive` run, with the UID and title `e2e-pg-<epoch>`, in
  Grafana's org 1

Each is a few kB. The retention differs per backend:

- Mimir and Loki keep the data. The chart sets no retention for them.
- Tempo deletes the traces after 48 h, the block retention of the Tempo subchart.

The checks write and read in tenant `default`. The Grafana checks query the datasources
`gs-mimir`, `gs-loki` and `gs-tempo` of the organization `Main Org.`, Grafana's org 1. The chart's
default GrafanaOrganization takes over this organization. These datasources read the tenant of
`global.tenant`. The default value of `global.tenant` is `default`. With another value,
`test_grafana_query` fails: the datasources read a tenant without the run's data. With Grafana
on SQLite, `test_grafana_uses_postgresql` fails.

## Inputs

| Variable | Default | Effect |
| --- | --- | --- |
| `KUBE_CONTEXT` | current context | kube context of every kubectl call. The run resolves it once at the start. |
| `OBS_NAMESPACE` | `monitoring` | Release namespace of the platform. |
| `OBS_TOKEN_COMMAND` | required | Command that prints a JWT signed by one of `auth.jwt.providers`. See [EXTERNAL_API.md](./EXTERNAL_API.md). |
| `OBS_GATEWAY_ADDRESS` | unset | `host:port` the HTTPS client connects to. Unset, the client connects to the route hostname. |
| `OBS_CA_BUNDLE` | system CA bundle | CA file the HTTPS client checks the certificates against. |
| `OBS_TARGET_FILE` | `tests/ats/target.env` | Path of the target file. Only the environment sets it. |

The token command:

- The run splits it with shell-style quoting and runs it with no shell.
- The command runs again when the token is older than 50 minutes.
- The command must finish within 60 s and print a single token.
- A failure message names its cause: the variable is unset, the exit code, the 60 s timeout, or
  an output that is not a single token.
- A failure message holds neither the output nor the command line. Either can hold a secret.

With `OBS_GATEWAY_ADDRESS`, the client sends the route hostname as SNI and in the `Host` header,
and checks the certificate against it.

kubectl reads `KUBECONFIG` and the variables of its credential plugins from the environment. The
run passes the environment through.

### Target file

The target file holds `KEY=value` lines, one per input:

```
KUBE_CONTEXT=example-admin
OBS_TOKEN_COMMAND=example-token-cli print --audience observability
```

- The environment wins over the target file.
- An empty value counts as unset, in the environment and in the target file.
- The run ignores lines with other keys.
- A missing default target file leaves the inputs to the environment.
- A set `OBS_TARGET_FILE` with a missing file ends the run.
- A relative `OBS_TARGET_FILE` resolves against `tests/ats`, where pytest runs. Use an absolute path.

Git ignores `tests/ats/target.env`. `make local-up` writes it for the kind cluster:

```
KUBE_CONTEXT=kind-kind
OBS_TOKEN_COMMAND=kubectl --context kind-kind exec -n jwt-issuer deploy/jwks -c signer -- /scripts/jwt.sh token
OBS_GATEWAY_ADDRESS=127.0.0.1:8443
OBS_CA_BUNDLE=<repository>/hack/local/.keys/tls.crt
```

`make local-down` and `make local-ats` delete it.

### How the run finds the target

The run reads the target's parts by label from the release namespace. The Gateways are the
exception: the run follows the `parentRefs` of the routes to the Gateways' namespaces.

| Part | Lookup |
| --- | --- |
| External API hostname | HTTPRoutes with `app.kubernetes.io/name=observability-platform-api` |
| Grafana hostname | HTTPRoutes with `app.kubernetes.io/name=grafana` |
| Agent hostnames | HTTPRoutes with `app.kubernetes.io/name` `mimir`, `loki` or `tempo` and `app.kubernetes.io/component=gateway` |
| Gateways | The `parentRefs` of the HTTPRoutes and GRPCRoutes, in the namespaces they name |
| Grafana admin user and password | The Secret with `app.kubernetes.io/name=grafana` and `app.kubernetes.io/component=admin-secret` |
| Mimir rule API | The Service with `app.kubernetes.io/name=mimir` and `app.kubernetes.io/component=gateway` |
| Loki rule API | The Service with `app.kubernetes.io/name=loki` and `app.kubernetes.io/component=backend` |
| Pods to flush, `slow` only | Running pods of `mimir` `ingester`, `loki` `write` and `tempo` `ingester` |
| Tempo querier, `slow` only | Running pods of `tempo` `querier` |

- Each hostname role needs exactly one hostname.
- A Service lookup skips headless Services and needs exactly one match.
- The HTTP port of a Service or a pod is the port named `http-metrics`.

### Rights of the kube context

Read means `get` and `list`. The run's namespace has a new name each run, so the rights in it are
cluster-wide rights.

Cluster-wide:

- Create, get, list, watch and delete namespaces. The teardown waits for the deletion with `get`,
  `list` and `watch`.
- Create and get AgentCredentials, and get Secrets, in the run's namespace.
- Get the Gateways in their namespaces.
- Get the API server version, for `kubectl version` at the start of the run.

In the release namespace:

- Read HTTPRoutes, GRPCRoutes, SecurityPolicies, Services, pods, events, PersistentVolumeClaims
  and Secrets.
- Read and watch Deployments, StatefulSets and DaemonSets, for `kubectl rollout status`.
- Patch Deployments, for the `disruptive` restart of Grafana.
- Get `pods/log`, for the failure dump.
- Create `pods/portforward`, for the port-forwards to a Service or a pod.
- Create `pods/proxy`, for the `slow` flush.

The kind token command needs these rights in namespace `jwt-issuer`:

- Get Deployments, for `deploy/jwks`.
- Get and list pods, for the pod of `deploy/jwks`.
- Create `pods/exec`, for the token script.

Another token command needs its own rights.

## Run

On kind, after `make local-up`:

```bash
make verify
```

`make verify` runs pytest in `tests/ats` with the markers in `VERIFY_MARKERS`. The default is
`smoke or verify`. It sets no input.

```bash
make verify VERIFY_MARKERS="smoke or verify or slow"
```

The direct pytest command:

```bash
cd tests/ats && uv run pytest -m "smoke or verify" -v -rs --tb=short
```

Keep `--tb=short`: the report then shows the failing line and its message only.

### Another cluster

Write a target file outside the repository and point `OBS_TARGET_FILE` at it:

```bash
cat > ~/targets/example.env <<'EOF'
KUBE_CONTEXT=example-admin
OBS_NAMESPACE=monitoring
OBS_TOKEN_COMMAND=example-token-cli print --audience observability
EOF
OBS_TARGET_FILE=$HOME/targets/example.env make verify
```

The routes of this example serve hostnames with public DNS and a certificate from a public CA, so
`OBS_GATEWAY_ADDRESS` and `OBS_CA_BUNDLE` stay unset.

### Run header

The run prints its target before the first check:

```
target file: /home/user/observability-platform/tests/ats/target.env (exists)
kube context: kind-kind
namespace: monitoring
API hostname: observability.localhost
gateway address: 127.0.0.1:8443
CA bundle: /home/user/observability-platform/hack/local/.keys/tls.crt
```

A lookup that fails prints `unknown (<error type>)`.

### When the target does not resolve

The run ends before the first check when the target does not resolve. Pytest exits with code 4
and a message that starts with `The target does not resolve:`. `make verify` then fails with
`Error 4`. The run ends when:

- `OBS_TARGET_FILE` points at a missing file
- `KUBE_CONTEXT` is unset and kubectl has no current context
- the kube context does not exist
- the cluster rejects the credentials
- the API server does not answer, after up to 40 s
- the credential plugin hangs, after up to 60 s

The run header looks up the API hostname first, with a 30 s timeout. Then `kubectl version`
checks the cluster, with a 10 s request timeout and a 30 s timeout.

## Checks

### `smoke`

| Check | Proves | How |
| --- | --- | --- |
| `test_install_workloads_ready` | No Deployment or StatefulSet of the release namespace has 0 replicas, and every Deployment, StatefulSet and DaemonSet has rolled out. | `spec.replicas` once, then `kubectl rollout status` up to 15 min |
| `test_grafana_health` | Grafana answers. | `GET /api/health` |
| `test_grafana_login` | The Grafana admin logs in. | `GET /api/org` with the admin Secret |
| `test_grafana_uses_postgresql` | Grafana stores its data in PostgreSQL. | `GET /api/admin/settings`, database type `postgres` |
| `test_write_metric_otlp`, `test_write_log`, `test_write_trace_otlp` | The external API accepts one write per signal. | OTLP/HTTP JSON for metrics and traces, Loki push for logs |
| `test_read_metric`, `test_read_log`, `test_read_trace` | The external API returns each write. | Prometheus query and Loki range query on the run's `job`, Tempo trace by id |
| `test_auth_read_no_token` | The external API rejects a read without a token. | `401` |
| `test_agent_credential_write_log` | The run's `logs` AgentCredential pushes to the Loki agent host, and the Mimir agent host rejects it. | Push, read back through the API, `401` on Mimir |

### `verify`

| Check | Proves | How |
| --- | --- | --- |
| `test_health_pvcs_bound` | Every PersistentVolumeClaim of the release namespace is `Bound`. | kubectl JSON |
| `test_health_no_container_oomkilled` | No container is `OOMKilled` now or was `OOMKilled` in the last hour. | Container state and last state |
| `test_health_routes_accepted` | Every HTTPRoute and GRPCRoute is `Accepted` and `ResolvedRefs` on each Gateway parent. | Route status |
| `test_health_security_policies_accepted` | Every SecurityPolicy is `Accepted`. | Policy status |
| `test_health_gateways_programmed` | The Gateways of the routes are `Programmed`. | Gateway status |
| `test_api_rejects_garbage_token` | The external API rejects a token that is no JWT, per signal. | `401` |
| `test_api_rejects_token_without_tenant` | The external API rejects a valid token without `X-Scope-OrgID`, per signal. | `401` |
| `test_api_rejects_basic_auth` | The external API rejects an AgentCredential, per signal. | `401` |
| `test_agent_host_rejects_no_credential` | Each agent host rejects a push without a credential. | `401` |
| `test_agent_host_has_no_read_path` | Each agent host serves no read path. | The API returns the run's data. The same read on the agent host, with a valid credential, gets `404`. |
| `test_agent_credential_write_metric`, `test_agent_credential_write_trace` | The run's `metrics` and `traces` AgentCredentials push. | OTLP/HTTP JSON to the agent host, read back through the API |
| `test_grafana_rejects_wrong_password` | Grafana rejects a wrong admin password. | `401` |
| `test_grafana_datasource_health` | The datasources `gs-mimir`, `gs-loki` and `gs-tempo` pass their health check. | `GET /api/datasources/uid/<uid>/health` |
| `test_grafana_query` | Each datasource returns the run's data. | `POST /api/ds/query` over the last hour, match on a returned field |
| `test_ruler_records` | The Mimir ruler and the Loki ruler evaluate a rule group, and its series reaches Mimir. | Post a `vector(1)` recording rule with `run=<run id>` through a port-forward, then read the series through the API within 3 min |

### `slow`

The `slow` checks prove that Mimir, Loki and Tempo serve reads from the object store. A shared
fixture:

1. writes 5 samples 14 h old in the backfill tenant, 2 log lines 4 h old and 1 trace
2. checks that the store-only reads return nothing
3. flushes the ingesters of Mimir, Loki and Tempo through the API server's pod proxy: every
   Running pod of each component. Mimir flushes the backfill tenant only, Tempo tenant `default`
   only. Loki's flush has no tenant scope and flushes every tenant. A Tempo ingester with no data
   of tenant `default` answers 404. At least one Tempo ingester must flush it.

Mimir and Loki query their ingesters for recent data only. A range query over the old data
therefore reads the object store alone.

| Check | Proves | How | Deadline |
| --- | --- | --- | --- |
| `test_store_read_metrics` | The store-gateways serve the backfill samples. | Range query over the 14 h old samples, through the API | 40 min |
| `test_store_read_logs` | The queriers serve the log lines from store chunks. | Range query over the 4 h old lines, with `querier.store.totalChunksRef` above 0 and `ingester.totalReached` at 0 in the stats | 25 min |
| `test_store_read_trace` | A Tempo querier serves the trace from the backend blocks. | `GET /querier/api/traces/<id>?mode=blocks` on a querier pod, through a port-forward | 15 min |

Each check polls every 30 s. The deadlines count from the end of the flush. A run lasts as long as
its slowest read from the object store. Each signal waits for intervals of its own:

- Mimir: the compactor writes the bucket index every 15 min, and the store-gateways sync every
  15 min. The read before the flush makes the queriers cache a missing bucket index for 15 min.
- Loki: the index uploads at the next 15 min rotation, and the readers sync every 5 min.
- Tempo: the ingesters write the tenant index on a 5 min poll, and the queriers poll the
  blocklist every 5 min.

Measured on kind, from the flush to the read from the store:

- Tempo: 104 s to 333 s
- Loki: 333 s to 945 s
- Mimir: 963 s to 1875 s

Mimir took 1875 s, about 31 min, in one measurement outside the full runs. This is inside its
40 min deadline.

### `disruptive`

| Check | Proves | How |
| --- | --- | --- |
| `test_dashboard_survives_grafana_restart` | A dashboard survives a restart of Grafana. | Create a dashboard through the API, `kubectl rollout restart deployment/grafana`, then read the dashboard |

## Out of scope

The setup that installed the platform owns its own checks:

- IRSA, bucket listing, node role, bucket policies, load balancer health and Certificate `Ready`
  on EKS
- the `garage-init` Job on kind: `hack/local/install.sh` waits for it

Checks to add:

- writes while a pod restarts
- the Mimir Alertmanager config
- OTLP/gRPC and Prometheus remote write
- HPA metrics, log contents and events
- upgrades
- tenant isolation

## Read a failure

Pytest prints one `PASSED` or `FAILED` line per check and exits non-zero on a failure. The first
failed check adds a `cluster state` section to its report. A fixture `ERROR` adds none. The
section holds:

- `kubectl get deployments,statefulsets,daemonsets` of the release namespace, with the ready and
  desired replicas of each workload
- `kubectl get pods -o wide` of the release namespace
- the events of the release namespace, oldest first
- the last 100 log lines of each container of each pod that is not ready

### Mimir answers `500 empty ring`

After a fresh install, the Mimir query frontend can answer `500` with `empty ring`. Restart it and
run again:

```bash
kubectl --context <context> -n <namespace> rollout restart deploy/mimir-query-frontend
```
