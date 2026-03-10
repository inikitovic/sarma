<#
.SYNOPSIS
    Sarma Worker — polls the task queue and executes tasks.
.EXAMPLE
    .\sarma-worker.ps1
    .\sarma-worker.ps1 --types backend,test
    .\sarma-worker.ps1 --live
#>

# Load all library modules
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\lib\config.ps1"
. "$scriptDir\lib\queue.ps1"
. "$scriptDir\lib\table.ps1"
. "$scriptDir\lib\git-ops.ps1"
. "$scriptDir\lib\executor.ps1"
. "$scriptDir\lib\pr.ps1"

# ── Parse args ───────────────────────────────────────────────────

$liveMode = $false
$taskTypes = $script:SarmaConfig.WorkerTaskTypes

for ($i = 0; $i -lt $args.Count; $i++) {
    switch ($args[$i]) {
        "--live"  { $liveMode = $true }
        "--types" { $i++; $taskTypes = $args[$i] -split "," }
    }
}

$workerId = $script:SarmaConfig.WorkerId

# ── Worker Registration ─────────────────────────────────────────

function Register-Worker {
    Set-SarmaTableEntity -TableName "sarmaworkers" -PartitionKey "worker" -RowKey $workerId -Properties @{
        lastSeen      = [datetime]::UtcNow.ToString("o")
        taskTypes     = ($taskTypes -join ",")
        currentTaskId = ""
    }
}

function Update-Heartbeat {
    param([string]$CurrentTaskId = "")
    Set-SarmaTableEntity -TableName "sarmaworkers" -PartitionKey "worker" -RowKey $workerId -Properties @{
        lastSeen      = [datetime]::UtcNow.ToString("o")
        taskTypes     = ($taskTypes -join ",")
        currentTaskId = $CurrentTaskId
    }
}

function Unregister-Worker {
    try { Remove-SarmaTableEntity -TableName "sarmaworkers" -PartitionKey "worker" -RowKey $workerId } catch {}
}

# ── Task Processing ─────────────────────────────────────────────

function Update-TaskStatus {
    param(
        [string]$TaskId,
        [string]$Status,
        [hashtable]$ExtraFields = @{}
    )
    $props = @{ status = $Status } + $ExtraFields
    Set-SarmaTableEntity -TableName "sarmatasks" -PartitionKey "task" -RowKey $TaskId -Properties $props
}

function Process-Task {
    param($TaskId)

    $task = Get-SarmaTableEntity -TableName "sarmatasks" -PartitionKey "task" -RowKey $TaskId
    if (-not $task) {
        Write-Host "  Task $TaskId not found in table, skipping" -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "═══ Task $($TaskId.Substring(0,8)) [$($task.taskType)] ═══" -ForegroundColor Cyan
    Write-Host "  Prompt: $($task.prompt.Substring(0, [Math]::Min(120, $task.prompt.Length)))" -ForegroundColor White
    Write-Host "  Repo:   $($task.repo)" -ForegroundColor DarkGray
    Write-Host "  Branch: $($task.branch) → $($task.resultBranch)" -ForegroundColor DarkGray

    Update-TaskStatus -TaskId $TaskId -Status "running" -ExtraFields @{
        workerId  = $workerId
        startedAt = [datetime]::UtcNow.ToString("o")
    }
    Update-Heartbeat -CurrentTaskId $TaskId

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        # 1. Get repo
        Write-Host "  [1/5] Initializing repo…" -ForegroundColor DarkGray
        $repoPath = Initialize-Repo -RepoUrl $task.repo
        Write-Host "  [1/5] ✓ Repo ready" -ForegroundColor Green

        # 2. Create worktree
        Write-Host "  [2/5] Creating worktree $($task.resultBranch)…" -ForegroundColor DarkGray
        $wtPath = New-Worktree -RepoPath $repoPath -BranchName $task.resultBranch -BaseBranch $task.branch
        Write-Host "  [2/5] ✓ Worktree at $wtPath" -ForegroundColor Green

        try {
            # 3. Execute
            Write-Host "  [3/5] Running agent…" -ForegroundColor DarkGray
            $result = Invoke-CopilotAgent -Prompt $task.prompt -WorkDir $wtPath -Live:$liveMode
            $icon = if ($result.Success) { "✓" } else { "✗" }
            Write-Host "  [3/5] $icon Agent finished (rc=$($result.ExitCode))" -ForegroundColor $(if ($result.Success) { "Green" } else { "Red" })

            if (-not $result.Success) {
                throw "Agent failed (rc=$($result.ExitCode)): $($result.Stderr.Substring(0, [Math]::Min(500, $result.Stderr.Length)))"
            }

            # 4. Commit and push
            Write-Host "  [4/5] Committing and pushing…" -ForegroundColor DarkGray
            Submit-Changes -WorktreePath $wtPath -Message $task.commitMessage -Branch $task.resultBranch
            Write-Host "  [4/5] ✓ Pushed to $($task.resultBranch)" -ForegroundColor Green

            # 5. Create PR
            Write-Host "  [5/5] Creating PR…" -ForegroundColor DarkGray
            $repoName = ($task.repo -split "/")[-1] -replace "\.git$", ""
            $reviewers = if ($task.reviewers) { $task.reviewers -split "," | Where-Object { $_ } } else { @() }
            $pr = New-AzDevOpsPR -Repo $repoName -SourceBranch $task.resultBranch -TargetBranch $task.branch `
                -Title $task.prTitle -Description $task.prDescription -Reviewers $reviewers
            $prId = $pr.pullRequestId
            Write-Host "  [5/5] ✓ PR #$prId created" -ForegroundColor Green

            # Done
            $elapsed = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
            Update-TaskStatus -TaskId $TaskId -Status "completed" -ExtraFields @{
                completedAt = [datetime]::UtcNow.ToString("o")
            }
            Write-Host "═══ Task $($TaskId.Substring(0,8)) COMPLETED in ${elapsed}s ═══" -ForegroundColor Green
        } finally {
            Remove-Worktree -RepoPath $repoPath -WorktreePath $wtPath
        }

    } catch {
        $elapsed = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
        $errMsg = $_.Exception.Message
        if ($errMsg.Length -gt 500) { $errMsg = $errMsg.Substring(0, 500) }
        Update-TaskStatus -TaskId $TaskId -Status "failed" -ExtraFields @{
            completedAt = [datetime]::UtcNow.ToString("o")
            error       = $errMsg
        }
        Write-Host "═══ Task $($TaskId.Substring(0,8)) FAILED after ${elapsed}s: $errMsg ═══" -ForegroundColor Red
    }

    Update-Heartbeat
}

# ── Main Loop ────────────────────────────────────────────────────

Write-Host "Sarma Worker starting…" -ForegroundColor Cyan
Write-Host "  Worker ID: $workerId"
Write-Host "  Task types: $($taskTypes -join ', ')"
Write-Host "  Live mode: $liveMode"
Write-Host ""

Register-Worker
$running = $true

# Handle Ctrl+C gracefully
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    $script:running = $false
}

try {
    Write-Host "Polling for tasks…" -ForegroundColor DarkGray
    while ($running) {
        Update-Heartbeat

        $task = Receive-SarmaTask -TaskTypes $taskTypes
        if ($task) {
            Write-Host "Received task: $($task.RowKey.Substring(0,8))…" -ForegroundColor Yellow
            Process-Task -TaskId $task.RowKey
        } else {
            Start-Sleep -Seconds 3
        }
    }
} finally {
    Unregister-Worker
    Write-Host "Worker $workerId shut down." -ForegroundColor Yellow
}
