"""Pluggable executor interface for running agent CLI commands."""

from __future__ import annotations

import subprocess
import sys
from abc import ABC, abstractmethod
from dataclasses import dataclass

from sarma.config import cfg


@dataclass
class ExecutionResult:
    """Result of an executor invocation."""

    exit_code: int
    stdout: str
    stderr: str

    @property
    def success(self) -> bool:
        return self.exit_code == 0


class BaseExecutor(ABC):
    """Abstract base class for task executors."""

    @abstractmethod
    def run(self, prompt: str, workdir: str) -> ExecutionResult:
        ...


class CopilotExecutor(BaseExecutor):
    """Executes tasks via the Agency Copilot CLI subprocess."""

    def __init__(
        self,
        cli_cmd: str | None = None,
        timeout: int | None = None,
        live: bool = False,
    ):
        self.cli_cmd = cli_cmd or cfg.COPILOT_CLI_CMD
        self.timeout = timeout or cfg.EXECUTOR_TIMEOUT
        self.live = live

    def run(self, prompt: str, workdir: str) -> ExecutionResult:
        try:
            if self.live:
                # Stream output directly to terminal (interactive mode)
                proc = subprocess.run(
                    [self.cli_cmd, "--prompt", prompt],
                    cwd=workdir,
                    text=True,
                    timeout=self.timeout,
                )
                return ExecutionResult(
                    exit_code=proc.returncode,
                    stdout="(live output — see terminal)",
                    stderr="",
                )
            else:
                proc = subprocess.run(
                    [self.cli_cmd, "--prompt", prompt],
                    cwd=workdir,
                    capture_output=True,
                    text=True,
                    timeout=self.timeout,
                )
                return ExecutionResult(
                    exit_code=proc.returncode,
                    stdout=proc.stdout,
                    stderr=proc.stderr,
                )
        except subprocess.TimeoutExpired:
            return ExecutionResult(
                exit_code=-1,
                stdout="",
                stderr=f"Executor timed out after {self.timeout}s",
            )
        except FileNotFoundError:
            return ExecutionResult(
                exit_code=-2,
                stdout="",
                stderr=f"Executor command not found: {self.cli_cmd}",
            )
