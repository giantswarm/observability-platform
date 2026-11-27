"""Grafana on PostgreSQL, the chart's default (setup/scripts/install.sh installs the CNPG operator):
Grafana uses the database, and a dashboard created through its API survives a restart of
the Grafana pod.

The tests run in file order and build on each other.
"""

import base64
import time

import pytest

from conftest import kubectl, namespace, retry

pytestmark = pytest.mark.smoke

UID = f"e2e-pg-{int(time.time())}"


@pytest.fixture(scope="module")
def admin(grafana) -> tuple[str, str]:
    password = kubectl("get", "secret", "grafana", "-n", namespace(), "-o", "jsonpath={.data.admin-password}")
    retry(900, lambda: grafana.request("GET", "/api/health").raise_for_status())
    return "admin", base64.b64decode(password).decode()


def test_grafana_uses_postgresql(grafana, admin):
    def check():
        response = grafana.request("GET", "/api/admin/settings", auth=admin)
        response.raise_for_status()
        assert response.json()["database"]["type"] == "postgres", response.text

    retry(300, check)


def test_dashboard_survives_grafana_restart(grafana, admin):
    dashboard = {"dashboard": {"uid": UID, "title": UID, "panels": []}, "overwrite": True}
    retry(120, lambda: grafana.request("POST", "/api/dashboards/db", auth=admin, json=dashboard).raise_for_status())

    kubectl("rollout", "restart", "deployment/grafana", "-n", namespace())
    kubectl("rollout", "status", "deployment/grafana", "-n", namespace(), "--timeout=5m")

    def check():
        response = grafana.request("GET", f"/api/dashboards/uid/{UID}", auth=admin)
        response.raise_for_status()
        assert response.json()["dashboard"]["title"] == UID, response.text

    retry(300, check)
