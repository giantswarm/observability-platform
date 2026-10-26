"""Smoke test: workloads ready, Grafana up, one write/read round trip per signal
through the external API, and a 401 without a token.

The tests run in file order and build on each other.
"""

import base64
import secrets
import time

import pytest

from conftest import NAMESPACE, kubectl, retry

pytestmark = pytest.mark.smoke

TENANT = "default"
RUN = f"e2e-{int(time.time())}"
TRACE_ID = secrets.token_hex(16)


def auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}", "X-Scope-OrgID": TENANT}


def now_ns() -> str:
    return str(time.time_ns())


# == Install


def test_install_azurite_init(platform):
    retry(300, lambda: kubectl("wait", "--for=condition=complete", "job/azurite-init", "-n", NAMESPACE, "--timeout=10s"))


def test_install_workloads_ready(platform):
    def rollouts():
        for kind in ("deployment", "statefulset", "daemonset"):
            for name in kubectl("get", kind, "-n", NAMESPACE, "-o", "name").split():
                kubectl("rollout", "status", name, "-n", NAMESPACE, "--timeout=10s")

    retry(900, rollouts)


# == Grafana


def test_grafana_health(grafana):
    retry(300, lambda: grafana.request("GET", "/api/health").raise_for_status())


def test_grafana_login(grafana):
    password = kubectl("get", "secret", "grafana", "-n", NAMESPACE, "-o", "jsonpath={.data.admin-password}")
    grafana.request("GET", "/api/org", auth=("admin", base64.b64decode(password).decode())).raise_for_status()


# == Write, one request per signal, through the external API


def test_write_metric_otlp(api, token):
    body = {
        "resourceMetrics": [{
            "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": RUN}}]},
            "scopeMetrics": [{"metrics": [{
                "name": "e2e_test",
                "gauge": {"dataPoints": [{"asDouble": 42, "timeUnixNano": now_ns()}]},
            }]}],
        }]
    }
    retry(120, lambda: api.request("POST", "/otlp/v1/metrics", headers=auth(token), json=body).raise_for_status())


def test_write_log(api, token):
    body = {"streams": [{"stream": {"job": RUN}, "values": [[now_ns(), f"hello from {RUN}"]]}]}
    retry(120, lambda: api.request("POST", "/loki/api/v1/push", headers=auth(token), json=body).raise_for_status())


def test_write_trace_otlp(api, token):
    start = time.time_ns()
    body = {
        "resourceSpans": [{
            "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": RUN}}]},
            "scopeSpans": [{"spans": [{
                "traceId": TRACE_ID,
                "spanId": "eee19b7ec3c1b174",
                "name": "e2e-test",
                "kind": 1,
                "startTimeUnixNano": str(start),
                "endTimeUnixNano": str(start + 100_000_000),
            }]}],
        }]
    }
    retry(120, lambda: api.request("POST", "/v1/traces", headers=auth(token), json=body).raise_for_status())


# == Read the data back


def read(api, token, path: str, expected: str, **kwargs):
    def check():
        response = api.request("GET", path, headers=auth(token), **kwargs)
        response.raise_for_status()
        assert expected in response.text, response.text

    retry(300, check)


def test_read_metric(api, token):
    read(api, token, "/prometheus/api/v1/query", '"__name__":"e2e_test"', params={"query": "e2e_test"})


def test_read_log(api, token):
    read(api, token, "/loki/api/v1/query_range", f"hello from {RUN}", params={"query": f'{{job="{RUN}"}}'})


def test_read_trace(api, token):
    read(api, token, f"/tempo/api/v2/traces/{TRACE_ID}", RUN)


# == Auth rejection


def test_auth_read_no_token(api):
    response = api.request("GET", "/prometheus/api/v1/query", headers={"X-Scope-OrgID": TENANT}, params={"query": "up"})
    assert response.status_code == 401, response.text
