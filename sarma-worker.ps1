<#
.SYNOPSIS
    Sarma Worker — polls the task queue and executes tasks.
.EXAMPLE
    .\sarma-worker.ps1
    .\sarma-worker.ps1 --types backend,test
    .\sarma-worker.ps1 --verbose
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
$script:Verbose = $false
$script:ReleaseMode = $false

for ($i = 0; $i -lt $args.Count; $i++) {
    switch ($args[$i]) {
        "--types"   { $i++; $taskTypes = $args[$i] -split "," }
        "--verbose" { $script:Verbose = $true }
        "-v"        { $script:Verbose = $true }
        "release"   { $script:ReleaseMode = $true }
    }
}

$workerId = $script:SarmaConfig.WorkerId

# ── Logging helpers ──────────────────────────────────────────────

function Log-Info {
    param([string]$Message, [string]$Color = "White")
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts] $Message" -ForegroundColor $Color
}

function Log-Verbose {
    param([string]$Message)
    if ($script:Verbose) {
        $ts = Get-Date -Format "HH:mm:ss"
        Write-Host "[$ts] [DBG] $Message" -ForegroundColor DarkGray
    }
}

function Log-Step {
    param([string]$Step, [string]$Message, [string]$Color = "DarkGray")
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts]   $Step $Message" -ForegroundColor $Color
}

# ── Worker Registration ─────────────────────────────────────────

function Register-Worker {
    Log-Verbose "Registering worker '$workerId' in sarmaworkers table…"
    Set-SarmaTableEntity -TableName "sarmaworkers" -PartitionKey "worker" -RowKey $workerId -Properties @{
        lastSeen      = [datetime]::UtcNow.ToString("o")
        taskTypes     = ($taskTypes -join ",")
        currentTaskId = ""
    }
    Log-Verbose "Worker registered."
}

function Update-Heartbeat {
    param([string]$CurrentTaskId = "")
    Log-Verbose "Heartbeat sent (task: $(if ($CurrentTaskId) { $CurrentTaskId.Substring(0,8) } else { 'none' }))"
    Set-SarmaTableEntity -TableName "sarmaworkers" -PartitionKey "worker" -RowKey $workerId -Properties @{
        lastSeen      = [datetime]::UtcNow.ToString("o")
        taskTypes     = ($taskTypes -join ",")
        currentTaskId = $CurrentTaskId
    }
}

function Unregister-Worker {
    Log-Verbose "Unregistering worker…"
    try { Remove-SarmaTableEntity -TableName "sarmaworkers" -PartitionKey "worker" -RowKey $workerId } catch {}
}

# ── Task Processing ─────────────────────────────────────────────

function Update-TaskStatus {
    param(
        [string]$TaskId,
        [string]$Status,
        [hashtable]$ExtraFields = @{}
    )
    Log-Verbose "Updating task $($TaskId.Substring(0,8)) → status=$Status $(if ($ExtraFields.Count) { $ExtraFields.Keys -join ',' })"
    $props = @{ status = $Status }
    foreach ($k in $ExtraFields.Keys) {
        $props[$k] = $ExtraFields[$k]
    }
    Set-SarmaTableEntity -TableName "sarmatasks" -PartitionKey "task" -RowKey $TaskId -Properties $props
}

