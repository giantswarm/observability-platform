"""Verify checks: the health of the release, the rejections of the external API and
the agent hosts, writes with the run's AgentCredentials, Grafana and the rulers.

Each test stands alone: the tests that read data depend on the `agent_data`
fixture, which writes it, and the ruler tests on the `rule_groups` fixture.
"""

import json
import secrets
from collections.abc import Iterator
from datetime import datetime, timedelta, timezone

import pytest
import requests

from conftest import (
    AGENT_HOSTS,
    RUN,
    TENANT,
    Gateway,
    auth,
    forwarded,
    hostname,
    kubectl,
    namespace,
    now_ns,
    otlp_gauge,
    otlp_span,
    port_forward,
    read,
    retry,
    service,
)

pytestmark = pytest.mark.verify

# The data the run writes with its AgentCredentials.
AGENT_JOB = f"{RUN}-agent"
AGENT_METRIC = "verify_agent"
AGENT_LINE = f"agent line from {RUN}"
AGENT_TRACE_ID = secrets.token_hex(16)
# A fixed dummy, not a secret.
GARBAGE = "not-a-token"
# One read request per signal on the external API.
API_READS = {
    "metrics": ("/prometheus/api/v1/query", {"query": "up"}),
    "logs": ("/loki/api/v1/query_range", {"query": f'{{job="{RUN}"}}'}),
    "traces": (f"/tempo/api/v2/traces/{AGENT_TRACE_ID}", {}),
}
# The instant query of the run's sample. The sample is written once: `last_over_time` over
# 1h returns it however long the tests before the read take.
AGENT_METRIC_QUERY = f'last_over_time({AGENT_METRIC}{{job="{AGENT_JOB}"}}[1h])'
# One read per agent host: the path, the parameters and a string that only an answer
# with the run's data holds. The agent hosts route write paths only.
AGENT_READS = {
    "metrics": ("/prometheus/api/v1/query", {"query": AGENT_METRIC_QUERY}, f'"job":"{AGENT_JOB}"'),
    "logs": ("/loki/api/v1/query_range", {"query": f'{{job="{AGENT_JOB}"}}'}, AGENT_LINE),
    "traces": (f"/tempo/api/v2/traces/{AGENT_TRACE_ID}", {}, AGENT_JOB),
}
DATASOURCES = ("gs-mimir", "gs-loki", "gs-tempo")


def items(kind: str, *args: str) -> list[dict]:
    return json.loads(kubectl("get", kind, *args, "-o", "json"))["items"]


def false_conditions(conditions: list[dict], *types: str) -> list[str]:
    """The condition types of `types` that are missing or not True."""
    status = {condition["type"]: condition["status"] for condition in conditions}
    return [name for name in types if status.get(name) != "True"]


# == Health


def test_health_pvcs_bound():
    def bound():
        pvcs = items("persistentvolumeclaims", "-n", namespace())
        assert pvcs, f"Namespace {namespace()} has no PVC."
        unbound = [f"{pvc['metadata']['name']}={pvc['status'].get('phase')}" for pvc in pvcs if pvc["status"].get("phase") != "Bound"]
        assert not unbound, f"PVCs not Bound: {unbound}"

    retry(120, bound)


def test_health_no_container_oomkilled():
    """No container is OOMKilled now, and none was OOMKilled within the last hour.

    The last state of a container keeps an OOMKill until the next restart, so an
    older OOMKill does not fail the check.
    """
    since = datetime.now(timezone.utc) - timedelta(hours=1)
    oomkilled = []
    for pod in items("pods", "-n", namespace()):
        statuses = pod["status"].get("initContainerStatuses", []) + pod["status"].get("containerStatuses", [])
        for container in statuses:
            name = f"{pod['metadata']['name']}/{container['name']}"
            current = container.get("state", {}).get("terminated", {})
            if current.get("reason") == "OOMKilled":
                oomkilled.append(f"{name} is OOMKilled, finished at {current.get('finishedAt')}")
            last = container.get("lastState", {}).get("terminated", {})
            finished = last.get("finishedAt")
            if last.get("reason") == "OOMKilled" and (not finished or datetime.fromisoformat(finished) >= since):
                oomkilled.append(f"{name} was OOMKilled, finished at {finished}")
    assert not oomkilled, f"Containers OOMKilled: {oomkilled}"


