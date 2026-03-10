"""Tests for sarma.worker.executor (subprocess is mocked)."""

from unittest.mock import patch, MagicMock
import subprocess

from sarma.worker.executor import CopilotExecutor, ExecutionResult


@patch("sarma.worker.executor.subprocess.run")
def test_executor_success(mock_run):
    mock_run.return_value = MagicMock(returncode=0, stdout="Done!", stderr="")
    executor = CopilotExecutor(cli_cmd="fake-cli", timeout=60)
    result = executor.run("do something", "/tmp/work")
    assert result.success
    assert result.stdout == "Done!"
    mock_run.assert_called_once_with(
        ["fake-cli", "--prompt", "do something"],
        cwd="/tmp/work",
        capture_output=True,
        text=True,
        timeout=60,
    )


@patch("sarma.worker.executor.subprocess.run")
def test_executor_failure(mock_run):
    mock_run.return_value = MagicMock(returncode=1, stdout="", stderr="Error occurred")
    executor = CopilotExecutor(cli_cmd="fake-cli", timeout=60)
    result = executor.run("fail task", "/tmp/work")
    assert not result.success
    assert result.exit_code == 1
    assert "Error" in result.stderr


@patch("sarma.worker.executor.subprocess.run", side_effect=subprocess.TimeoutExpired("cmd", 60))
def test_executor_timeout(mock_run):
    executor = CopilotExecutor(cli_cmd="fake-cli", timeout=60)
    result = executor.run("slow task", "/tmp/work")
    assert not result.success
    assert result.exit_code == -1
    assert "timed out" in result.stderr


@patch("sarma.worker.executor.subprocess.run", side_effect=FileNotFoundError)
def test_executor_not_found(mock_run):
    executor = CopilotExecutor(cli_cmd="nonexistent-cli", timeout=60)
    result = executor.run("task", "/tmp/work")
    assert not result.success
    assert result.exit_code == -2
    assert "not found" in result.stderr
