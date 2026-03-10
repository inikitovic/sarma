"""Tests for sarma.queue using fakeredis."""

import fakeredis
import pytest

from sarma.models import Task
from sarma.queue import (
    delete_task,
    get_task,
    heartbeat,
    list_tasks,
    list_workers,
    pop_task,
    push_task,
    register_worker,
    unregister_worker,
)


@pytest.fixture
def r():
    """Provide a fakeredis client for each test."""
    return fakeredis.FakeRedis(decode_responses=True)


def test_push_and_get(r):
    task = Task(repo="https://example.com/repo.git", prompt="test push")
    push_task(task, r=r)
    fetched = get_task(task.id, r=r)
    assert fetched is not None
    assert fetched.id == task.id
    assert fetched.prompt == "test push"


def test_push_and_pop(r):
    task = Task(repo="https://example.com/repo.git", prompt="test pop", task_type="backend")
    push_task(task, r=r)
    popped = pop_task(task_types=["backend"], timeout=1, r=r)
    assert popped is not None
    assert popped.id == task.id


def test_pop_empty_queue(r):
    result = pop_task(task_types=["backend"], timeout=1, r=r)
    assert result is None


def test_list_tasks(r):
    t1 = Task(repo="r", prompt="a", status="pending")
    t2 = Task(repo="r", prompt="b", status="completed")
    push_task(t1, r=r)
    push_task(t2, r=r)
    # Update t2 status manually in redis for the test
    from sarma.queue import update_status
    update_status(t2.id, "completed", r=r)

    all_tasks = list_tasks(r=r)
    assert len(all_tasks) == 2

    completed = list_tasks(status_filter="completed", r=r)
    assert len(completed) == 1
    assert completed[0].id == t2.id


def test_delete_task(r):
    task = Task(repo="r", prompt="delete me")
    push_task(task, r=r)
    delete_task(task.id, r=r)
    assert get_task(task.id, r=r) is None


def test_worker_registration(r):
    register_worker("worker-1", r=r)
    ws = list_workers(r=r)
    assert any(w["worker_id"] == "worker-1" for w in ws)

    heartbeat("worker-1", r=r)
    ws = list_workers(r=r)
    w = next(w for w in ws if w["worker_id"] == "worker-1")
    assert "last_seen" in w

    unregister_worker("worker-1", r=r)
    ws = list_workers(r=r)
    assert not any(w["worker_id"] == "worker-1" for w in ws)