def route_parents() -> tuple[list[str], set[tuple[str, str]]]:
    """The route parents that are not Accepted and ResolvedRefs, and the Gateways the routes attach to."""
    failures = []
    gateways = set()
    routes = items("httproutes.gateway.networking.k8s.io", "-n", namespace()) + items("grpcroutes.gateway.networking.k8s.io", "-n", namespace())
    assert routes, f"Namespace {namespace()} has no HTTPRoute or GRPCRoute."
    for route in routes:
        name = f"{route['kind']}/{route['metadata']['name']}"
        statuses = {
            (parent["parentRef"]["name"], parent["parentRef"].get("namespace", namespace()), parent["parentRef"].get("sectionName")): parent
            for parent in route.get("status", {}).get("parents", [])
        }
        for ref in route["spec"].get("parentRefs", []):
            if ref.get("kind", "Gateway") != "Gateway":
                continue
            key = (ref["name"], ref.get("namespace", namespace()), ref.get("sectionName"))
            gateways.add(key[:2])
            parent = statuses.get(key)
            if parent is None:
                failures.append(f"{name} has no status for parent {key}")
                continue
            missing = false_conditions(parent.get("conditions", []), "Accepted", "ResolvedRefs")
            if missing:
                failures.append(f"{name} on parent {key} is not {missing}")
    return failures, gateways


def test_health_routes_accepted():
    def accepted():
        failures, _ = route_parents()
        assert not failures, failures

    retry(120, accepted)


def test_health_security_policies_accepted():
    def accepted():
        policies = items("securitypolicies.gateway.envoyproxy.io", "-n", namespace())
        assert policies, f"Namespace {namespace()} has no SecurityPolicy."
        failures = []
        for policy in policies:
            ancestors = policy.get("status", {}).get("ancestors", [])
            if not ancestors:
                failures.append(f"{policy['metadata']['name']} has no ancestor status")
            for ancestor in ancestors:
                if false_conditions(ancestor.get("conditions", []), "Accepted"):
                    failures.append(f"{policy['metadata']['name']} is not Accepted on {ancestor['ancestorRef'].get('name')}")
        assert not failures, failures

    retry(120, accepted)


def test_health_gateways_programmed():
    """The Gateways the routes attach to, wherever they live, are Programmed."""

    def programmed():
        _, gateways = route_parents()
        assert gateways, f"The routes in namespace {namespace()} attach to no Gateway."
        failures = []
        for name, gateway_namespace in sorted(gateways):
            gateway = json.loads(kubectl("get", "gateways.gateway.networking.k8s.io", name, "-n", gateway_namespace, "-o", "json"))
            if false_conditions(gateway.get("status", {}).get("conditions", []), "Programmed"):
                failures.append(f"Gateway {gateway_namespace}/{name} is not Programmed")
        assert not failures, failures

    retry(120, programmed)


# == Rejections


@pytest.mark.parametrize("signal", API_READS)
def test_api_rejects_garbage_token(api, signal):
    path, params = API_READS[signal]
    response = api.request("GET", path, headers={"Authorization": f"Bearer {GARBAGE}", "X-Scope-OrgID": TENANT}, params=params)
    assert response.status_code == 401, response.text


@pytest.mark.parametrize("signal", API_READS)
def test_api_rejects_token_without_tenant(api, token, signal):
    path, params = API_READS[signal]
    response = api.request("GET", path, headers={"Authorization": f"Bearer {token()}"}, params=params)
    assert response.status_code == 401, response.text


@pytest.mark.parametrize("signal", API_READS)
def test_api_rejects_basic_auth(api, agent_credentials, signal):
    path, params = API_READS[signal]
    response = api.request("GET", path, headers={"X-Scope-OrgID": TENANT}, auth=agent_credentials[signal], params=params)
    assert response.status_code == 401, response.text


