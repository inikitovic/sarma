"""Master CLI for the Sarma Launcher."""

from __future__ import annotations

import os
import subprocess
import sys

import click

from sarma.config import cfg
from sarma.models import Task
from sarma.queue import (
    delete_task,
    get_task,
    list_tasks,
    list_workers,
    push_task,
)


@click.group()
def cli() -> None:
    """Sarma Launcher — distributed coding task orchestrator."""


@cli.command()
@click.option("--repo", required=True, help="Repository clone URL.")
@click.option("--branch", default="main", help="Base branch to fork from.")
@click.option("--type", "task_type", default="backend", type=click.Choice(["backend", "frontend", "test", "docs"]), help="Task type for routing.")
@click.option("--prompt", required=True, help="Agent prompt describing the task.")
@click.option("--reviewer", multiple=True, help="Reviewer alias(es) for the PR.")
@click.option("--ado-org", default=None, help="Override ADO organization.")
@click.option("--ado-project", default=None, help="Override ADO project.")
def submit(
    repo: str,
    branch: str,
    task_type: str,
    prompt: str,
    reviewer: tuple[str, ...],
    ado_org: str | None,
    ado_project: str | None,
) -> None:
    """Submit a new task to the sarma queue."""
    task = Task(
        repo=repo,
        branch=branch,
        task_type=task_type,
        prompt=prompt,
        pr_options={"title": "", "description": "", "reviewers": list(reviewer)},
        ado_org=ado_org,
        ado_project=ado_project,
    )
    task_id = push_task(task)
    click.echo(f"✅ Task submitted: {task_id}")
    click.echo(f"   Type: {task_type} | Branch: {task.result_branch}")


@cli.command()
@click.option("--filter", "status_filter", default=None, type=click.Choice(["pending", "running", "completed", "failed"]), help="Filter by status.")
def status(status_filter: str | None) -> None:
    """Show status of all tasks."""
    tasks = list_tasks(status_filter=status_filter)
    if not tasks:
        click.echo("No tasks found.")
        return

    click.echo(f"{'ID':<38} {'TYPE':<10} {'STATUS':<12} {'WORKER':<20} {'BRANCH'}")
    click.echo("─" * 100)
    for t in tasks:
        click.echo(
            f"{t.id:<38} {t.task_type:<10} {t.status:<12} "
            f"{(t.worker_id or '—'):<20} {t.result_branch}"
        )


@cli.command()
def workers() -> None:
    """Show registered workers and their heartbeat status."""
    ws = list_workers()
    if not ws:
        click.echo("No workers registered.")
        return

    click.echo(f"{'WORKER ID':<30} {'LAST SEEN'}")
    click.echo("─" * 60)
    for w in ws:
        click.echo(f"{w['worker_id']:<30} {w.get('last_seen', '—')}")


@cli.command()
@click.argument("task_id")
def logs(task_id: str) -> None:
    """Show details and logs for a specific task."""
    task = get_task(task_id)
    if task is None:
        click.echo(f"Task {task_id} not found.")
        return

    click.echo(f"Task:    {task.id}")
    click.echo(f"Status:  {task.status}")
    click.echo(f"Type:    {task.task_type}")
    click.echo(f"Worker:  {task.worker_id or '—'}")
    click.echo(f"Branch:  {task.result_branch}")
    click.echo(f"Created: {task.created_at}")
    click.echo(f"Started: {task.started_at or '—'}")
    click.echo(f"Done:    {task.completed_at or '—'}")
    if task.error:
        click.echo(f"Error:   {task.error}")
    click.echo(f"\nPrompt:\n  {task.prompt}")


@cli.command()
@click.option("--completed", is_flag=True, help="Prune completed tasks.")
@click.option("--failed", is_flag=True, help="Prune failed tasks.")
@click.option("--all", "prune_all", is_flag=True, help="Prune all non-running tasks.")
@click.confirmation_option(prompt="Are you sure you want to prune tasks?")
def prune(completed: bool, failed: bool, prune_all: bool) -> None:
    """Remove completed/failed task records from the queue."""
    statuses = set()
    if completed or prune_all:
        statuses.add("completed")
    if failed or prune_all:
        statuses.add("failed")
    if prune_all:
        statuses.add("pending")

    if not statuses:
        click.echo("Specify --completed, --failed, or --all.")
        return

    pruned = 0
    for s in statuses:
        for t in list_tasks(status_filter=s):
            delete_task(t.id)
            pruned += 1

    click.echo(f"🗑️  Pruned {pruned} task(s).")


@cli.command()
@click.argument("worker_or_task")
@click.option("--user", default=None, help="SSH username (default: current user).")
@click.option("--method", default="ssh", type=click.Choice(["ssh", "rdp", "devbox"]), help="Connection method.")
def attach(worker_or_task: str, user: str | None, method: str) -> None:
    """Attach to a Dev Box worker's terminal via SSH/RDP.

    WORKER_OR_TASK can be a worker ID (hostname) or a task ID.
    If a task ID is given, resolves to the worker running it.

    Examples:

      sarma attach CPC-iniki-JIZGB

      sarma attach ec76c20d-8bec-40eb-9304-db40f0635556

      sarma attach CPC-iniki-JIZGB --method rdp
    """
    # Resolve task ID to worker hostname
    target = worker_or_task
    task = get_task(worker_or_task)
    if task and task.worker_id:
        click.echo(f"Task {worker_or_task[:8]} is on worker: {task.worker_id}")
        target = task.worker_id
    elif task and not task.worker_id:
        click.echo(f"Task {worker_or_task[:8]} has no assigned worker yet.")
        return

    user = user or os.environ.get("USERNAME") or os.environ.get("USER") or "azureuser"

    if method == "ssh":
        click.echo(f"Connecting via SSH to {target} as {user}…")
        cmd = ["ssh", f"{user}@{target}"]
        os.execvp("ssh", cmd)

    elif method == "rdp":
        click.echo(f"Opening RDP to {target}…")
        if sys.platform == "win32":
            subprocess.run(["mstsc", f"/v:{target}"], check=False)
        else:
            click.echo(f"Run: xfreerdp /v:{target} /u:{user}")

    elif method == "devbox":
        click.echo(f"Connecting via Dev Box CLI to {target}…")
        cmd = ["az", "network", "bastion", "ssh",
               "--name", os.environ.get("BASTION_NAME", ""),
               "--resource-group", os.environ.get("BASTION_RG", ""),
               "--target-resource-id", target,
               "--auth-type", "AAD"]
        click.echo(f"  {' '.join(cmd)}")
        os.execvp("az", cmd)


if __name__ == "__main__":
    cli()
