"""Tests for sarma.worker.git_ops (subprocess calls are mocked)."""

import os
from unittest.mock import patch, MagicMock
import subprocess

from sarma.worker.git_ops import clone_or_fetch, commit_and_push


@patch("sarma.worker.git_ops.subprocess.run")
@patch("sarma.worker.git_ops.os.path.isdir", return_value=False)
@patch("sarma.worker.git_ops.os.makedirs")
def test_clone_new_repo(mock_makedirs, mock_isdir, mock_run):
    mock_run.return_value = MagicMock(returncode=0, stdout="", stderr="")
    path = clone_or_fetch("https://example.com/repo.git", base_dir="/tmp/wt")
    assert os.path.normpath(path) == os.path.normpath("/tmp/wt/repo")
    mock_run.assert_called_once()
    args = mock_run.call_args[0][0]
    assert "clone" in args


@patch("sarma.worker.git_ops.subprocess.run")
@patch("sarma.worker.git_ops.os.path.isdir", return_value=True)
def test_fetch_existing_repo(mock_isdir, mock_run):
    mock_run.return_value = MagicMock(returncode=0, stdout="", stderr="")
    path = clone_or_fetch("https://example.com/repo.git", base_dir="/tmp/wt")
    assert os.path.normpath(path) == os.path.normpath("/tmp/wt/repo")
    args = mock_run.call_args[0][0]
    assert "fetch" in args


@patch("sarma.worker.git_ops.subprocess.run")
def test_commit_and_push_with_changes(mock_run):
    # First call: git add -A (success)
    # Second call: git status --porcelain (has changes)
    # Third call: git commit
    # Fourth call: git push
    mock_run.side_effect = [
        MagicMock(returncode=0, stdout="", stderr=""),       # add
        MagicMock(returncode=0, stdout="M file.py\n", stderr=""),  # status
        MagicMock(returncode=0, stdout="", stderr=""),       # commit
        MagicMock(returncode=0, stdout="", stderr=""),       # push
    ]
    commit_and_push("/tmp/wt/repo", "test commit", "task/abc")
    assert mock_run.call_count == 4


@patch("sarma.worker.git_ops.subprocess.run")
def test_commit_and_push_no_changes(mock_run):
    mock_run.side_effect = [
        MagicMock(returncode=0, stdout="", stderr=""),  # add
        MagicMock(returncode=0, stdout="", stderr=""),  # status (empty = no changes)
    ]
    commit_and_push("/tmp/wt/repo", "test commit", "task/abc")
    assert mock_run.call_count == 2  # no commit or push