function Process-Task {
    param($TaskId)

    Log-Verbose "Fetching task $TaskId from blob storage…"
    $task = Get-SarmaTableEntity -TableName "sarmatasks" -PartitionKey "task" -RowKey $TaskId
    if (-not $task) {
        Log-Info "Task $TaskId not found in storage, skipping" Yellow
        return
    }

    Write-Host ""
    Log-Info "═══ Task $($TaskId.Substring(0,8)) [$($task.taskType)] ═══" Cyan
    Log-Info "  Prompt: $($task.prompt.Substring(0, [Math]::Min(120, $task.prompt.Length)))" White
    Log-Verbose "  Repo:       $($task.repo)"
    Log-Verbose "  Branch:     $($task.branch) → $($task.resultBranch)"
    Log-Verbose "  Commit msg: $($task.commitMessage)"
    Log-Verbose "  PR title:   $($task.prTitle)"
    Log-Verbose "  Reviewers:  $(if ($task.reviewers) { $task.reviewers } else { '(none)' })"
    Log-Verbose "  Work item:  $(if ($task.workItemId) { '#' + $task.workItemId } else { '(none)' })"

    Update-TaskStatus -TaskId $TaskId -Status "running" -ExtraFields @{
        workerId  = $workerId
        startedAt = [datetime]::UtcNow.ToString("o")
    }
    Update-Heartbeat -CurrentTaskId $TaskId

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $isRevise = ($task.isRevise -eq "true")
        $isReserve = ($task.isReserve -eq "true")
        $isReview = ($task.isReview -eq "true")
        $isProfile = ($task.taskType -eq "profile")

        if ($isProfile) {
            # Profile tasks are pure ADO data fetching — no git ops needed
            # But Copilot still needs a repo working directory to boot (init.ps1, MCP servers)
            $localPath = $script:SarmaConfig.LocalRepo
            if ($localPath -and (Test-Path "$localPath\.git")) {
                $wtPath = $localPath
            } else {
                $wtPath = (Get-Location).Path
            }
            Log-Step "[1/1]" "✓ Profile task — using $wtPath (no git ops)" Green
        } else {
            # 1. Initialize repo (use local if available, otherwise clone)
            Log-Step "[1/3]" "Initializing repo…"
            Log-Verbose "  Local repo config: '$($script:SarmaConfig.LocalRepo)'"
            $repoPath = Initialize-Repo -RepoUrl $task.repo
            Log-Step "[1/3]" "✓ Repo ready at $repoPath" Green

            # 2. Checkout branch
            if ($isRevise -or $isReserve -or $isReview) {
                # Revise/Reserve/Review: copilot will checkout the PR branch via MCP
                Log-Step "[2/3]" "Preparing for PR #$($task.prNumber)…"
                $null = Invoke-Git -GitArgs @("fetch", "--all") -WorkDir $repoPath
                $null = Invoke-Git -GitArgs @("checkout", $script:SarmaConfig.DefaultBranch) -WorkDir $repoPath
                $wtPath = $repoPath
                Log-Step "[2/3]" "✓ On $($script:SarmaConfig.DefaultBranch) (agent will handle PR)" Green
            } else {
                # Normal task: create new branch
                Log-Step "[2/3]" "Creating branch $($task.resultBranch)…"
                Log-Verbose "  Base branch: $($task.branch)"
                $wtPath = New-Worktree -RepoPath $repoPath -BranchName $task.resultBranch -BaseBranch $task.branch
                Log-Step "[2/3]" "✓ Checked out $($task.resultBranch) at $wtPath" Green
            }
        }

        # 3. Craft prompt and launch agent
        $reviewers = if ($task.reviewers) { $task.reviewers } else { "" }
        $adoOrg = if ($task.adoOrg) { $task.adoOrg } else { $script:SarmaConfig.AdoOrg }
        $adoProject = if ($task.adoProject) { $task.adoProject } else { $script:SarmaConfig.AdoProject }
        $repoName = ($task.repo -split "/")[-1] -replace "\.git$", ""

        if ($isRevise -or $isReserve -or $isReview -or $isProfile) {
            # Revise/Reserve/Review/Profile: prompt already has all instructions
            $fullPrompt = $task.prompt
        } else {
            # Normal task: add branch/commit/PR instructions
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
        }

        Log-Step "[3/3]" "Launching agent (ConPTY)…"
        Log-Verbose "  Working dir: $wtPath"
        Log-Verbose "  Prompt length: $($fullPrompt.Length) chars"
        Log-Verbose "  ADO target: $adoOrg / $adoProject / $repoName"

        $keepAlive = ($isRevise -or $isReserve)
        $skipInit = ($isProfile -or $isReview)
        $result = Invoke-CopilotAgent -Prompt $fullPrompt -WorkDir $wtPath -KeepAlive:$keepAlive -SkipInit:$skipInit

        $icon = if ($result.Success) { "✓" } else { "✗" }
        Log-Step "[3/3]" "$icon Agent finished (rc=$($result.ExitCode))" $(if ($result.Success) { "Green" } else { "Red" })
        Log-Verbose "  Duration: $($result.Stdout)"
        Log-Verbose "  Session ID: $(if ($result.SessionId) { $result.SessionId } else { '(not captured)' })"

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

        $elapsed = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 1)

        if ($isReserve) {
            # RESERVE MODE — block this worker until released
            Update-TaskStatus -TaskId $TaskId -Status "reserved" -ExtraFields $sessionFields
            Log-Info "═══ Dev Box RESERVED for PR #$($task.prNumber) (${elapsed}s setup) ═══" Cyan
            Log-Info "  Worker $workerId is now blocked for manual work." Cyan
            Log-Info "  Run '.\sarma-worker.ps1 release' when done." Cyan

            # Update worker status to reserved
            Set-SarmaTableEntity -TableName "sarmaworkers" -PartitionKey "worker" -RowKey $workerId -Properties @{
                lastSeen      = [datetime]::UtcNow.ToString("o")
                taskTypes     = ($taskTypes -join ",")
                currentTaskId = $TaskId
                reserved      = "true"
                reservedPR    = $task.prNumber
            }

            # Block — wait for release file
            $releaseFile = Join-Path $repoPath ".sarma-release"
            Log-Info "  Waiting for release (polling .sarma-release or run sarma-worker.ps1 release)…" DarkGray
            while (-not (Test-Path $releaseFile)) {
                Start-Sleep 5
            }
            Remove-Item $releaseFile -Force -ErrorAction SilentlyContinue
            Log-Info "═══ Dev Box RELEASED ═══" Green

            # Unblock worker
            Set-SarmaTableEntity -TableName "sarmaworkers" -PartitionKey "worker" -RowKey $workerId -Properties @{
                lastSeen      = [datetime]::UtcNow.ToString("o")
                taskTypes     = ($taskTypes -join ",")
                currentTaskId = ""
                reserved      = ""
                reservedPR    = ""
            }
            Update-TaskStatus -TaskId $TaskId -Status "completed" -ExtraFields @{
                completedAt = [datetime]::UtcNow.ToString("o")
            }
        } else {
            # Normal completion
            Update-TaskStatus -TaskId $TaskId -Status "completed" -ExtraFields $sessionFields
            Log-Info "═══ Task $($TaskId.Substring(0,8)) COMPLETED in ${elapsed}s ═══" Green
        }

    } catch {
        $elapsed = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
        $errMsg = $_.Exception.Message
        if ($errMsg.Length -gt 500) { $errMsg = $errMsg.Substring(0, 500) }
        Log-Verbose "  Exception: $($_.Exception.GetType().Name)"
        Log-Verbose "  Stack: $($_.ScriptStackTrace)"
        $failFields = @{
            completedAt = [datetime]::UtcNow.ToString("o")
            error       = $errMsg
        }
        if ($result -and $result.SessionId) {
            $failFields.sessionId = $result.SessionId
        }
        Update-TaskStatus -TaskId $TaskId -Status "failed" -ExtraFields $failFields
        Log-Info "═══ Task $($TaskId.Substring(0,8)) FAILED after ${elapsed}s: $errMsg ═══" Red
    }

    Update-Heartbeat
}

