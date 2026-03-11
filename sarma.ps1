<#
.SYNOPSIS
    Sarma Launcher — distributed coding task orchestrator (Master CLI)
.DESCRIPTION
    Submit tasks, delegate work items, check status, view logs, and manage workers.
.EXAMPLE
    .\sarma.ps1 submit --prompt "Fix login bug"
    .\sarma.ps1 delegate 4946264 --type test
    .\sarma.ps1 status
    .\sarma.ps1 logs <task-id>
    .\sarma.ps1 workers
    .\sarma.ps1 prune --completed
#>

# Load all library modules
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\lib\config.ps1"
. "$scriptDir\lib\queue.ps1"
. "$scriptDir\lib\table.ps1"
. "$scriptDir\lib\pr.ps1"
. "$scriptDir\lib\ado-wit.ps1"
. "$scriptDir\lib\profile.ps1"

# ── Helpers ──────────────────────────────────────────────────────

function New-TaskId { return [guid]::NewGuid().ToString() }

function Save-Task {
    param([hashtable]$Task)
    Set-SarmaTableEntity -TableName "sarmatasks" -PartitionKey "task" -RowKey $Task.id -Properties $Task
}

function Show-Task {
    param($Task)
    Write-Host "Task:    $($Task.id)"
    Write-Host "Status:  $($Task.status)"
    Write-Host "Type:    $($Task.taskType)"
    Write-Host "Worker:  $(if ($Task.workerId) { $Task.workerId } else { '—' })"
    Write-Host "Branch:  $($Task.resultBranch)"
    Write-Host "Created: $($Task.createdAt)"
    Write-Host "Started: $(if ($Task.startedAt) { $Task.startedAt } else { '—' })"
    Write-Host "Done:    $(if ($Task.completedAt) { $Task.completedAt } else { '—' })"
    if ($Task.error) { Write-Host "Error:   $($Task.error)" -ForegroundColor Red }
    if ($Task.workItemId) { Write-Host "Work Item: #$($Task.workItemId)" }
    if ($Task.sessionId) {
        Write-Host "Session: $($Task.sessionId)" -ForegroundColor Cyan
        Write-Host "Resume:  copilot --resume=$($Task.sessionId)" -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host "Prompt:"
    Write-Host "  $($Task.prompt)" -ForegroundColor Cyan
}

# ── Commands ─────────────────────────────────────────────────────

function Invoke-Submit {
    param(
        [string]$Prompt,
        [string]$Repo,
        [string]$Branch = "",
        [string]$TaskType = "backend",
        [string[]]$Reviewer = @()
    )

    if (-not $Prompt) { Write-Host "Error: --prompt is required" -ForegroundColor Red; return }

    $id = New-TaskId
    $task = @{
        id            = $id
        repo          = if ($Repo) { $Repo } else { $script:SarmaConfig.DefaultRepo }
        branch        = if ($Branch) { $Branch } else { $script:SarmaConfig.DefaultBranch }
        taskType      = $TaskType
        prompt        = $Prompt
        status        = "pending"
        resultBranch  = "dev/$($script:SarmaConfig.UserAlias)/task/$($id.Substring(0,8))"
        commitMessage = "[sarma] ${TaskType}: $($Prompt.Substring(0, [Math]::Min(80, $Prompt.Length)))"
        prTitle       = "[sarma] ${TaskType}: $($Prompt.Substring(0, [Math]::Min(80, $Prompt.Length)))"
        prDescription = ""
        reviewers     = ($Reviewer -join ",")
        createdAt     = [datetime]::UtcNow.ToString("o")
        startedAt     = ""
        completedAt   = ""
        workerId      = ""
        error         = ""
        workItemId    = ""
    }

    Save-Task $task
    Write-Host "✅ Task submitted: $id" -ForegroundColor Green
    Write-Host "   Type: $TaskType | Branch: dev/$($script:SarmaConfig.UserAlias)/task/$($id.Substring(0,8))"
}

function Invoke-Delegate {
    param(
        [int]$WorkItemId,
        [string]$Repo,
        [string]$Branch = "",
        [string]$TaskType = "backend",
        [string[]]$Reviewer = @()
    )

    if (-not $WorkItemId) { Write-Host "Error: work item ID is required" -ForegroundColor Red; return }

    Write-Host "Fetching work item #$WorkItemId…"
    $wi = Get-SarmaWorkItem -Id $WorkItemId

    Write-Host "  Title: $($wi.Title)"
    Write-Host "  Type:  $($wi.Type) | State: $($wi.State)"

    $prompt = "Work Item #$WorkItemId`: $($wi.Title)`n`n$($wi.Description)"
    $id = New-TaskId

    $task = @{
        id            = $id
        repo          = if ($Repo) { $Repo } else { $script:SarmaConfig.DefaultRepo }
        branch        = if ($Branch) { $Branch } else { $script:SarmaConfig.DefaultBranch }
        taskType      = $TaskType
        prompt        = $prompt
        status        = "pending"
        resultBranch  = "dev/$($script:SarmaConfig.UserAlias)/task/$($id.Substring(0,8))"
        commitMessage = "[#$WorkItemId] $($wi.Title)"
        prTitle       = "[#$WorkItemId] $($wi.Title)"
        prDescription = "Auto-generated from work item #$WorkItemId`n`n$($wi.Description.Substring(0, [Math]::Min(500, $wi.Description.Length)))"
        reviewers     = ($Reviewer -join ",")
        createdAt     = [datetime]::UtcNow.ToString("o")
        startedAt     = ""
        completedAt   = ""
        workerId      = ""
        error         = ""
        workItemId    = "$WorkItemId"
    }

    Save-Task $task
    Write-Host "✅ Delegated: $id" -ForegroundColor Green
    Write-Host "   Branch: dev/$($script:SarmaConfig.UserAlias)/task/$($id.Substring(0,8))"
}

function Invoke-Revise {
    param(
        [int]$PrNumber,
        [switch]$JustMe,
        [string]$Repo
    )

    if (-not $PrNumber) { Write-Host "Error: PR number is required" -ForegroundColor Red; return }

    $id = New-TaskId
    $repoName = if ($Repo) { ($Repo -split "/")[-1] -replace "\.git$", "" } else { "DsMainDev" }
    $alias = $script:SarmaConfig.UserAlias

    # Build the revise prompt — copilot will use its ADO MCP to fetch PR details
    $commentFilter = if ($JustMe) {
        "Only address comments from $alias. Ignore all other reviewers' comments."
    } else {
        "Address ALL active/unresolved review comments from all reviewers."
    }

    $prompt = @"
You are revising code based on PR review feedback.

PULL REQUEST: #$PrNumber
Repository: $repoName
ADO Organization: $($script:SarmaConfig.AdoOrg)
ADO Project: $($script:SarmaConfig.AdoProject)

STEPS:
1. Use your Azure DevOps MCP tools to fetch PR #$PrNumber details and all review comment threads
2. Read and understand each active/unresolved comment
3. $commentFilter
4. Make the necessary code changes to address each comment
5. After all changes, commit with message: "Address PR #$PrNumber review comments"
6. Push the changes to the SAME branch (the PR will auto-update)
7. Reply to each resolved comment thread in the PR indicating what was done

Do NOT create a new PR. Push to the existing branch so the PR auto-updates.
Do NOT ask for confirmation. Complete the task autonomously.
"@

    $task = @{
        id            = $id
        repo          = if ($Repo) { $Repo } else { $script:SarmaConfig.DefaultRepo }
        branch        = ""  # worker will resolve from PR
        taskType      = "revise"
        prompt        = $prompt
        status        = "pending"
        resultBranch  = ""  # worker will resolve from PR
        commitMessage = "Address PR #$PrNumber review comments"
        prTitle       = ""
        prDescription = ""
        reviewers     = ""
        createdAt     = [datetime]::UtcNow.ToString("o")
        startedAt     = ""
        completedAt   = ""
        workerId      = ""
        error         = ""
        workItemId    = ""
        prNumber      = "$PrNumber"
        isRevise      = "true"
    }

    Save-Task $task
    Write-Host "✅ Revise task submitted: $id" -ForegroundColor Green
    Write-Host "   PR: #$PrNumber | Repo: $repoName$(if ($JustMe) { ' | Filter: just my comments' })"
}

function Invoke-Reserve {
    param(
        [int]$PrNumber,
        [string]$Repo
    )

    if (-not $PrNumber) { Write-Host "Error: PR number is required" -ForegroundColor Red; return }

    $id = New-TaskId
    $repoName = if ($Repo) { ($Repo -split "/")[-1] -replace "\.git$", "" } else { "DsMainDev" }
    $adoOrg = $script:SarmaConfig.AdoOrg
    $adoProject = $script:SarmaConfig.AdoProject

    $prompt = @"
RESERVE MODE — Manual debugging session for PR #$PrNumber

STEPS:
1. Use your Azure DevOps MCP tools to fetch PR #$PrNumber from org "$adoOrg" project "$adoProject" repo "$repoName"
2. Get the source branch name from the PR
3. Checkout that branch: git fetch --all && git checkout <source-branch>
4. Clean build artifacts by running these commands:
   rd /s /q obj QLocal debug retail testbin oacr_temp __cacheOutput \CloudBuildCache 2>nul
5. Open the SQL Server solution:
   slngen "%BaseDir%\Sql\Ntdbms\ksource\bin\sqlservr.vcxproj"

After completing all steps, the worker will keep this Dev Box RESERVED.
The developer will work manually. Do NOT make any code changes yourself.
"@

    $task = @{
        id            = $id
        repo          = if ($Repo) { $Repo } else { $script:SarmaConfig.DefaultRepo }
        branch        = ""
        taskType      = "reserve"
        prompt        = $prompt
        status        = "pending"
        resultBranch  = ""
        commitMessage = ""
        prTitle       = ""
        prDescription = ""
        reviewers     = ""
        createdAt     = [datetime]::UtcNow.ToString("o")
        startedAt     = ""
        completedAt   = ""
        workerId      = ""
        error         = ""
        workItemId    = ""
        prNumber      = "$PrNumber"
        isReserve     = "true"
    }

    Save-Task $task
    Write-Host "✅ Reserve task submitted: $id" -ForegroundColor Green
    Write-Host "   PR: #$PrNumber — a Dev Box will be reserved for manual work"
    Write-Host "   Run '.\sarma.ps1 status' to see which Dev Box picks it up"
    Write-Host "   Run '.\sarma-worker.ps1 release' on the Dev Box when done"
}

function Invoke-Review {
    param(
        [int]$PrNumber,
        [string]$Alias = "",
        [string]$Repo
    )

    if (-not $PrNumber) { Write-Host "Error: PR number is required" -ForegroundColor Red; return }

    $id = New-TaskId
    $repoName = if ($Repo) { ($Repo -split "/")[-1] -replace "\.git$", "" } else { "DsMainDev" }
    $adoOrg = $script:SarmaConfig.AdoOrg
    $adoProject = $script:SarmaConfig.AdoProject

    # Load reviewer profile if alias provided
    $personaContext = ""
    if ($Alias) {
        Write-Host "Loading review profile for $Alias..."
        $profile = Get-ReviewerProfile -Alias $Alias
        if ($profile -and $profile.profile) {
            $personaContext = @"

REVIEWER PERSONA:
You are reviewing this PR as $($profile.displayName) ($Alias). Match their review style exactly.

$($profile.profile)

Apply this reviewer's focus areas, comment style, and severity calibration to your review.
"@
            Write-Host "  ✅ Profile loaded ($($profile.commentCount) comments, $($profile.prCount) PRs)" -ForegroundColor Green
        } else {
            Write-Host "  ⚠ No profile found for $Alias. Run 'sarma profile $Alias' first." -ForegroundColor Yellow
            Write-Host "  Proceeding with generic review." -ForegroundColor Yellow
        }
    }

    $prompt = @"
You are performing a code review of PR #$PrNumber.

PULL REQUEST: #$PrNumber
Repository: $repoName
ADO Organization: $adoOrg
ADO Project: $adoProject
$personaContext
STEPS:
1. Use your Azure DevOps MCP tools to fetch PR #$PrNumber details from org "$adoOrg" project "$adoProject" repo "$repoName"
2. Get the PR diff — examine all changed files
3. Review every changed file thoroughly, checking for:
   - Bugs, logic errors, edge cases
   - Missing error handling or validation
   - Dead code or unused symbols
   - Logging and observability gaps
   - Test coverage gaps
   - API design issues
   - Documentation needs
   - Typos and formatting
4. For each issue found, create a review comment thread on the PR at the specific file and line
5. Use appropriate severity: mark blocking issues clearly, label nits as "nit:"
6. If no issues found, leave a general comment that the PR looks good

Do NOT make any code changes. This is a review-only task.
Do NOT ask for confirmation. Complete the review autonomously.
"@

    $task = @{
        id            = $id
        repo          = if ($Repo) { $Repo } else { $script:SarmaConfig.DefaultRepo }
        branch        = ""
        taskType      = "review"
        prompt        = $prompt
        status        = "pending"
        resultBranch  = ""
        commitMessage = ""
        prTitle       = ""
        prDescription = ""
        reviewers     = ""
        createdAt     = [datetime]::UtcNow.ToString("o")
        startedAt     = ""
        completedAt   = ""
        workerId      = ""
        error         = ""
        workItemId    = ""
        prNumber      = "$PrNumber"
        isReview      = "true"
        reviewAlias   = $Alias
    }

    Save-Task $task
    Write-Host "✅ Review task submitted: $id" -ForegroundColor Green
    Write-Host "   PR: #$PrNumber | Repo: $repoName$(if ($Alias) { " | Persona: $Alias" })"
}

function Invoke-Profile {
    param(
        [string]$Alias,
        [switch]$Refresh,
        [switch]$Show
    )

    if (-not $Alias) { Write-Host "Error: alias is required" -ForegroundColor Red; return }

    if ($Show) {
        $profile = Get-ReviewerProfile -Alias $Alias
        if ($profile -and $profile.profile) {
            Write-Host "Profile: $($profile.displayName) ($Alias)" -ForegroundColor Cyan
            Write-Host "Generated: $($profile.generatedAt) | PRs: $($profile.prCount) | Comments: $($profile.commentCount)"
            Write-Host ""
            Write-Host $profile.profile
        } else {
            Write-Host "No profile found for $Alias. Run 'sarma profile $Alias' to generate." -ForegroundColor Yellow
        }
        return
    }

    if (-not $Refresh) {
        $existing = Get-ReviewerProfile -Alias $Alias
        if ($existing -and $existing.profile) {
            Write-Host "Profile already exists for $Alias (generated $($existing.generatedAt))" -ForegroundColor Yellow
            Write-Host "Use --refresh to regenerate."
            return
        }
    }

    # Dispatch as a worker task — Copilot agent uses ADO MCP tools (no PAT needed)
    $id = New-TaskId
    $email = "$Alias@microsoft.com"
    $adoOrg = $script:SarmaConfig.AdoOrg
    $adoProject = $script:SarmaConfig.AdoProject
    $storageAccount = $script:SarmaConfig.StorageAccount

    $prompt = @"
You are building a reviewer style profile for $email.

ADO Organization: $adoOrg
ADO Project: $adoProject
Repository: DsMainDev

STEPS:
1. Use your Azure DevOps MCP tools to list COMPLETED pull requests in DsMainDev where "$email" was a reviewer. Fetch up to 100 PRs (page if needed).
2. For each PR, fetch comment threads authored by "$email" (use authorEmail filter).
3. Collect ONLY substantive code review comments — skip:
   - Vote messages (e.g. "voted 10", "voted -5")
   - System/bot messages
   - Comments without threadContext (non-code comments), UNLESS they contain actionable review text
4. Keep fetching PR threads until you have at least 100 code review comments, or you've exhausted all PRs.
5. Categorize each comment into one of these buckets:
   - "Dead code / unused symbols"
   - "Correctness / edge cases"
   - "Logging / observability"
   - "API design / abstractions"
   - "Test quality / coverage"
   - "Documentation / comments"
   - "Typos / formatting"
   - "Scoping / configuration"
   - "Other"
6. Generate a profile in this format:

   # Review Profile: <DisplayName> ($Alias)
   Generated from <N> code review comments across <M> PRs.

   ## Focus Areas (by frequency)
   <numbered list sorted by count>

   ## Representative Examples
   <for each non-empty category, show 2-3 best examples with [file] prefix>

   ## Comment Style
   - Short/terse (< 50 chars): X/N (%)
   - Detailed with context: X/N (%)
   - Questions probing intent: X/N (%)
   - Long/architectural (> 200 chars): X/N (%)

   ## Review Instructions
   When reviewing as <DisplayName>, you should:
   <5-7 bullet points capturing their review personality, focus areas, and style>

7. Save the profile to Azure Blob Storage by running this PowerShell command:
   `$json = @{ PartitionKey='profile'; RowKey='$Alias'; alias='$Alias'; displayName='<NAME>'; profile=`$profileText; prCount='<M>'; commentCount='<N>'; generatedAt=[datetime]::UtcNow.ToString('o') } | ConvertTo-Json -Depth 5; `$headers = @{ 'Authorization'='Bearer '+(az account get-access-token --resource https://storage.azure.com --query accessToken -o tsv); 'x-ms-version'='2023-11-03'; 'x-ms-date'=[datetime]::UtcNow.ToString('R'); 'Content-Type'='application/json'; 'x-ms-blob-type'='BlockBlob' }; Invoke-RestMethod -Uri 'https://$storageAccount.blob.core.windows.net/sarma/sarmaprofiles/profile/$Alias.json' -Method Put -Headers `$headers -Body `$json`

Do NOT ask for confirmation. Complete the task autonomously.
"@

    $task = @{
        id            = $id
        repo          = $script:SarmaConfig.DefaultRepo
        branch        = ""
        taskType      = "profile"
        prompt        = $prompt
        status        = "pending"
        resultBranch  = ""
        commitMessage = ""
        prTitle       = ""
        prDescription = ""
        reviewers     = ""
        createdAt     = [datetime]::UtcNow.ToString("o")
        startedAt     = ""
        completedAt   = ""
        workerId      = ""
        error         = ""
        workItemId    = ""
        profileAlias  = $Alias
    }

    Save-Task $task
    Write-Host "✅ Profile task submitted: $id" -ForegroundColor Green
    Write-Host "   Alias: $Alias — a worker will build the profile via Copilot MCP"
    Write-Host "   Run '.\sarma.ps1 profile $Alias --show' once complete"
}

