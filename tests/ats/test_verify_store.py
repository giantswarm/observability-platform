"""Slow checks: reads come from the object store.

The `store_data` fixture writes data that only the object store serves once the
ingesters flush it: samples 14h old in a new tenant, log lines 4h old and one
trace. Mimir and Loki query their ingesters for recent data only, so a range query
over the old data reads the object store alone. The fixture checks that the
store-only reads are empty, then flushes the ingesters. Each test polls its signal
until the store-only read returns the data. The deadlines count from the flush, so
the run lasts as long as the longest poll.
"""

import json
import secrets
import time
from collections.abc import Callable

import pytest
import requests

from conftest import RUN, TENANT, KubectlError, auth, forwarded, kubectl, namespace, otlp_span, port_forward, retry

pytestmark = pytest.mark.slow

# The tenant of the backfill samples. It holds only them: its TSDB is empty, so
# Mimir accepts samples 14h old.
BACKFILL_TENANT = f"{RUN}-backfill"
BACKFILL_METRIC = "verify_backfill"
BACKFILL_VALUES = ("100", "101", "102", "103", "104")
BACKFILL_JOB = f"{RUN}-backfill"
BACKFILL_LINES = (f"backfill from {RUN}", f"backfill 2 from {RUN}")
STORE_SERVICE = f"{RUN}-store"
STORE_TRACE_ID = secrets.token_hex(16)
# Per chart: the component of the pods that the fixture flushes, and the flush path.
# Mimir and Tempo flush the run's tenants only. Loki's flush has no tenant scope.
FLUSHES = {
    "mimir": ("ingester", f"/ingester/flush?tenant={BACKFILL_TENANT}&wait=true"),
    "loki": ("ingester", "/flush"),
    "tempo": ("ingester", f"/flush?tenant={TENANT}"),
}
# Per signal: minutes from the flush to the read from the store.
# Mimir: the compactor writes the bucket index, then the store-gateways sync, 15 min each.
# Loki: the index uploads at the next 15 min rotation, then the readers resync every 5 min.
# Tempo: the ingesters write the tenant index on a 5 min poll, and the queriers poll the blocklist every 5 min.
DEADLINES = {"metrics": 40, "logs": 25, "traces": 15}


def pods(chart: str, component: str) -> list[tuple[str, int]]:
    """Name and HTTP port of the Running pods of a chart's component in the release namespace.

    The charts label each pod with the chart (`name`) and the component. The HTTP
    port is the container port named `http-metrics`.
    """
    selector = f"app.kubernetes.io/name={chart},app.kubernetes.io/component={component}"
    found = []
    for pod in json.loads(kubectl("get", "pods", "-n", namespace(), "-l", selector, "-o", "json"))["items"]:
        if pod["status"].get("phase") != "Running":
            print(f"Skipped pod {pod['metadata']['name']}: phase {pod['status'].get('phase')}, not Running")
            continue
        ports = [port["containerPort"] for container in pod["spec"]["containers"] for port in container.get("ports", []) if port.get("name") == "http-metrics"]
        if len(ports) != 1:
            raise LookupError(f"Pod {pod['metadata']['name']} has no single http-metrics port.")
        found.append((pod["metadata"]["name"], ports[0]))
    if not found:
        raise LookupError(f"Namespace {namespace()} has no Running pod with the labels {selector}.")
    return found


def checked(response: requests.Response) -> requests.Response:
    """The response when its status is below 400. Otherwise raise an error with the status and
    the first 500 characters of the body. The error holds no request header."""
    if not response.ok:
        raise requests.HTTPError(f"{response.status_code} {response.reason}: {response.text[:500]}")
    return response


def read_metrics(api, token, params: dict) -> list[str]:
    """The values of the backfill series from a range query over the 14h-old samples."""
    response = checked(api.request("GET", "/prometheus/api/v1/query_range", headers={**auth(token()), "X-Scope-OrgID": BACKFILL_TENANT}, params=params))
    return [value for series in response.json()["data"]["result"] for _, value in series["values"]]


def read_logs(api, token, params: dict) -> tuple[list[str], dict]:
    """The lines and the query stats of a range query over the 4h-old lines."""
    response = checked(api.request("GET", "/loki/api/v1/query_range", headers=auth(token()), params=params))
    data = response.json()["data"]
    return [line for stream in data["result"] for _, line in stream["values"]], data["stats"]


def read_trace_from_blocks() -> requests.Response:
    """Read the trace from the backend blocks only, on a querier pod through a port-forward."""
    pod, port = pods("tempo", "querier")[0]
    params = {"mode": "blocks", "blockStart": "0" * 32, "blockEnd": "f" * 32}
    with port_forward(f"pod/{pod}", port) as address:
        return forwarded("GET", address, f"/querier/api/traces/{STORE_TRACE_ID}", headers={"X-Scope-OrgID": TENANT}, params=params)