@pytest.mark.parametrize("backend", AGENT_HOSTS)
def test_agent_host_rejects_no_credential(agent_credentials, backend):
    """The agent host has credentials to check: the run's AgentCredentials exist."""
    role, path = AGENT_HOSTS[backend]
    response = Gateway(hostname(role)).request("POST", path, headers={"X-Scope-OrgID": TENANT}, json={})
    assert response.status_code == 401, response.text


@pytest.mark.parametrize("backend", AGENT_READS)
def test_agent_host_has_no_read_path(api, token, agent_credentials, agent_data, backend):
    """The external API answers a read with the run's data. The same read on the agent
    host, with a valid credential, gets 404. The Mimir and Loki agent hosts route push
    paths only, so the 404 comes from the Gateway. The Tempo agent host routes every
    path under `/tempo` to the distributor, so the 404 comes from its OTLP receiver."""
    path, params, expected = AGENT_READS[backend]
    read(api, token, path, expected, params=params)
    role, _ = AGENT_HOSTS[backend]
    response = Gateway(hostname(role)).request("GET", path, headers={"X-Scope-OrgID": TENANT}, auth=agent_credentials[backend], params=params)
    assert response.status_code == 404, response.text


# == Writes with the run's AgentCredentials, read back through the external API


@pytest.fixture(scope="module")
def agent_data(agent_credentials) -> None:
    """Write one sample, one log line and one span through the agent hosts with the run's AgentCredentials."""
    bodies = {
        "metrics": otlp_gauge(AGENT_METRIC, 7, AGENT_JOB),
        "logs": {"streams": [{"stream": {"job": AGENT_JOB}, "values": [[now_ns(), AGENT_LINE]]}]},
        "traces": otlp_span(AGENT_TRACE_ID, "verify-agent", AGENT_JOB),
    }
    for backend, body in bodies.items():
        role, path = AGENT_HOSTS[backend]
        agent_host = Gateway(hostname(role))
        credential = agent_credentials[backend]
        retry(120, lambda: agent_host.request("POST", path, headers={"X-Scope-OrgID": TENANT}, auth=credential, json=body).raise_for_status())


def test_agent_credential_write_metric(api, token, agent_data):
    read(api, token, "/prometheus/api/v1/query", f'"job":"{AGENT_JOB}"', params={"query": AGENT_METRIC_QUERY})


def test_agent_credential_write_trace(api, token, agent_data):
    read(api, token, f"/tempo/api/v2/traces/{AGENT_TRACE_ID}", AGENT_JOB)


# == Grafana


def test_grafana_rejects_wrong_password(grafana, grafana_admin):
    user, _ = grafana_admin
    response = grafana.request("GET", "/api/org", auth=(user, "wrong-password"))
    assert response.status_code == 401, response.text


@pytest.mark.parametrize("uid", DATASOURCES)
def test_grafana_datasource_health(grafana, grafana_admin, uid):
    def healthy():
        response = grafana.request("GET", f"/api/datasources/uid/{uid}/health", auth=grafana_admin)
        assert response.status_code == 200 and response.json().get("status") == "OK", response.text

    retry(120, healthy)


# Per datasource: the query over the last hour, and a match on one returned field and
# its values. The match reads the returned data: Grafana echoes the query expression
# in the frame metadata, also for an empty answer.
GRAFANA_QUERIES = {
    "gs-mimir": (
        {"expr": f'{AGENT_METRIC}{{job="{AGENT_JOB}"}}', "range": True, "instant": False},
        lambda field, values: field.get("labels", {}).get("job") == AGENT_JOB and 7 in values,
    ),
    "gs-loki": (
        {"expr": f'{{job="{AGENT_JOB}"}}', "queryType": "range"},
        lambda field, values: field["name"] in ("Line", "body") and AGENT_LINE in values,
    ),
    "gs-tempo": (
        {"queryType": "traceId", "query": AGENT_TRACE_ID},
        lambda field, values: field["name"] == "serviceName" and AGENT_JOB in values,
    ),
}


