"""Redis-backed task queue for the Sarma Launcher."""

from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from typing import Any, Optional

import redis

from sarma.config import cfg
from sarma.models import Task


def _create_entra_credential_provider():
    """Create a redis CredentialProvider that fetches Entra ID tokens."""
    from azure.identity import DefaultAzureCredential

    credential = DefaultAzureCredential()
    _REDIS_SCOPE = "https://redis.azure.com/.default"

    class EntraCredentialProvider(redis.CredentialProvider):
        def get_credentials(self):
            token = credential.get_token(_REDIS_SCOPE)
            # Azure Managed Redis expects the user's Object ID as username.
            # Extract from the token's 'oid' claim, fall back to env var.
            import json, base64
            try:
                payload = token.token.split(".")[1]
                payload += "=" * (-len(payload) % 4)  # pad base64
                claims = json.loads(base64.b64decode(payload))
                username = claims.get("oid", "default")
            except Exception:
                username = os.environ.get("AZURE_CLIENT_ID", "default")
            return username, token.token

    return EntraCredentialProvider()


def _redis_client(host: str | None = None, port: int | None = None) -> redis.RedisCluster | redis.Redis:
    """Create a Redis client from config or overrides.

    Uses RedisCluster for Azure Managed Redis (cluster mode),
    falls back to standalone Redis if REDIS_CLUSTER=false.
    """
    use_cluster = os.environ.get("REDIS_CLUSTER", "true").lower() in ("true", "1", "yes")

    kwargs: dict[str, Any] = {
        "host": host or cfg.REDIS_HOST,
        "port": port or cfg.REDIS_PORT,
        "ssl": cfg.REDIS_SSL,
        "decode_responses": True,
    }

    if cfg.REDIS_AUTH_MODE == "entra":
        kwargs["credential_provider"] = _create_entra_credential_provider()
    else:
        kwargs["password"] = cfg.REDIS_PASSWORD or None

    if use_cluster:
        # Azure Managed Redis returns internal node IPs for cluster slots;
        # the TLS cert only covers the public hostname, so we must skip
        # hostname verification on internal node connections.
        kwargs["ssl_check_hostname"] = False
        return redis.RedisCluster(**kwargs)
    return redis.Redis(**kwargs)


# ── Key helpers ──────────────────────────────────────────────────────
# Use {sarma} hash tag so all keys land on the same Redis Cluster slot.

def _queue_key(task_type: str) -> str:
    return f"{{sarma}}:tasks:{task_type}"


def _task_key(task_id: str) -> str:
    return f"{{sarma}}:task:{task_id}"


_TASK_INDEX = "{sarma}:task_index"
_WORKERS_SET = "{sarma}:workers"


def _worker_key(worker_id: str) -> str:
    return f"{{sarma}}:worker:{worker_id}"


# ── Task operations ─────────────────────────────────────────────────

def push_task(task: Task, r: redis.Redis | None = None) -> str:
    """Push a task onto its typed queue and store its full data."""
    r = r or _redis_client()
    r.hset(_task_key(task.id), mapping={"data": task.to_json()})
    r.sadd(_TASK_INDEX, task.id)
    r.lpush(_queue_key(task.task_type), task.id)
    return task.id


def pop_task(
    task_types: list[str] | None = None,
    timeout: int | None = None,
    r: redis.Redis | None = None,
) -> Optional[Task]:
    """Pop from one or more typed queues. Returns a Task or None."""
    r = r or _redis_client()
    task_types = task_types or cfg.WORKER_TASK_TYPES
    timeout = timeout if timeout is not None else cfg.WORKER_POLL_TIMEOUT

    keys = [_queue_key(t) for t in task_types]
    result = r.brpop(keys, timeout=timeout)
    if result is None:
        return None

    _queue_name, task_id = result
    raw = r.hget(_task_key(task_id), "data")
    if raw is None:
        return None
    return Task.from_json(raw)


def update_status(
    task_id: str,
    status: str,
    r: redis.Redis | None = None,
    **fields: Any,
) -> None:
    """Update the status (and optional extra fields) of a task."""
    r = r or _redis_client()
    raw = r.hget(_task_key(task_id), "data")
    if raw is None:
        raise KeyError(f"Task {task_id} not found")

    task = Task.from_json(raw)
    task.status = status
    for k, v in fields.items():
        if hasattr(task, k):
            setattr(task, k, v)
    r.hset(_task_key(task_id), mapping={"data": task.to_json()})


def get_task(task_id: str, r: redis.Redis | None = None) -> Optional[Task]:
    """Retrieve a single task by ID."""
    r = r or _redis_client()
    raw = r.hget(_task_key(task_id), "data")
    if raw is None:
        return None
    return Task.from_json(raw)


def list_tasks(
    status_filter: str | None = None,
    r: redis.Redis | None = None,
) -> list[Task]:
    """List all tasks, optionally filtered by status."""
    r = r or _redis_client()
    tasks: list[Task] = []

    task_ids = r.smembers(_TASK_INDEX)
    for task_id in task_ids:
        raw = r.hget(_task_key(task_id), "data")
        if raw:
            task = Task.from_json(raw)
            if status_filter is None or task.status == status_filter:
                tasks.append(task)

    return tasks


def delete_task(task_id: str, r: redis.Redis | None = None) -> None:
    """Remove a task record from Redis."""
    r = r or _redis_client()
    r.delete(_task_key(task_id))
    r.srem(_TASK_INDEX, task_id)


# ── Worker registration ─────────────────────────────────────────────

def register_worker(worker_id: str, r: redis.Redis | None = None) -> None:
    """Register a worker in the active workers set."""
    r = r or _redis_client()
    r.sadd(_WORKERS_SET, worker_id)
    heartbeat(worker_id, r=r)


def heartbeat(worker_id: str, r: redis.Redis | None = None) -> None:
    """Update the worker's last-seen timestamp."""
    r = r or _redis_client()
    now = datetime.now(timezone.utc).isoformat()
    r.hset(_worker_key(worker_id), mapping={"last_seen": now})


def unregister_worker(worker_id: str, r: redis.Redis | None = None) -> None:
    """Remove a worker from the active set."""
    r = r or _redis_client()
    r.srem(_WORKERS_SET, worker_id)
    r.delete(_worker_key(worker_id))


def list_workers(r: redis.Redis | None = None) -> list[dict]:
    """List all registered workers with their heartbeat data."""
    r = r or _redis_client()
    members = r.smembers(_WORKERS_SET)
    workers = []
    for wid in members:
        info = r.hgetall(_worker_key(wid))
        workers.append({"worker_id": wid, **info})
    return workers