def flush() -> None:
    """Flush the ingesters of Mimir, Loki and Tempo through the API server's pod proxy.

    A Tempo ingester answers 404 when it holds no data of the tenant. At least one
    Tempo ingester must flush the tenant. A failed flush, and a Tempo flush that every
    ingester answers with 404, retries the component's pods with a fresh pod list.
    """
    for chart, (component, path) in FLUSHES.items():

        def post() -> int:
            flushed = 0
            for pod, port in pods(chart, component):
                try:
                    kubectl("create", "--raw", f"/api/v1/namespaces/{namespace()}/pods/{pod}:{port}/proxy{path}", "-f", "-", input="{}")
                except KubectlError as error:
                    # A 404 from Tempo. A missing pod prints `pods "<name>" not found` instead.
                    if chart == "tempo" and "(NotFound): the server could not find the requested resource" in error.stderr:
                        continue
                    raise
                flushed += 1
            if not flushed:
                raise LookupError(f"No {chart} {component} pod flushed: each answers 404 to {path}.")
            return flushed

        retry(120, post)


def poll(signal: str, flushed: float, check: Callable[[], None]) -> None:
    """Run check every 30 s until it passes, up to the signal's deadline after the flush."""
    deadline = flushed + DEADLINES[signal] * 60
    while True:
        try:
            check()
            print(f"{signal}: read from the store {time.monotonic() - flushed:.0f} s after the flush")
            return
        except Exception as error:
            elapsed = time.monotonic() - flushed
            if time.monotonic() >= deadline:
                pytest.fail(f"{signal}: no read from the store {elapsed:.0f} s after the flush. Last answer: {error}", pytrace=False)
            print(f"{signal}: not in the store yet, {elapsed:.0f} s after the flush")
            time.sleep(30)


@pytest.fixture(scope="module")
def store_data(api, token) -> dict:
    """Write the backfill samples, the backfill lines and the trace, check that the
    store-only reads are empty, and flush the ingesters.

    Returns the `time.monotonic()` of the end of the flush and the query parameters
    of the two range queries.
    """
    now = int(time.time())
    metric_start = now - 14 * 3600
    log_start = now - 4 * 3600
    samples = [{"asDouble": float(value), "timeUnixNano": str((metric_start + 60 * i) * 10**9)} for i, value in enumerate(BACKFILL_VALUES)]
    metrics = {"resourceMetrics": [{
        "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": BACKFILL_JOB}}]},
        "scopeMetrics": [{"metrics": [{"name": BACKFILL_METRIC, "gauge": {"dataPoints": samples}}]}],
    }]}
    lines = [[str((log_start + 60 * i) * 10**9), line] for i, line in enumerate(BACKFILL_LINES)]
    logs = {"streams": [{"stream": {"job": BACKFILL_JOB}, "values": lines}]}
    retry(120, lambda: api.request("POST", "/otlp/v1/metrics", headers={**auth(token()), "X-Scope-OrgID": BACKFILL_TENANT}, json=metrics).raise_for_status())
    retry(120, lambda: api.request("POST", "/loki/api/v1/push", headers=auth(token()), json=logs).raise_for_status())
    retry(120, lambda: api.request("POST", "/v1/traces", headers=auth(token()), json=otlp_span(STORE_TRACE_ID, "verify-store", STORE_SERVICE)).raise_for_status())

    # Both ranges end well past the data and still 3.5h or more in the past.
    metric_params = {"query": BACKFILL_METRIC, "start": metric_start - 60, "end": metric_start + 600, "step": 60}
    log_params = {"query": f'{{job="{BACKFILL_JOB}"}}', "start": (log_start - 300) * 10**9, "end": (log_start + 1800) * 10**9, "limit": 100}
    # The reads retry on errors. The checks of their answers do not.
    values = retry(60, lambda: read_metrics(api, token, metric_params))
    assert not values, f"metrics: the store-only read returns data before the flush: {values}"
    found, _ = retry(60, lambda: read_logs(api, token, log_params))
    assert not found, f"logs: the store-only read returns data before the flush: {found}"

    def trace_answer() -> requests.Response:
        response = read_trace_from_blocks()
        if response.status_code >= 500:
            checked(response)
        return response

    response = retry(60, trace_answer)
    assert response.status_code == 404, f"traces: the read from the blocks answers {response.status_code} before the flush: {response.text}"

    flush()
    return {"flushed": time.monotonic(), "metrics": metric_params, "logs": log_params}


def test_store_read_metrics(api, token, store_data):
    """A range query over the 14h-old samples returns them from the store-gateways."""

    def found():
        values = read_metrics(api, token, store_data["metrics"])
        assert set(BACKFILL_VALUES) <= set(values), f"values {values}"

    poll("metrics", store_data["flushed"], found)


def test_store_read_logs(api, token, store_data):
    """A range query over the 4h-old lines returns them from store chunks, with no ingester reached."""

    def found():
        lines, stats = read_logs(api, token, store_data["logs"])
        store = stats["querier"]["store"]
        reached = stats["ingester"]["totalReached"]
        summary = f"lines {lines}, querier.store.totalChunksRef {store['totalChunksRef']}, querier.store.totalChunksDownloaded {store['totalChunksDownloaded']}, ingester.totalReached {reached}"
        assert set(BACKFILL_LINES) <= set(lines) and store["totalChunksRef"] > 0 and reached == 0, summary

    poll("logs", store_data["flushed"], found)


def test_store_read_trace(store_data):
    """A querier returns the trace from the backend blocks."""

    def found():
        response = read_trace_from_blocks()
        assert response.status_code == 200 and STORE_SERVICE in response.text, f"{response.status_code} {response.text[:200]}"

    poll("traces", store_data["flushed"], found)
