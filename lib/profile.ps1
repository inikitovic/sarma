# lib/profile.ps1 — Reviewer profile generation and storage

function Get-ReviewerProfile {
    <#
    .SYNOPSIS
        Load a reviewer profile from blob storage.
    #>
    param([Parameter(Mandatory)][string]$Alias)
    return Get-SarmaTableEntity -TableName "sarmaprofiles" -PartitionKey "profile" -RowKey $Alias
}

function Save-ReviewerProfile {
    <#
    .SYNOPSIS
        Save a reviewer profile to blob storage.
    #>
    param(
        [Parameter(Mandatory)][string]$Alias,
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$ProfileText,
        [int]$PrCount = 0,
        [int]$CommentCount = 0
    )
    Set-SarmaTableEntity -TableName "sarmaprofiles" -PartitionKey "profile" -RowKey $Alias -Properties @{
        alias        = $Alias
        displayName  = $DisplayName
        profile      = $ProfileText
        prCount      = "$PrCount"
        commentCount = "$CommentCount"
        generatedAt  = [datetime]::UtcNow.ToString("o")
    }
}

function Build-ReviewerProfile {
    <#
    .SYNOPSIS
        Fetch a reviewer's PR comments and generate a review style profile.
        Uses ADO REST API directly (no MCP dependency — runs from master CLI).
    #>
    param(
        [Parameter(Mandatory)][string]$Alias,
        [int]$MaxPrs = 30
    )

    $email = "$Alias@microsoft.com"
    $org = $script:SarmaConfig.AdoOrg
    $project = $script:SarmaConfig.AdoProject
    $pat = $script:SarmaConfig.AdoPat
    if (-not $pat) { throw "AZURE_DEVOPS_PAT required for profile generation" }
    $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat"))
    $adoHeaders = @{ "Authorization" = "Basic $b64" }
    $baseUrl = "https://dev.azure.com/$org/$([uri]::EscapeDataString($project))/_apis"

    # 1. Fetch completed PRs where this person was a reviewer
    Write-Host "  Fetching PRs reviewed by $Alias..." -ForegroundColor DarkGray
    $searchUrl = "$baseUrl/git/repositories/DsMainDev/pullrequests?searchCriteria.status=completed&searchCriteria.reviewerId=&`$top=$MaxPrs&api-version=7.1"

    # Get reviewer identity ID first
    $identUrl = "https://vssps.dev.azure.com/$org/_apis/identities?searchFilter=MailAddress&filterValue=$email&api-version=7.1"
    $identResp = Invoke-RestMethod -Uri $identUrl -Headers $adoHeaders -ErrorAction Stop
    if (-not $identResp.value -or $identResp.value.Count -eq 0) {
        throw "Could not find identity for $email"
    }
    $reviewerId = $identResp.value[0].id
    $displayName = $identResp.value[0].providerDisplayName

    $prUrl = "$baseUrl/git/repositories/DsMainDev/pullrequests?searchCriteria.status=completed&searchCriteria.reviewerId=$reviewerId&`$top=$MaxPrs&api-version=7.1"
    $prResp = Invoke-RestMethod -Uri $prUrl -Headers $adoHeaders -ErrorAction Stop
    $prs = $prResp.value
    Write-Host "  Found $($prs.Count) PRs" -ForegroundColor DarkGray

    # 2. Fetch review comment threads for each PR
    $allComments = @()
    $prsDone = 0
    foreach ($pr in $prs) {
        $prsDone++
        Write-Host "  [$prsDone/$($prs.Count)] PR #$($pr.pullRequestId): $($pr.title)" -ForegroundColor DarkGray -NoNewline

        $threadsUrl = "$baseUrl/git/repositories/DsMainDev/pullRequests/$($pr.pullRequestId)/threads?api-version=7.1"
        try {
            $threads = (Invoke-RestMethod -Uri $threadsUrl -Headers $adoHeaders -ErrorAction Stop).value
        } catch {
            Write-Host " (skipped)" -ForegroundColor DarkGray
            continue
        }

        $prCommentCount = 0
        foreach ($thread in $threads) {
            # Skip non-code threads (votes, system messages)
            if (-not $thread.threadContext) { continue }

            # Only include comments authored by the target reviewer
            $reviewerComments = $thread.comments | Where-Object {
                $_.author.uniqueName -eq $email -and $_.content -notmatch 'voted \d+'
            }
            if (-not $reviewerComments) { continue }

            foreach ($c in $reviewerComments) {
                $allComments += [PSCustomObject]@{
                    PrId    = $pr.pullRequestId
                    PrTitle = $pr.title
                    File    = $thread.threadContext.filePath
                    Line    = if ($thread.threadContext.rightFileStart) { $thread.threadContext.rightFileStart.line } else { 0 }
                    Comment = $c.content
                    Date    = $c.publishedDate
                }
                $prCommentCount++
            }
        }
        Write-Host " ($prCommentCount comments)" -ForegroundColor DarkGray
    }

    Write-Host "  Total: $($allComments.Count) code review comments" -ForegroundColor Cyan

    if ($allComments.Count -eq 0) {
        Write-Host "  No review comments found for $Alias" -ForegroundColor Yellow
        return $null
    }

    # 3. Build profile from comments
    Write-Host "  Generating profile..." -ForegroundColor DarkGray
    $profileText = Build-ProfileFromComments -Alias $Alias -DisplayName $displayName -Comments $allComments

    # 4. Save to storage
    Save-ReviewerProfile -Alias $Alias -DisplayName $displayName -ProfileText $profileText `
        -PrCount $prs.Count -CommentCount $allComments.Count

    Write-Host "  ✅ Profile saved for $Alias ($($allComments.Count) comments from $($prs.Count) PRs)" -ForegroundColor Green
    return $profileText
}

function Build-ProfileFromComments {
    <#
    .SYNOPSIS
        Analyze review comments and generate a structured profile.
    #>
    param(
        [string]$Alias,
        [string]$DisplayName,
        [array]$Comments
    )

    # Categorize comments by pattern
    $categories = @{
        "Dead code / unused symbols" = @()
        "Correctness / edge cases"   = @()
        "Logging / observability"    = @()
        "API design / abstractions"  = @()
        "Test quality / coverage"    = @()
        "Documentation / comments"   = @()
        "Typos / formatting"         = @()
        "Other"                      = @()
    }

    foreach ($c in $Comments) {
        $text = $c.Comment.ToLower()
        if ($text -match 'not used|unused|dead|unreachable') {
            $categories["Dead code / unused symbols"] += $c
        } elseif ($text -match 'typo|nit:|formatting|indent|whitespace|spacing') {
            $categories["Typos / formatting"] += $c
        } elseif ($text -match 'log|telemetry|observab|trace|prefix|kusto|diagnos') {
            $categories["Logging / observability"] += $c
        } elseif ($text -match 'test|coverage|assert|expect|mock|concurrent|race|contention') {
            $categories["Test quality / coverage"] += $c
        } elseif ($text -match 'doc|comment|readme|header|copyright|description|mention') {
            $categories["Documentation / comments"] += $c
        } elseif ($text -match 'edge|boundary|null|empty|overflow|off.by|sentinel|initial|valid') {
            $categories["Correctness / edge cases"] += $c
        } elseif ($text -match 'abstraction|struct|pattern|contract|api|design|refactor|inconsist|duplicate') {
            $categories["API design / abstractions"] += $c
        } else {
            $categories["Other"] += $c
        }
    }

    # Build profile text
    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.AppendLine("# Review Profile: $DisplayName ($Alias)")
    $null = $sb.AppendLine("Generated from $($Comments.Count) code review comments across recent PRs.`n")

    # Focus areas sorted by frequency
    $null = $sb.AppendLine("## Focus Areas (by frequency)")
    $sorted = $categories.GetEnumerator() | Where-Object { $_.Value.Count -gt 0 } | Sort-Object { $_.Value.Count } -Descending
    $rank = 1
    foreach ($cat in $sorted) {
        $null = $sb.AppendLine("${rank}. **$($cat.Key)** ($($cat.Value.Count) comments)")
        $rank++
    }
    $null = $sb.AppendLine("")

    # Representative examples (pick top 2 from each non-empty category)
    $null = $sb.AppendLine("## Representative Examples")
    foreach ($cat in $sorted) {
        $null = $sb.AppendLine("### $($cat.Key)")
        $examples = $cat.Value | Where-Object { $_.Comment.Length -gt 15 } | Select-Object -First 3
        foreach ($ex in $examples) {
            $commentPreview = $ex.Comment
            if ($commentPreview.Length -gt 400) { $commentPreview = $commentPreview.Substring(0, 400) + "..." }
            $null = $sb.AppendLine("- [$($ex.File)] ``$commentPreview``")
        }
        $null = $sb.AppendLine("")
    }

    # Comment style analysis
    $shortComments = ($Comments | Where-Object { $_.Comment.Length -lt 50 }).Count
    $longComments = ($Comments | Where-Object { $_.Comment.Length -gt 200 }).Count
    $questionComments = ($Comments | Where-Object { $_.Comment -match '\?' }).Count
    $codeComments = ($Comments | Where-Object { $_.Comment -match '```|struct |class |void |if \(' }).Count

    $null = $sb.AppendLine("## Comment Style")
    $null = $sb.AppendLine("- Short/terse (< 50 chars): $shortComments/$($Comments.Count) ($('{0:P0}' -f ($shortComments / $Comments.Count)))")
    $null = $sb.AppendLine("- Detailed with code examples: $codeComments/$($Comments.Count)")
    $null = $sb.AppendLine("- Questions probing intent: $questionComments/$($Comments.Count)")
    $null = $sb.AppendLine("- Long/architectural (> 200 chars): $longComments/$($Comments.Count)")
    $null = $sb.AppendLine("")

    $null = $sb.AppendLine("## Review Instructions")
    $null = $sb.AppendLine("When reviewing as $DisplayName, you should:")
    $null = $sb.AppendLine("- Focus especially on: $(($sorted | Select-Object -First 3 | ForEach-Object { $_.Key }) -join ', ')")
    $null = $sb.AppendLine("- Match the comment style: $(if ($shortComments -gt $longComments) { 'prefer concise comments for simple issues' } else { 'provide detailed feedback with code examples' })")
    $null = $sb.AppendLine("- $(if ($questionComments -gt $Comments.Count / 3) { 'Ask questions to understand intent before suggesting changes' } else { 'Make direct suggestions rather than asking questions' })")
    $null = $sb.AppendLine("- $(if ($codeComments -gt 2) { 'Provide concrete code examples when suggesting structural changes' } else { 'Keep suggestions descriptive without full code rewrites' })")

    return $sb.ToString()
}