function Invoke-Status {
    param([string]$Filter)

    $filterExpr = "PartitionKey eq 'task'"
    if ($Filter) { $filterExpr += " and status eq '$Filter'" }

    $tasks = Get-SarmaTableEntities -TableName "sarmatasks" -Filter $filterExpr
    if (-not $tasks -or $tasks.Count -eq 0) {
        Write-Host "No tasks found."
        return
    }

    Write-Host ("{0,-38} {1,-10} {2,-12} {3,-20} {4}" -f "ID", "TYPE", "STATUS", "WORKER", "BRANCH")
    Write-Host ("─" * 100)
    foreach ($t in $tasks) {
        $worker = if ($t.workerId) { $t.workerId } else { "—" }
        Write-Host ("{0,-38} {1,-10} {2,-12} {3,-20} {4}" -f $t.RowKey, $t.taskType, $t.status, $worker, $t.resultBranch)
    }
}

function Invoke-Logs {
    param([string]$TaskId)
    if (-not $TaskId) { Write-Host "Error: task ID is required" -ForegroundColor Red; return }

    $task = Get-SarmaTableEntity -TableName "sarmatasks" -PartitionKey "task" -RowKey $TaskId
    if (-not $task) { Write-Host "Task $TaskId not found." -ForegroundColor Red; return }
    Show-Task $task
}

