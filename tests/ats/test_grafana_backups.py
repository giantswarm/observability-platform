"""Grafana's PostgreSQL backups (setup/scripts/install.sh turns them on against Garage): an
on-demand base backup completes, and its files land in the Garage `grafana-postgresql`
bucket.

The tests skip on a target without backups, and the bucket listing skips on a store other
than the local Garage. The tests run in file order and build on each other.
"""

import json
import time

import pytest

from conftest import KubectlError, kubectl, namespace, retry

pytestmark = pytest.mark.smoke

CLUSTER = "grafana-postgresql"
BACKUP = f"e2e-backup-{int(time.time())}"
# The bucket the local setup creates, global.objectStorage.buckets.grafanaPostgresql.
BUCKET = "grafana-postgresql"
GARAGE = "http://garage.monitoring.svc.cluster.local:3900"


@pytest.fixture(scope="module")
def backups_on() -> None:
    try:
        kubectl("get", "objectstore.barmancloud.cnpg.io", f"{CLUSTER}-objectstore-backup", "-n", namespace())
    except KubectlError:
        pytest.skip("Grafana's backups are off on this target")


@pytest.fixture(scope="module")
def backup_id(backups_on) -> str:
    """The ID of a base backup taken for this run, once it completed."""
    manifest = {
        "apiVersion": "postgresql.cnpg.io/v1",
        "kind": "Backup",
        "metadata": {"name": BACKUP, "namespace": namespace()},
        "spec": {
            "cluster": {"name": CLUSTER},
            "method": "plugin",
            "pluginConfiguration": {"name": "barman-cloud.cloudnative-pg.io"},
        },
    }
    retry(900, lambda: kubectl("wait", f"cluster.postgresql.cnpg.io/{CLUSTER}", "-n", namespace(), "--for=condition=Ready", "--timeout=10s"))
    kubectl("apply", "-f", "-", input=json.dumps(manifest))

    def completed():
        status = json.loads(kubectl("get", "backup.postgresql.cnpg.io", BACKUP, "-n", namespace(), "-o", "jsonpath={.status}") or "{}")
        if status.get("phase") == "failed":
            pytest.fail(f"backup {BACKUP} failed: {status.get('error')}")
        assert status.get("phase") == "completed", status
        return status["backupId"]

    yield retry(600, completed)
    kubectl("delete", "backup.postgresql.cnpg.io", BACKUP, "-n", namespace(), "--ignore-not-found")


def test_backup_completes(backup_id):
    assert backup_id


def test_backup_in_garage_bucket(backup_id):
    try:
        kubectl("get", "secret", "garage-credentials", "-n", namespace())
    except KubectlError:
        pytest.skip("the store is not the local Garage")
    container = {
        "name": "ls",
        "image": "amazon/aws-cli:2.41.0",
        "args": ["--endpoint-url", GARAGE, "--region", "garage", "s3", "ls", f"s3://{BUCKET}/{CLUSTER}/base/", "--recursive"],
        "envFrom": [{"secretRef": {"name": "garage-credentials"}}],
        "env": [{"name": "HOME", "value": "/tmp"}],
        "securityContext": {
            "allowPrivilegeEscalation": False,
            "capabilities": {"drop": ["ALL"]},
            "runAsNonRoot": True,
            "runAsUser": 1000,
            "seccompProfile": {"type": "RuntimeDefault"},
        },
    }
    overrides = json.dumps({"spec": {"restartPolicy": "Never", "containers": [container]}})
    listing = kubectl(
        "run", f"{BACKUP}-ls", "-n", namespace(), "--rm", "-i", "--quiet", "--restart=Never",
        "--image", container["image"], "--overrides", overrides,
        timeout=180,
    )
    assert f"{CLUSTER}/base/{backup_id}/" in listing, listing
