# Sarma Launcher — Cheat Sheet

> Zero dependencies — just PowerShell + Git + Azure CLI.

## Setup (One-Time)

```powershell
git clone https://github.com/inikitovic/sarma.git
az login
$env:SARMA_STORAGE_ACCOUNT = "sarmastorage"
$env:AZURE_DEVOPS_PAT = "<pat>"
$env:SARMA_LOCAL_REPO = "Q:\src\DsMainDev"  # Dev Boxes only
```

## Master CLI

| Command | What it does |
|---------|-------------|
| `.\sarma.ps1 delegate 4946264` | Delegate ADO work item |
| `.\sarma.ps1 submit --prompt "..."` | Submit free-form task |
| `.\sarma.ps1 status` | List all tasks |
| `.\sarma.ps1 logs <task-id>` | View task details |
| `.\sarma.ps1 workers` | Show workers |
| `.\sarma.ps1 prune --completed` | Clean up |

## Worker (Dev Box)

```powershell
.\sarma-worker.ps1 --live                # see copilot output
.\sarma-worker.ps1 --types backend,test  # specialize
```

## Workflow

```
Delegate → Worker Executes → PR Created → You Review & Merge
```