# ── Release Handler ──────────────────────────────────────────────

if ($script:ReleaseMode) {
    $repoPath = $script:SarmaConfig.LocalRepo
    if (-not $repoPath) { $repoPath = "." }
    $releaseFile = Join-Path $repoPath ".sarma-release"
    "released" | Set-Content $releaseFile -Encoding UTF8
    Write-Host "✅ Dev Box released. Worker will resume polling." -ForegroundColor Green
    exit 0
}

# ── Main Loop ────────────────────────────────────────────────────

Write-Host ""
Log-Info "Sarma Worker starting…" Cyan
Log-Info "  Worker ID:  $workerId"
Log-Info "  Task types: $($taskTypes -join ', ')"
Log-Info "  Verbose:    $($script:Verbose)"
Log-Info "  Storage:    $($script:SarmaConfig.StorageAccount)"
Log-Info "  Local repo: $(if ($script:SarmaConfig.LocalRepo) { $script:SarmaConfig.LocalRepo } else { '(none — will clone)' })"
Log-Info "  Default branch: $($script:SarmaConfig.DefaultBranch)"
Write-Host ""

Register-Worker
$running = $true

# Handle Ctrl+C gracefully
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    $script:running = $false
}

try {
    Log-Info "Polling for tasks…" DarkGray
    while ($running) {
        Update-Heartbeat

        Log-Verbose "Polling queues: $($taskTypes -join ', ')…"
        $task = Receive-SarmaTask -TaskTypes $taskTypes
        if ($task) {
            Log-Info "Received task: $($task.RowKey.Substring(0,8))… (type: $($task.taskType))" Yellow
            Process-Task -TaskId $task.RowKey
            Log-Info "Ready for next task." DarkGray
        } else {
            Log-Verbose "No tasks — sleeping 3s…"
            Start-Sleep -Seconds 3
        }
    }
} finally {
    Unregister-Worker
    Log-Info "Worker $workerId shut down." Yellow
}
