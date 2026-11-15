"""Fixtures for the app-test-suite tests.

The tests read their target from inputs: environment variables, then the target
file. The setup that installs the platform writes the target file. Every lookup
runs lazily in a fixture: the tests collect without a cluster or a target file.

  KUBE_CONTEXT         kubectl context. Unset, the current context applies.
  OBS_NAMESPACE        Release namespace. Default `monitoring`.
  OBS_TOKEN_COMMAND    Command that prints a JWT for the external API. Required.
  OBS_GATEWAY_ADDRESS  `host:port` the HTTPS client connects to. Unset, it connects
                       to the route hostname.
  OBS_CA_BUNDLE        CA file for the HTTPS client. Unset, the system CA bundle applies.
  OBS_TARGET_FILE      Path of the target file, from the environment only.
                       Default `target.env` next to this file.
"""

import base64
import functools
import json
import os
import shlex
import subprocess
import time
from collections.abc import Iterator
from pathlib import Path

import pytest
import requests

INPUTS = ("KUBE_CONTEXT", "OBS_NAMESPACE", "OBS_TOKEN_COMMAND", "OBS_GATEWAY_ADDRESS", "OBS_CA_BUNDLE")
TARGET_FILE = Path(os.environ.get("OBS_TARGET_FILE") or Path(__file__).resolve().parent / "target.env").absolute()
# The token command re-runs when its token is older than this.
TOKEN_MAX_AGE = 50 * 60
# The tenant of the run's test data.
TENANT = "default"
# The run id: the label of the run's test data and the namespace of its AgentCredentials.
RUN = f"verify-{int(time.time())}"
# The agent host and a write path of each AgentCredential backend.
AGENT_HOSTS = {
    "metrics": ("mimir", "/otlp/v1/metrics"),
    "logs": ("loki", "/loki/api/v1/push"),
    "traces": ("tempo", "/tempo/v1/traces"),
}


@functools.cache
def inputs() -> dict[str, str]:
    """The inputs from the target file, overridden by the environment."""
    values = {}
    if TARGET_FILE.exists():
        for line in TARGET_FILE.read_text().splitlines():
            key, sep, value = line.partition("=")
            if sep and key.strip() in INPUTS:
                values[key.strip()] = value.strip()
    elif "OBS_TARGET_FILE" in os.environ:
        raise FileNotFoundError(f"OBS_TARGET_FILE points at {TARGET_FILE}, which does not exist.")
    values.update({key: os.environ[key] for key in INPUTS if os.environ.get(key)})
    return values


@functools.cache
def context() -> str:
    """The kube context, resolved once so that a later context switch does not move the run."""
    return inputs().get("KUBE_CONTEXT") or subprocess.run(
        ["kubectl", "config", "current-context"], check=True, capture_output=True, text=True
    ).stdout.strip()


def namespace() -> str:
    return inputs().get("OBS_NAMESPACE", "monitoring")


def kubectl(*args: str, input: str | None = None) -> str:
    return subprocess.run(
        ["kubectl", "--context", context(), *args], input=input, check=True, capture_output=True, text=True
    ).stdout


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


@functools.cache
def hostnames() -> dict[str, str]:
    """The route hostnames in the release namespace, by role.

    `api` is the external API, `grafana` is Grafana, `loki`, `mimir` and `tempo` are
    the agent hosts. The charts label each HTTPRoute with the chart that owns it.
    """
    found: dict[str, set[str]] = {}
    for route in json.loads(kubectl("get", "httproute", "-n", namespace(), "-o", "json"))["items"]:
        labels = route["metadata"].get("labels", {})
        name = labels.get("app.kubernetes.io/name")
        if name == "observability-platform-api":
            role = "api"
        elif name == "grafana":
            role = "grafana"
        elif name in ("loki", "mimir", "tempo") and labels.get("app.kubernetes.io/component") == "gateway":
            role = name
        else:
            continue
        found.setdefault(role, set()).update(route["spec"].get("hostnames", []))
    for role, hosts in found.items():
        if len(hosts) != 1:
            raise LookupError(f"The {role} HTTPRoutes in namespace {namespace()} have {len(hosts)} hostnames: {sorted(hosts)}")
    return {role: hosts.pop() for role, hosts in found.items()}


def hostname(role: str) -> str:
    try:
        return hostnames()[role]
    except KeyError:
        raise LookupError(f"No {role} HTTPRoute in namespace {namespace()}") from None


class Gateway:
    """HTTPS client for one route hostname.

    With OBS_GATEWAY_ADDRESS, the client connects to that address and sends the
    hostname in the Host header.
    """

    def __init__(self, hostname: str):
        self.session = requests.Session()
        self.session.verify = inputs().get("OBS_CA_BUNDLE") or True
        address = inputs().get("OBS_GATEWAY_ADDRESS")
        if address:
            self.session.headers["Host"] = hostname
        self.base = f"https://{address or hostname}"

    def request(self, method: str, path: str, **kwargs) -> requests.Response:
        return self.session.request(method, self.base + path, timeout=10, **kwargs)


@pytest.fixture(scope="session")
def grafana() -> Gateway:
    return Gateway(hostname("grafana"))


