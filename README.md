# Sarma Launcher

Distributed task orchestrator that dispatches coding tasks across multiple Microsoft Dev Boxes, executes them via Agency Copilot CLI, and creates Azure DevOps pull requests — fully automated.

## Architecture

```
┌─────────────┐       ┌──────────────────┐       ┌──────────────────┐
│  Developer   │──────▶│   Azure Redis    │◀──────│  Dev Box Worker  │
│  Master CLI  │       │   Task Queue     │       │  (polls + runs)  │
└─────────────┘       └──────────────────┘       └──────┬───────────┘
                                                        │
                                            ┌───────────┴───────────┐
                                            │  Agency Copilot CLI   │
                                            │  (executes prompt)    │
                                            └───────────┬───────────┘
                                                        │
                                            ┌───────────┴───────────┐
                                            │  Azure DevOps         │
                                            │  (PR created)         │
                                            └───────────────────────┘
```

## Prerequisites

- Python 3.10+
- Git
- Azure CLI (for Dev Box provisioning)
- Agency Copilot CLI installed on each Dev Box
- Azure Cache for Redis instance

## Installation

```bash
cd D:\swarm
pip install -e ".[dev]"
```

## Configuration

Set these environment variables on each machine:

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `REDIS_HOST` | ✅ | `localhost` | Azure Redis hostname |
| `REDIS_PORT` | | `6380` | Redis port (6380 for Azure TLS) |
| `REDIS_PASSWORD` | ✅ | | Redis access key |
| `REDIS_SSL` | | `true` | Use TLS |
| `AZURE_DEVOPS_PAT` | ✅ | | ADO Personal Access Token |
| `ADO_ORG` | | `msdata` | Default ADO organization |
| `ADO_PROJECT` | | `Database Systems` | Default ADO project |
| `COPILOT_CLI_CMD` | | `copilot-cli` | Path to agent CLI |
| `WORKER_ID` | | hostname | Unique worker identifier |
| `WORKER_CONCURRENCY` | | `1` | Reserved for future use |
| `WORKER_TASK_TYPES` | | `backend,frontend,test,docs` | Task types this worker accepts |
| `LOG_DIR` | | `./logs` | Log output directory |
| `WORKTREE_DIR` | | `./worktrees` | Git worktree base directory |
| `EXECUTOR_TIMEOUT` | | `3600` | Max seconds per task |

## Quick Start

### 1. Submit a task

```bash
sarma submit \
  --repo https://dev.azure.com/msdata/DatabaseSystems/_git/MyRepo \
  --branch main \
  --type backend \
  --prompt "Implement OAuth login with JWT tokens" \
  --reviewer jdoe@microsoft.com
```

### 2. Start a worker (on a Dev Box)

```bash
sarma-worker --types backend,test
```

### 3. Monitor tasks

```bash
sarma status                    # all tasks
sarma status --filter running   # only running
sarma workers                   # registered workers
sarma logs <task-id>            # task details
```

### 4. Cleanup

```bash
sarma prune --completed --yes
```

## Task Types

| Type | Description |
|------|-------------|
| `backend` | Backend logic, APIs, services |
| `frontend` | UI components, pages |
| `test` | Test generation, test fixes |
| `docs` | Documentation, READMEs |

Workers can selectively consume specific types via `--types` or `WORKER_TASK_TYPES`.

## Running Tests

```bash
pip install -e ".[dev]"
pytest tests/ -v
```

## License

Internal — Microsoft use only.
