# lib\git-ops.ps1 — Git worktree, commit, push operations

function Invoke-Git {
    param([string[]]$GitArgs, [string]$WorkDir = ".")
    $result = & git -C $WorkDir @GitArgs 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "git $($GitArgs -join ' ') failed (rc=$LASTEXITCODE): $result"
    }
    return $result.Trim()
}

function Initialize-Repo {
    <#
    .SYNOPSIS
        Get the repo path — use local repo if configured, otherwise clone.
    #>
    param(
        [string]$RepoUrl = $script:SarmaConfig.DefaultRepo
    )

    $localPath = $script:SarmaConfig.LocalRepo
    if ($localPath -and (Test-Path "$localPath\.git")) {
        Write-Host "    Using local repo: $localPath" -ForegroundColor DarkGray
        $null = Invoke-Git -GitArgs @("fetch", "--all", "--prune") -WorkDir $localPath
        return $localPath
    }

    # Clone if needed
    $wtDir = $script:SarmaConfig.WorktreeDir
    $repoName = ($RepoUrl -split "/")[-1] -replace "\.git$", ""
    $repoPath = Join-Path $wtDir $repoName

    if (Test-Path "$repoPath\.git") {
        $null = Invoke-Git -GitArgs @("fetch", "--all", "--prune") -WorkDir $repoPath
    } else {
        New-Item -ItemType Directory -Path $wtDir -Force | Out-Null
        $null = Invoke-Git -GitArgs @("clone", $RepoUrl, $repoPath)
    }
    return $repoPath
}

function New-Worktree {
    <#
    .SYNOPSIS
        Create a git worktree for a task branch.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$BranchName,
        [string]$BaseBranch = ""
    )

    if (-not $BaseBranch) { $BaseBranch = $script:SarmaConfig.DefaultBranch }

    $wtDir = $script:SarmaConfig.WorktreeDir
    # Ensure absolute path
    if (-not [System.IO.Path]::IsPathRooted($wtDir)) {
        $wtDir = Join-Path $PSScriptRoot ".." $wtDir
    }
    $wtDir = [System.IO.Path]::GetFullPath($wtDir)
    New-Item -ItemType Directory -Path $wtDir -Force | Out-Null

    $safeName = $BranchName -replace "/", "-"
    $wtPath = Join-Path $wtDir "wt-$safeName"

    if (Test-Path $wtPath) {
        return $wtPath
    }

    try {
        $null = Invoke-Git -GitArgs @("worktree", "add", "-b", $BranchName, $wtPath, "origin/$BaseBranch") -WorkDir $RepoPath
    } catch {
        if (Test-Path $wtPath) { return $wtPath }
        throw
    }
    return $wtPath
}

function Submit-Changes {
    <#
    .SYNOPSIS
        Stage all changes, commit, and push.
    #>
    param(
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][string]$Branch
    )

    Invoke-Git -GitArgs @("add", "-A") -WorkDir $WorktreePath

    $status = & git -C $WorktreePath status --porcelain 2>&1 | Out-String
    if (-not $status.Trim()) {
        Write-Host "    No changes to commit" -ForegroundColor Yellow
        return
    }

    Invoke-Git -GitArgs @("commit", "-m", $Message) -WorkDir $WorktreePath
    Invoke-Git -GitArgs @("push", "-u", "origin", $Branch) -WorkDir $WorktreePath
}

function Remove-Worktree {
    <#
    .SYNOPSIS
        Remove a git worktree.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$WorktreePath
    )

    if (Test-Path $WorktreePath) {
        try { Invoke-Git -GitArgs @("worktree", "remove", $WorktreePath, "--force") -WorkDir $RepoPath } catch {}
    }
}
