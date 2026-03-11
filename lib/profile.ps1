# lib/profile.ps1 — Reviewer profile storage (generation is done by Copilot agent)

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