@pytest.fixture(scope="session")
def api() -> Gateway:
    return Gateway(hostname("api"))


@pytest.fixture(scope="session")
def loki_write() -> Gateway:
    return Gateway(hostname("loki"))


@pytest.fixture(scope="session")
def mimir_write() -> Gateway:
    return Gateway(hostname("mimir"))


class Token:
    """JWT from OBS_TOKEN_COMMAND, re-run when older than TOKEN_MAX_AGE."""

    def __init__(self):
        self.value = ""
        self.issued = 0.0

    def get(self) -> str:
        if self.value and time.monotonic() - self.issued < TOKEN_MAX_AGE:
            return self.value
        command = inputs().get("OBS_TOKEN_COMMAND")
        if not command:
            pytest.fail(f"OBS_TOKEN_COMMAND is not set. Set it in the environment or in the target file {TARGET_FILE}.", pytrace=False)
        result = subprocess.run(shlex.split(command), capture_output=True, text=True)
        if result.returncode != 0 or not result.stdout.strip():
            pytest.fail(f"OBS_TOKEN_COMMAND exited with {result.returncode} and printed no token: {result.stderr.strip()}", pytrace=False)
        self.value = result.stdout.strip()
        self.issued = time.monotonic()
        return self.value


_token = Token()


@pytest.fixture
def token() -> str:
    return _token.get()


@pytest.fixture(scope="session")
def agent_credentials() -> Iterator[dict[str, tuple[str, str]]]:
    """Username and password of the run's AgentCredential per backend.

    Creates the namespace RUN with one AgentCredential per backend. Waits for the
    operator to write each Secret and for each agent host to accept its credential:
    a write with the credential gets an answer other than 401. Teardown deletes the
    namespace.
    """
    items = [{"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": RUN}}] + [
        {
            "apiVersion": "observability.giantswarm.io/v1alpha1",
            "kind": "AgentCredential",
            "metadata": {"name": backend, "namespace": RUN},
            "spec": {"backend": backend},
        }
        for backend in AGENT_HOSTS
    ]
    try:
        kubectl("create", "-f", "-", input=json.dumps({"apiVersion": "v1", "kind": "List", "items": items}))
        credentials = {backend: retry(120, lambda: _agent_credential(backend)) for backend in AGENT_HOSTS}
        for backend, credential in credentials.items():
            role, path = AGENT_HOSTS[backend]
            agent_host = Gateway(hostname(role))

            def accepted():
                response = agent_host.request("POST", path, headers={"X-Scope-OrgID": TENANT}, auth=credential, json={})
                assert response.status_code != 401, f"The {role} agent host answers 401 to the run's {backend} credential."

            retry(300, accepted)
        yield credentials
    finally:
        kubectl("delete", "namespace", RUN, "--ignore-not-found", "--timeout=180s")


def _agent_credential(backend: str) -> tuple[str, str]:
    """Username and password from the Secret the operator writes for an AgentCredential."""
    status = json.loads(kubectl("get", "agentcredential", backend, "-n", RUN, "-o", "json")).get("status", {})
    secret = status.get("secretRef", {}).get("name")
    if not secret:
        raise LookupError(f"The {backend} AgentCredential in namespace {RUN} has no Secret yet.")
    data = json.loads(kubectl("get", "secret", secret, "-n", RUN, "-o", "jsonpath={.data}"))
    return tuple(base64.b64decode(data[key]).decode() for key in ("username", "password"))


def pytest_report_header(config) -> list[str]:
    """The target of the run. Each lookup that fails prints its error instead."""

    def show(lookup) -> str:
        try:
            return lookup()
        except Exception as error:
            return f"unknown ({type(error).__name__})"

    return [
        f"target file: {TARGET_FILE} ({'exists' if TARGET_FILE.exists() else 'missing'})",
        f"kube context: {show(context)}",
        f"namespace: {show(namespace)}",
        f"API hostname: {show(lambda: hostname('api'))}",
        f"gateway address: {show(lambda: inputs().get('OBS_GATEWAY_ADDRESS', 'unset, connects to the hostname'))}",
        f"CA bundle: {show(lambda: inputs().get('OBS_CA_BUNDLE', 'system'))}",
    ]


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
        ["get", "pods", "-n", namespace(), "-o", "wide"],
        ["get", "events", "-n", namespace(), "--sort-by=.lastTimestamp"],
    ):
        out.append(f"$ kubectl {' '.join(args)}\n{_run(args)}")
    try:
        pods = json.loads(_run(["get", "pods", "-n", namespace(), "-o", "json"]))["items"]
    except ValueError:
        pods = []
    for pod in pods:
        if all(c.get("ready") for c in pod["status"].get("containerStatuses", [])):
            continue
        args = ["logs", "-n", namespace(), pod["metadata"]["name"], "--all-containers", "--tail=100"]
        out.append(f"$ kubectl {' '.join(args)}\n{_run(args)}")
    report.sections.append(("cluster state", "\n".join(out)))


def _run(args: list[str]) -> str:
    result = subprocess.run(["kubectl", "--context", context(), *args], capture_output=True, text=True)
    return result.stdout + result.stderr
