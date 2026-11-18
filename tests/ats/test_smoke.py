"""Smoke test: workloads ready, Grafana up, one write/read round trip per signal
through the external API, one log pushed with an AgentCredential, and 401s without
a token or with another backend's credential.

The tests run in file order and build on each other.
"""

import json
import secrets

import pytest

from conftest import RUN, TENANT, auth, kubectl, namespace, now_ns, otlp_gauge, otlp_span, read, retry

pytestmark = pytest.mark.smoke

TRACE_ID = secrets.token_hex(16)


# == Install


def test_install_workloads_ready():
    # A workload scaled to 0 counts as rolled out and does not heal by waiting: fail at once.
    workloads = json.loads(kubectl("get", "deployments,statefulsets", "-n", namespace(), "-o", "json"))["items"]
    scaled_to_zero = [f"{w['kind'].lower()}/{w['metadata']['name']} has 0 replicas" for w in workloads if w["spec"].get("replicas") == 0]
    assert not scaled_to_zero, "; ".join(scaled_to_zero)

    def rollouts():
        for kind in ("deployment", "statefulset", "daemonset"):
            for name in kubectl("get", kind, "-n", namespace(), "-o", "name").split():
                kubectl("rollout", "status", name, "-n", namespace(), "--timeout=10s")

    retry(900, rollouts)


# == Grafana


def test_grafana_health(grafana):
    retry(300, lambda: grafana.request("GET", "/api/health").raise_for_status())


def test_grafana_login(grafana, grafana_admin):
    grafana.request("GET", "/api/org", auth=grafana_admin).raise_for_status()


# == Write, one request per signal, through the external API


def test_write_metric_otlp(api, token):
    body = otlp_gauge("e2e_test", 42, RUN)
    retry(120, lambda: api.request("POST", "/otlp/v1/metrics", headers=auth(token()), json=body).raise_for_status())


def test_write_log(api, token):
    body = {"streams": [{"stream": {"job": RUN}, "values": [[now_ns(), f"hello from {RUN}"]]}]}
    retry(120, lambda: api.request("POST", "/loki/api/v1/push", headers=auth(token()), json=body).raise_for_status())


def test_write_trace_otlp(api, token):
    body = otlp_span(TRACE_ID, "e2e-test", RUN)
    retry(120, lambda: api.request("POST", "/v1/traces", headers=auth(token()), json=body).raise_for_status())


# == Read the data back


def test_read_metric(api, token):
    read(api, token, "/prometheus/api/v1/query", f'"job":"{RUN}"', params={"query": f'e2e_test{{job="{RUN}"}}'})


def test_read_log(api, token):
    read(api, token, "/loki/api/v1/query_range", f"hello from {RUN}", params={"query": f'{{job="{RUN}"}}'})


def test_read_trace(api, token):
    read(api, token, f"/tempo/api/v2/traces/{TRACE_ID}", RUN)


# == Auth rejection


def test_auth_read_no_token(api):
    response = api.request("GET", "/prometheus/api/v1/query", headers={"X-Scope-OrgID": TENANT}, params={"query": "up"})
    assert response.status_code == 401, response.text


# == AgentCredentials, through the backends' own routes


def test_agent_credential_write_log(loki_write, mimir_write, api, token, agent_credentials):
    credential = agent_credentials["logs"]
    body = {"streams": [{"stream": {"job": f"{RUN}-basic"}, "values": [[now_ns(), f"basic auth from {RUN}"]]}]}
    headers = {"X-Scope-OrgID": TENANT}
    retry(120, lambda: loki_write.request("POST", "/loki/api/v1/push", headers=headers, auth=credential, json=body).raise_for_status())
    read(api, token, "/loki/api/v1/query_range", f"basic auth from {RUN}", params={"query": f'{{job="{RUN}-basic"}}'})

    # The run has a metrics credential, so Mimir's agent host answers a foreign one with 401,
    # not 500. Retry until the gateway has loaded the run's metrics credential.
    def foreign_credential_rejected():
        response = mimir_write.request("POST", "/otlp/v1/metrics", headers=headers, auth=credential, json={})
        assert response.status_code == 401, response.text

    retry(120, foreign_credential_rejected)
