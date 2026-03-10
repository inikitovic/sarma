"""Centralized configuration loaded from environment variables."""

import os
import socket


class Config:
    """Sarma Launcher configuration backed by environment variables."""

    # Redis
    REDIS_HOST: str = os.getenv("REDIS_HOST", "localhost")
    REDIS_PORT: int = int(os.getenv("REDIS_PORT", "6380"))
    REDIS_PASSWORD: str = os.getenv("REDIS_PASSWORD", "")
    REDIS_SSL: bool = os.getenv("REDIS_SSL", "true").lower() in ("true", "1", "yes")
    # Auth mode: "entra" (Microsoft Entra ID / Managed Identity) or "key" (access key)
    REDIS_AUTH_MODE: str = os.getenv("REDIS_AUTH_MODE", "entra")

    # Azure DevOps defaults
    ADO_ORG: str = os.getenv("ADO_ORG", "msdata")
    ADO_PROJECT: str = os.getenv("ADO_PROJECT", "Database Systems")
    AZURE_DEVOPS_PAT: str = os.getenv("AZURE_DEVOPS_PAT", "")

    # Copilot CLI
    COPILOT_CLI_CMD: str = os.getenv("COPILOT_CLI_CMD", "copilot-cli")

    # Worker
    WORKER_ID: str = os.getenv("WORKER_ID", socket.gethostname())
    WORKER_CONCURRENCY: int = int(os.getenv("WORKER_CONCURRENCY", "1"))
    WORKER_POLL_TIMEOUT: int = int(os.getenv("WORKER_POLL_TIMEOUT", "5"))
    WORKER_TASK_TYPES: list[str] = os.getenv(
        "WORKER_TASK_TYPES", "backend,frontend,test,docs"
    ).split(",")

    # Paths
    LOG_DIR: str = os.getenv("LOG_DIR", "./logs")
    WORKTREE_DIR: str = os.getenv("WORKTREE_DIR", "./worktrees")

    # Executor timeout (seconds)
    EXECUTOR_TIMEOUT: int = int(os.getenv("EXECUTOR_TIMEOUT", "3600"))


cfg = Config()