function Invoke-Workers {
    $workers = Get-SarmaTableEntities -TableName "sarmaworkers" -Filter "PartitionKey eq 'worker'"
    if (-not $workers -or $workers.Count -eq 0) {
        Write-Host "No workers registered."
        return
    }

    Write-Host ("{0,-30} {1,-25} {2}" -f "WORKER ID", "LAST SEEN", "CURRENT TASK")
    Write-Host ("─" * 80)
    foreach ($w in $workers) {
        $taskId = if ($w.currentTaskId) { $w.currentTaskId.Substring(0, 8) + "…" } else { "—" }
        Write-Host ("{0,-30} {1,-25} {2}" -f $w.RowKey, $w.lastSeen, $taskId)
    }
}

function Invoke-Prune {
    param([switch]$Completed, [switch]$Failed, [switch]$All)

    $statuses = @()
    if ($Completed -or $All) { $statuses += "completed" }
    if ($Failed -or $All) { $statuses += "failed" }
    if ($All) { $statuses += "pending" }

    if ($statuses.Count -eq 0) {
        Write-Host "Specify --completed, --failed, or --all."
        return
    }

    $pruned = 0
    foreach ($s in $statuses) {
        $tasks = Get-SarmaTableEntities -TableName "sarmatasks" -Filter "PartitionKey eq 'task' and status eq '$s'"
        foreach ($t in $tasks) {
            Remove-SarmaTableEntity -TableName "sarmatasks" -PartitionKey "task" -RowKey $t.RowKey
            $pruned++
        }
    }
    Write-Host "🗑️  Pruned $pruned task(s)." -ForegroundColor Green
}