@pytest.mark.parametrize("uid", GRAFANA_QUERIES)
def test_grafana_query(grafana, grafana_admin, agent_data, uid):
    query, match = GRAFANA_QUERIES[uid]
    body = {"queries": [{"refId": "A", "datasource": {"uid": uid}, **query}], "from": "now-1h", "to": "now"}

    def found():
        response = grafana.request("POST", "/api/ds/query", auth=grafana_admin, json=body)
        response.raise_for_status()
        frames = response.json()["results"]["A"].get("frames", [])
        fields = [pair for frame in frames for pair in zip(frame["schema"]["fields"], frame.get("data", {}).get("values", []))]
        assert any(match(field, values) for field, values in fields), response.text

    retry(300, found)


# == Rulers

# Per ruler: the chart and component of the Service that serves its rule API, the
# rule API path, and the recording rule the run's group holds.
RULERS = {
    "mimir": ("mimir", "gateway", "/prometheus/config/v1/rules", "verify:const"),
    "loki": ("loki", "backend", "/loki/api/v1/rules", "verify:loki_const"),
}


def ruler_request(ruler: str, method: str, **kwargs) -> requests.Response:
    """Send a request for the rule namespace RUN to a ruler's API through a port-forward.

    The rule APIs have no authentication of their own: the tenant header selects the tenant.
    """
    name, component, path, _ = RULERS[ruler]
    target, port = service(name, component)
    with port_forward(target, port) as address:
        return forwarded(method, address, f"{path}/{RUN}", **kwargs)


@pytest.fixture(scope="module")
def rule_groups() -> Iterator[None]:
    """One rule group per ruler in tenant TENANT and rule namespace RUN.

    Each group holds a `vector(1)` recording rule with the label `run=RUN`, so that a
    series an earlier run recorded never matches. Teardown deletes the rule namespace
    in each ruler the run posted to, also when no 202 reached the run: the ruler may
    store the group all the same. It raises once when a deletion fails, so the run fails.
    """
    # Per ruler the run posted to: True once the ruler answered 202.
    attempted: dict[str, bool] = {}
    try:
        for ruler, (_, _, _, record) in RULERS.items():
            group = {"name": "verify", "interval": "15s", "rules": [{"record": record, "expr": "vector(1)", "labels": {"run": RUN}}]}

            def created():
                # JSON is YAML: the rule APIs read the body as YAML.
                response = ruler_request(ruler, "POST", headers={"X-Scope-OrgID": TENANT, "Content-Type": "application/yaml"}, data=json.dumps(group))
                assert response.status_code == 202, f"The {ruler} ruler answers {response.status_code} to the rule group: {response.text}"

            attempted[ruler] = False
            retry(60, created)
            attempted[ruler] = True
        yield
    finally:
        failures = []
        for ruler, accepted in attempted.items():

            def deleted():
                response = ruler_request(ruler, "DELETE", headers={"X-Scope-OrgID": TENANT})
                assert response.status_code in (200, 202, 404), f"The {ruler} ruler answers {response.status_code} to the deletion: {response.text}"

            try:
                retry(60, deleted)
            except Exception as error:
                left = "left" if accepted else "may have left"
                failures.append(f"Teardown {left} rule namespace {RUN} of tenant {TENANT} in the {ruler} ruler: {error}")
        if failures:
            raise RuntimeError("; ".join(failures))


@pytest.mark.parametrize("ruler", RULERS)
def test_ruler_records(api, token, rule_groups, ruler):
    """The ruler evaluates the run's recording rule, and its series is readable through the external API within 3 min."""
    record = RULERS[ruler][3]

    def recorded():
        response = api.request("GET", "/prometheus/api/v1/query", headers=auth(token()), params={"query": f'{record}{{run="{RUN}"}}'})
        response.raise_for_status()
        assert f'"run":"{RUN}"' in response.text, response.text

    retry(180, recorded)
