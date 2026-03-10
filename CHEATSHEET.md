# 🐝 Sarma Launcher — Cheat Sheet

> One-page reference for developers using the distributed agent sarma.

---

## 🔧 Dev Box Setup (One-Time)

```bash
# 1. Install Python + Sarma
pip install -e ".[dev]"

# 2. Set environment variables
export REDIS_HOST=<your-redis-host>
export REDIS_PORT=6380
export REDIS_PASSWORD=<access-key>
export AZURE_DEVOPS_PAT=<your-pat>
export COPILOT_CLI_CMD=copilot-cli
```

---

## 🚀 Master CLI Commands

| Command | What it does |
|---------|-------------|
| `sarma submit --repo <url> --prompt "..."` | Submit a task to the queue |
| `sarma status` | List all tasks with status |
| `sarma status --filter running` | Show only running tasks |
| `sarma workers` | Show registered Dev Box workers |
| `sarma logs <task-id>` | View task details and errors |
| `sarma prune --completed --yes` | Clean up finished tasks |

### Submit Examples

```bash
# Simple
sarma submit --repo https://dev.azure.com/msdata/DB/_git/Repo \
  --prompt "Add input validation to the signup form"

# With options
sarma submit --repo https://dev.azure.com/msdata/DB/_git/Repo \
  --branch develop \
  --type frontend \
  --prompt "Refactor dashboard component to use React hooks" \
  --reviewer alice@microsoft.com \
  --reviewer bob@microsoft.com
```

---

## 👷 Worker Startup (On Each Dev Box)

```bash
# Accept all task types
sarma-worker

# Only backend + test tasks
sarma-worker --types backend,test
```

---

## 📋 Developer Workflow

```
 ┌──────────┐     ┌───────────┐     ┌───────────┐     ┌──────────┐
 │  Submit   │────▶│  Workers  │────▶│ PR Created│────▶│  Review  │
 │  Task     │     │  Execute  │     │ in ADO    │     │ & Merge  │
 └──────────┘     └───────────┘     └───────────┘     └──────────┘
     You            Automated         Automated          You
```

1. **Submit** — `sarma submit --prompt "..."`
2. **Wait** — Workers pick it up automatically
3. **Monitor** (optional) — `sarma status`
4. **Review** — PR appears in Azure DevOps
5. **Merge** — Standard code review workflow

---

## 🔍 Troubleshooting

| Problem | Fix |
|---------|-----|
| Task stuck in `pending` | Check workers are running: `sarma workers` |
| Worker not connecting | Verify `REDIS_HOST` and firewall rules |
| PR creation fails | Check `AZURE_DEVOPS_PAT` has Code (Read & Write) scope |
| Executor timeout | Increase `EXECUTOR_TIMEOUT` env var (default: 3600s) |
| Task failed | Check error: `sarma logs <task-id>` |

---

## 📂 Task Types

| `--type` | Routes to workers accepting | Use for |
|----------|---------------------------|---------|
| `backend` | backend logic | APIs, services, data |
| `frontend` | UI work | Components, pages |
| `test` | testing | Test generation |
| `docs` | documentation | READMEs, guides |

---

*Sarma Launcher v0.1.0 — Internal use only*