# ── Argument Parsing ─────────────────────────────────────────────

$command = $args[0]
$remaining = $args[1..($args.Count - 1)]

# Parse --key value pairs from remaining args
function Parse-Args {
    param([string[]]$ArgList)
    $parsed = @{}
    $positional = @()
    for ($i = 0; $i -lt $ArgList.Count; $i++) {
        $a = $ArgList[$i]
        if ($a -match "^--(.+)$") {
            $key = $Matches[1]
            if (($i + 1) -lt $ArgList.Count -and -not $ArgList[$i + 1].StartsWith("--")) {
                $parsed[$key] = $ArgList[$i + 1]
                $i++
            } else {
                $parsed[$key] = $true
            }
        } else {
            $positional += $a
        }
    }
    $parsed["_positional"] = $positional
    return $parsed
}

$p = Parse-Args $remaining

switch ($command) {
    "submit" {
        $reviewers = if ($p["reviewer"]) { @($p["reviewer"]) } else { @() }
        Invoke-Submit -Prompt $p["prompt"] -Repo $p["repo"] -Branch ($p["branch"] ?? "") -TaskType ($p["type"] ?? "backend") -Reviewer $reviewers
    }
    "delegate" {
        $wiId = if ($p["_positional"].Count -gt 0) { [int]$p["_positional"][0] } else { 0 }
        $reviewers = if ($p["reviewer"]) { @($p["reviewer"]) } else { @() }
        Invoke-Delegate -WorkItemId $wiId -Repo $p["repo"] -Branch ($p["branch"] ?? "") -TaskType ($p["type"] ?? "backend") -Reviewer $reviewers
    }
    "status" { Invoke-Status -Filter $p["filter"] }
    "logs"   { Invoke-Logs -TaskId ($p["_positional"][0]) }
    "workers" { Invoke-Workers }
    "prune"  { Invoke-Prune -Completed:($p["completed"] -eq $true) -Failed:($p["failed"] -eq $true) -All:($p["all"] -eq $true) }
    "revise" {
        $prNum = if ($p["_positional"].Count -gt 0) { [int]$p["_positional"][0] } else { 0 }
        Invoke-Revise -PrNumber $prNum -JustMe:($p["just-me"] -eq $true) -Repo $p["repo"]
    }
    "reserve" {
        $prNum = if ($p["_positional"].Count -gt 0) { [int]$p["_positional"][0] } else { 0 }
        Invoke-Reserve -PrNumber $prNum -Repo $p["repo"]
    }
    "review" {
        $prNum = if ($p["_positional"].Count -gt 0) { [int]$p["_positional"][0] } else { 0 }
        Invoke-Review -PrNumber $prNum -Alias ($p["alias"] ?? "") -Repo $p["repo"]
    }
    "profile" {
        $alias = if ($p["_positional"].Count -gt 0) { $p["_positional"][0] } else { "" }
        Invoke-Profile -Alias $alias -Refresh:($p["refresh"] -eq $true) -Show:($p["show"] -eq $true)
    }
    default {
        Write-Host "Sarma Launcher — distributed coding task orchestrator" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Usage: .\sarma.ps1 <command> [options]"
        Write-Host ""
        Write-Host "Commands:"
        Write-Host "  submit      Submit a task with a prompt"
        Write-Host "  delegate    Delegate an ADO work item to a worker"
        Write-Host "  revise      Address PR review comments"
        Write-Host "  review      Review a PR (optionally as a specific reviewer)"
        Write-Host "  reserve     Reserve a Dev Box for manual PR work"
        Write-Host "  profile     Build/show a reviewer's review style profile"
        Write-Host "  status      Show all tasks"
        Write-Host "  logs        Show task details"
        Write-Host "  workers     Show registered workers"
        Write-Host "  prune       Remove completed/failed tasks"
        Write-Host ""
        Write-Host "Examples:"
        Write-Host '  .\sarma.ps1 submit --prompt "Fix login bug"'
        Write-Host "  .\sarma.ps1 delegate 4946264 --type test"
        Write-Host "  .\sarma.ps1 revise 1993956"
        Write-Host "  .\sarma.ps1 revise 1993956 --just-me"
        Write-Host "  .\sarma.ps1 review 1993956"
        Write-Host "  .\sarma.ps1 review 1993956 --alias tisonjic"
        Write-Host "  .\sarma.ps1 profile tisonjic"
        Write-Host "  .\sarma.ps1 profile tisonjic --show"
        Write-Host "  .\sarma.ps1 profile tisonjic --refresh"
        Write-Host "  .\sarma.ps1 reserve 1993956"
        Write-Host "  .\sarma.ps1 status --filter running"
        Write-Host "  .\sarma.ps1 logs <task-id>"
    }
}


