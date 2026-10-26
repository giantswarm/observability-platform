"""Fixtures for the app-test-suite tests.

ATS skips its own chart deploy (.ats/main.yaml). The `platform` fixture installs
the prerequisites and the chart under test with hack/local/install.sh, the same
script `make local-up` runs, on the kind cluster ATS hands over in KUBECONFIG.
"""

import json
import os
import subprocess
import time
from pathlib import Path

import pytest
import requests

ROOT = Path(__file__).resolve().parents[2]
NAMESPACE = "monitoring"
CA = ROOT / "hack/local/.keys/tls.crt"
# kind maps the Envoy Gateway `https` NodePort to this address (.ats/kind-config.yaml).
GATEWAY = "https://127.0.0.1:8443"


def kubectl(*args: str) -> str:
    return subprocess.run(["kubectl", *args], check=True, capture_output=True, text=True).stdout


def retry(seconds: int, check):
    """Run check every 5s until it passes. Past the deadline, raise its last error."""
    deadline = time.monotonic() + seconds
    while True:
        try:
            return check()
        except Exception:
            if time.monotonic() >= deadline:
                raise
            time.sleep(5)


class Gateway:
    """HTTPS client for one hostname behind the Envoy Gateway."""

    def __init__(self, hostname: str):
        self.session = requests.Session()
        self.session.verify = str(CA)
        self.session.headers["Host"] = hostname

    def request(self, method: str, path: str, **kwargs) -> requests.Response:
        return self.session.request(method, GATEWAY + path, timeout=10, **kwargs)


@pytest.fixture(scope="session")
def platform():
    chart = ROOT / os.environ["ATS_CHART_PATH"]
    subprocess.run([ROOT / "hack/local/install.sh", chart], check=True)


@pytest.fixture(scope="session")
def grafana(platform) -> Gateway:
    return Gateway("grafana.localhost")


@pytest.fixture(scope="session")
def api(platform) -> Gateway:
    return Gateway("observability.localhost")


@pytest.fixture(scope="session")
def token(platform) -> str:
    return kubectl("exec", "-n", "jwt-issuer", "deploy/jwks", "-c", "signer", "--", "/scripts/jwt.sh", "token").strip()


_dumped = False


@pytest.hookimpl(hookwrapper=True)
def pytest_runtest_makereport(item, call):
    """On the first failure, attach pods, events and logs of not-ready pods."""
    global _dumped
    report = (yield).get_result()
    if report.when != "call" or not report.failed or _dumped:
        return
    _dumped = True
    out = []
    for args in (
        ["get", "pods", "-n", NAMESPACE, "-o", "wide"],
        ["get", "events", "-n", NAMESPACE, "--sort-by=.lastTimestamp"],
    ):
        out.append(f"$ kubectl {' '.join(args)}\n{_run(args)}")
    try:
        pods = json.loads(_run(["get", "pods", "-n", NAMESPACE, "-o", "json"]))["items"]
    except ValueError:
        pods = []
    for pod in pods:
        if all(c.get("ready") for c in pod["status"].get("containerStatuses", [])):
            continue
        args = ["logs", "-n", NAMESPACE, pod["metadata"]["name"], "--all-containers", "--tail=100"]
        out.append(f"$ kubectl {' '.join(args)}\n{_run(args)}")
    report.sections.append(("cluster state", "\n".join(out)))


def _run(args: list[str]) -> str:
    result = subprocess.run(["kubectl", *args], capture_output=True, text=True)
    return result.stdout + result.stderr
