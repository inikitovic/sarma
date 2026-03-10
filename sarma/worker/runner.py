"""Worker loop: poll queue → execute → commit → PR → repeat."""

from __future__ import annotations

import signal
import sys
import time
from datetime import datetime, timezone

import click

from sarma.config import cfg
from sarma.logging_util import get_logger
from sarma.models import Task
from sarma.queue import (
    heartbeat,
    pop_task,
    register_worker,
    unregister_worker,
    update_status,
)
from sarma.worker.executor import CopilotExecutor
from sarma.worker.git_ops import (
    _run_git,
    cleanup_worktree,
    clone_or_fetch,
    commit_and_push,
    create_worktree,
)
from sarma.worker.pr import create_pull_request

logger = get_logger("sarma.worker")

_shutdown = False
_current_task_id: str | None = None


def _handle_signal(signum: int, frame: object) -> None:
    global _shutdown
    logger.info("Received shutdown signal (%s), finishing current task…", signum)
    _shutdown = True


def _process_task(task: Task, executor: CopilotExecutor) -> None:
    """Process a single task end-to-end."""
    global _current_task_id
    _current_task_id = task.id

    log_extra = {"task_id": task.id}
    logger.info("═══ Task %s [%s] ═══", task.id[:8], task.task_type, extra=log_extra)
    logger.info("  Prompt: %s", task.prompt[:120], extra=log_extra)
    logger.info("  Repo:   %s", task.repo, extra=log_extra)
    logger.info("  Branch: %s → %s", task.branch, task.result_branch, extra=log_extra)

    now = datetime.now(timezone.utc).isoformat()
    update_status(task.id, "running", worker_id=cfg.WORKER_ID, started_at=now)

    start = time.monotonic()
    try:
        # 1. Get repo path (use local if available, otherwise clone)
        if cfg.LOCAL_REPO_PATH:
            repo_path = cfg.LOCAL_REPO_PATH
            logger.info("  [1/5] Using local repo at %s", repo_path, extra=log_extra)
            _run_git("fetch", "--all", "--prune", cwd=repo_path)
            logger.info("  [1/5] ✓ Fetched latest", extra=log_extra)
        else:
            logger.info("  [1/5] Cloning / fetching repo…", extra=log_extra)
            repo_path = clone_or_fetch(task.repo)
            logger.info("  [1/5] ✓ Repo ready at %s", repo_path, extra=log_extra)

        # 2. Create an isolated worktree
        logger.info("  [2/5] Creating worktree %s…", task.result_branch, extra=log_extra)
        wt_path = create_worktree(repo_path, task.result_branch, task.branch)
        logger.info("  [2/5] ✓ Worktree at %s", wt_path, extra=log_extra)

        try:
            # 3. Run the agent
            logger.info("  [3/5] Running executor (%s)…", executor.cli_cmd, extra=log_extra)
            result = executor.run(task.prompt, wt_path)
            logger.info(
                "  [3/5] %s Executor finished (rc=%d)",
                "✓" if result.success else "✗",
                result.exit_code,
                extra={**log_extra, "exit_code": result.exit_code},
            )

            if not result.success:
                raise RuntimeError(f"Executor failed (rc={result.exit_code}): {result.stderr[:500]}")

            # 4. Commit and push
            logger.info("  [4/5] Committing and pushing…", extra=log_extra)
            commit_and_push(wt_path, task.commit_message, task.result_branch)
            logger.info("  [4/5] ✓ Pushed to %s", task.result_branch, extra=log_extra)

            # 5. Create PR
            logger.info("  [5/5] Creating PR…", extra=log_extra)
            repo_name = task.repo.rstrip("/").split("/")[-1].removesuffix(".git")
            pr = create_pull_request(
                repo=repo_name,
                source_branch=task.result_branch,
                target_branch=task.branch,
                title=task.pr_options.title,
                description=task.pr_options.description,
                reviewers=task.pr_options.reviewers or None,
                org=task.ado_org,
                project=task.ado_project,
            )
            logger.info("  [5/5] ✓ PR #%s created", pr.get("pullRequestId", "?"), extra=log_extra)

            # 6. Mark completed
            elapsed = round(time.monotonic() - start, 1)
            done_at = datetime.now(timezone.utc).isoformat()
            update_status(task.id, "completed", completed_at=done_at)
            logger.info(
                "═══ Task %s COMPLETED in %.1fs ═══", task.id[:8], elapsed,
                extra={**log_extra, "duration": elapsed, "status": "completed"},
            )
        finally:
            cleanup_worktree(repo_path, wt_path)

    except Exception as exc:
        elapsed = round(time.monotonic() - start, 1)
        done_at = datetime.now(timezone.utc).isoformat()
        update_status(task.id, "failed", completed_at=done_at, error=str(exc)[:500])
        logger.error(
            "═══ Task %s FAILED after %.1fs: %s ═══", task.id[:8], elapsed, exc,
            extra={**log_extra, "duration": elapsed, "status": "failed"},
        )
    finally:
        _current_task_id = None


@click.command()
@click.option("--types", default=None, help="Comma-separated task types to consume.")
@click.option("--concurrency", default=None, type=int, help="Max concurrent tasks (reserved for future use).")
@click.option("--live", is_flag=True, help="Stream executor output to terminal (interactive mode).")
def main(types: str | None, concurrency: int | None, live: bool) -> None:
    """Start a Sarma worker that polls the task queue."""
    signal.signal(signal.SIGINT, _handle_signal)
    signal.signal(signal.SIGTERM, _handle_signal)

    task_types = types.split(",") if types else cfg.WORKER_TASK_TYPES
    logger.info("Worker %s starting — types=%s, live=%s", cfg.WORKER_ID, task_types, live)

    register_worker(cfg.WORKER_ID)
    executor = CopilotExecutor(live=live)

    try:
        logger.info("Polling for tasks…")
        while not _shutdown:
            heartbeat(cfg.WORKER_ID)
            task = pop_task(task_types=task_types)
            if task is None:
                continue  # timeout, loop again
            _process_task(task, executor)
    finally:
        if _current_task_id is not None:
            logger.info("Resetting interrupted task %s to pending", _current_task_id[:8])
            update_status(_current_task_id, "pending")
        unregister_worker(cfg.WORKER_ID)
        logger.info("Worker %s shut down.", cfg.WORKER_ID)


if __name__ == "__main__":
    main()
