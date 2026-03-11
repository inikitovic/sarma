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

$taskTypes = $script:SarmaConfig.WorkerTaskTypes

for ($i = 0; $i -lt $args.Count; $i++) {
    switch ($args[$i]) {
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
        Write-Host "  [1/3] Initializing repo…" -ForegroundColor DarkGray
        $repoPath = Initialize-Repo -RepoUrl $task.repo
        Write-Host "  [1/3] ✓ Repo ready" -ForegroundColor Green

        # 2. Create worktree
        Write-Host "  [2/3] Creating worktree $($task.resultBranch)…" -ForegroundColor DarkGray
        $wtPath = New-Worktree -RepoPath $repoPath -BranchName $task.resultBranch -BaseBranch $task.branch
        Write-Host "  [2/3] ✓ Worktree at $wtPath" -ForegroundColor Green

        # 3. Craft prompt and launch agent
        #    The agent handles everything: code changes, commit, push, and PR
        $reviewers = if ($task.reviewers) { $task.reviewers } else { "" }
        $adoOrg = if ($task.adoOrg) { $task.adoOrg } else { $script:SarmaConfig.AdoOrg }
        $adoProject = if ($task.adoProject) { $task.adoProject } else { $script:SarmaConfig.AdoProject }
        $repoName = ($task.repo -split "/")[-1] -replace "\.git$", ""

        $fullPrompt = @"
$($task.prompt)

== INSTRUCTIONS ==
You are on branch "$($task.resultBranch)" in the $repoName repository.

When you are done with all code changes:
1. Stage and commit all changes: git add -A && git commit -m "$($task.commitMessage)"
2. Push the branch: git push -u origin $($task.resultBranch)
3. Create a pull request in Azure DevOps:
   - Organization: $adoOrg
   - Project: $adoProject
   - Repository: $repoName
   - Source branch: $($task.resultBranch)
   - Target branch: $($task.branch)
   - Title: $($task.prTitle)
$(if ($reviewers) { "   - Reviewers: $reviewers" })

Do NOT ask for confirmation. Complete the task autonomously.
"@

        Write-Host "  [3/3] Launching agent…" -ForegroundColor DarkGray
        $result = Invoke-CopilotAgent -Prompt $fullPrompt -WorkDir $wtPath
        $icon = if ($result.Success) { "✓" } else { "✗" }
        Write-Host "  [3/3] $icon Agent finished (rc=$($result.ExitCode))" -ForegroundColor $(if ($result.Success) { "Green" } else { "Red" })

        # Store session ID for resume capability
        $sessionFields = @{
            completedAt = [datetime]::UtcNow.ToString("o")
        }
        if ($result.SessionId) {
            $sessionFields.sessionId = $result.SessionId
        }

        if (-not $result.Success) {
            throw "Agent failed (rc=$($result.ExitCode)): $($result.Stderr)"
        }

        # Done — agent handled commit + push + PR
        $elapsed = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
        $sessionFields.status = "completed"
        Update-TaskStatus -TaskId $TaskId -Status "completed" -ExtraFields $sessionFields
        Write-Host "═══ Task $($TaskId.Substring(0,8)) COMPLETED in ${elapsed}s ═══" -ForegroundColor Green

    } catch {
        $elapsed = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
        $errMsg = $_.Exception.Message
        if ($errMsg.Length -gt 500) { $errMsg = $errMsg.Substring(0, 500) }
        $failFields = @{
            completedAt = [datetime]::UtcNow.ToString("o")
            error       = $errMsg
        }
        if ($result -and $result.SessionId) {
            $failFields.sessionId = $result.SessionId
        }
        Update-TaskStatus -TaskId $TaskId -Status "failed" -ExtraFields $failFields
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
