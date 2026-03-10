"""Tests for sarma.models.Task."""

from sarma.models import Task


def test_task_defaults():
    t = Task(repo="https://example.com/repo.git", prompt="Do something")
    assert t.status == "pending"
    assert t.task_type == "backend"
    assert t.result_branch.startswith("task/")
    assert t.commit_message.startswith("[sarma]")
    assert t.id  # uuid generated


def test_task_json_roundtrip():
    t = Task(repo="https://example.com/repo.git", prompt="Fix the bug")
    json_str = t.to_json()
    t2 = Task.from_json(json_str)
    assert t2.id == t.id
    assert t2.repo == t.repo
    assert t2.prompt == t.prompt
    assert t2.status == t.status
    assert t2.result_branch == t.result_branch


def test_task_dict_roundtrip():
    t = Task(repo="https://example.com/repo.git", prompt="Add tests")
    d = t.to_dict()
    t2 = Task.from_dict(d)
    assert t2.id == t.id
    assert t2.prompt == t.prompt


def test_task_pr_options():
    t = Task(
        repo="https://example.com/repo.git",
        prompt="Refactor auth",
        pr_options={"title": "My PR", "description": "Desc", "reviewers": ["alice"]},
    )
    assert t.pr_options.title == "My PR"
    assert t.pr_options.reviewers == ["alice"]


def test_task_ado_overrides():
    t = Task(
        repo="https://example.com/repo.git",
        prompt="Work",
        ado_org="custom-org",
        ado_project="custom-proj",
    )
    assert t.ado_org == "custom-org"
    assert t.ado_project == "custom-proj"
