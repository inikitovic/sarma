"""Git operations: clone, worktree, commit, push, cleanup."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

from sarma.config import cfg


def _run_git(*args: str, cwd: str | None = None) -> subprocess.CompletedProcess[str]:
    """Run a git command and return the result."""
    result = subprocess.run(
        ["git", *args],
        cwd=cwd,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"git {' '.join(args)} failed (rc={result.returncode}): {result.stderr.strip()}"
        )
    return result


def clone_or_fetch(repo_url: str, base_dir: str | None = None) -> str:
    """Clone the repo if it doesn't exist locally, otherwise fetch.

    Returns the path to the bare/main clone directory.
    """
    base_dir = base_dir or cfg.WORKTREE_DIR
    # Derive a directory name from the repo URL
    repo_name = repo_url.rstrip("/").split("/")[-1].removesuffix(".git")
    repo_path = os.path.join(base_dir, repo_name)

    if os.path.isdir(os.path.join(repo_path, ".git")):
        _run_git("fetch", "--all", "--prune", cwd=repo_path)
    else:
        os.makedirs(base_dir, exist_ok=True)
        _run_git("clone", repo_url, repo_path)

    return repo_path


def create_worktree(repo_path: str, branch_name: str, base_branch: str = "main") -> str:
    """Create a git worktree for the given branch.

    Returns the worktree directory path.
    """
    worktree_path = os.path.join(cfg.WORKTREE_DIR, f"wt-{branch_name.replace('/', '-')}")

    try:
        _run_git("worktree", "add", "-b", branch_name, worktree_path, f"origin/{base_branch}", cwd=repo_path)
    except RuntimeError:
        if os.path.isdir(worktree_path):
            return worktree_path
        raise
    return worktree_path


def commit_and_push(worktree_path: str, message: str, branch: str) -> None:
    """Stage all changes, commit, and push to remote."""
    _run_git("add", "-A", cwd=worktree_path)

    # Check if there are changes to commit
    status = _run_git("status", "--porcelain", cwd=worktree_path)
    if not status.stdout.strip():
        return  # nothing to commit

    _run_git("commit", "-m", message, cwd=worktree_path)
    _run_git("push", "-u", "origin", branch, cwd=worktree_path)


def cleanup_worktree(repo_path: str, worktree_path: str) -> None:
    """Remove a worktree and its directory."""
    wt = Path(worktree_path)
    if wt.exists():
        _run_git("worktree", "remove", str(wt), "--force", cwd=repo_path)
