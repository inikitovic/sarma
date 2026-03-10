# Sarma Launcher

Distributed task orchestrator that dispatches coding tasks across multiple Microsoft Dev Boxes, executes them via Agency Copilot CLI, and creates Azure DevOps pull requests — fully automated, zero dependencies.

## Architecture

```
┌─────────────┐       ┌──────────────────┐       ┌──────────────────┐
│  Developer   │──────▶│  Azure Storage   │◀──────│  Dev Box Worker  │
│  sarma.ps1   │       │  Queue + Table   │       │  sarma-worker    │
└─────────────┘       └──────────────────┘       └──────┬───────────┘
                                                        │
                                            ┌───────────┴───────────┐
                                            │  Agency Copilot CLI   │
                                            └───────────┬───────────┘
                                                        │
                                            ┌───────────┴───────────┐
                                            │  Azure DevOps PR      │
                                            └───────────────────────┘
```

## Prerequisites

- PowerShell 5.1+ (pre-installed on Windows)
- Git
- Azure CLI (`az login`)
- Agency Copilot CLI on each Dev Box

**No pip, no conda, no packages to install.**

## Setup

```powershell
git clone https://github.com/inikitovic/sarma.git
az login
$env:SARMA_STORAGE_ACCOUNT = "sarmastorage"
$env:SARMA_LOCAL_REPO = "Q:\src\DsMainDev"    # Dev Boxes only
$env:AZURE_DEVOPS_PAT = "<your-pat>"
```

## Usage

```powershell
.\sarma.ps1 delegate 4946264 --type test          # delegate work item
.\sarma.ps1 submit --prompt "Fix the login bug"   # or free-form prompt
.\sarma.ps1 status                                 # check all tasks
.\sarma.ps1 logs <task-id>                         # task details
.\sarma.ps1 workers                                # registered workers
.\sarma-worker.ps1 --live                          # start worker on Dev Box
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `SARMA_STORAGE_ACCOUNT` | `sarmastorage` | Azure Storage Account name |
| `SARMA_LOCAL_REPO` | | Local repo path (skips cloning) |
| `AZURE_DEVOPS_PAT` | | ADO PAT for PRs and work items |
| `ADO_ORG` | `msdata` | ADO organization |
| `ADO_PROJECT` | `Database Systems` | ADO project for PRs |
| `COPILOT_CLI_CMD` | `copilot-cli` | Agent CLI command |
| `WORKER_TASK_TYPES` | `backend,frontend,test,docs` | Task types for this worker |
