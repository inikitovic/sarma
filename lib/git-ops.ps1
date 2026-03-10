# lib\git-ops.ps1 — Git worktree, commit, push operations

function Invoke-Git {
    param([string[]]$Args, [string]$WorkDir = ".")
    $result = & git @Args 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Args -join ' ') failed (rc=$LASTEXITCODE): $result"
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
        Invoke-Git -Args @("fetch", "--all", "--prune") -WorkDir $localPath
        return $localPath
    }

    # Clone if needed
    $wtDir = $script:SarmaConfig.WorktreeDir
    $repoName = ($RepoUrl -split "/")[-1] -replace "\.git$", ""
    $repoPath = Join-Path $wtDir $repoName

    if (Test-Path "$repoPath\.git") {
        Invoke-Git -Args @("fetch", "--all", "--prune") -WorkDir $repoPath
    } else {
        New-Item -ItemType Directory -Path $wtDir -Force | Out-Null
        Invoke-Git -Args @("clone", $RepoUrl, $repoPath)
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
        [string]$BaseBranch = "main"
    )

    $wtDir = $script:SarmaConfig.WorktreeDir
    $safeName = $BranchName -replace "/", "-"
    $wtPath = Join-Path $wtDir "wt-$safeName"

    if (Test-Path $wtPath) {
        return $wtPath
    }

    try {
        Invoke-Git -Args @("worktree", "add", "-b", $BranchName, $wtPath, "origin/$BaseBranch") -WorkDir $RepoPath
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

    Invoke-Git -Args @("add", "-A") -WorkDir $WorktreePath

    # Check for changes
    $status = & git -C $WorktreePath status --porcelain 2>&1 | Out-String
    if (-not $status.Trim()) {
        Write-Host "    No changes to commit" -ForegroundColor Yellow
        return
    }

    Invoke-Git -Args @("commit", "-m", $Message) -WorkDir $WorktreePath
    Invoke-Git -Args @("push", "-u", "origin", $Branch) -WorkDir $WorktreePath
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
        try { Invoke-Git -Args @("worktree", "remove", $WorktreePath, "--force") -WorkDir $RepoPath } catch {}
    }
}
