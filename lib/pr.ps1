# lib\pr.ps1 — Azure DevOps pull request creation

function New-AzDevOpsPR {
    <#
    .SYNOPSIS
        Create a pull request in Azure DevOps.
    #>
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$SourceBranch,
        [string]$TargetBranch = "main",
        [string]$Title = "",
        [string]$Description = "",
        [string[]]$Reviewers = @(),
        [string]$Org = "",
        [string]$Project = ""
    )

    $Org = if ($Org) { $Org } else { $script:SarmaConfig.AdoOrg }
    $Project = if ($Project) { $Project } else { $script:SarmaConfig.AdoProject }

    # Ensure refs/ prefix
    if (-not $SourceBranch.StartsWith("refs/")) { $SourceBranch = "refs/heads/$SourceBranch" }
    if (-not $TargetBranch.StartsWith("refs/")) { $TargetBranch = "refs/heads/$TargetBranch" }

    $encodedProject = [uri]::EscapeDataString($Project)
    $url = "https://dev.azure.com/$Org/$encodedProject/_apis/git/repositories/$Repo/pullrequests?api-version=7.1"
    $headers = Get-SarmaAdoHeaders

    $body = @{
        sourceRefName = $SourceBranch
        targetRefName = $TargetBranch
        title         = $Title
        description   = $Description
    }

    if ($Reviewers.Count -gt 0) {
        $body.reviewers = $Reviewers | ForEach-Object { @{ uniqueName = $_ } }
    }

    $json = $body | ConvertTo-Json -Depth 5
    $resp = Invoke-RestMethod -Uri $url -Method Post -Headers $headers -Body $json
    return $resp
}
