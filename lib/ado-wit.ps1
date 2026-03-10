# lib\ado-wit.ps1 — Azure DevOps work item fetch

function Get-SarmaWorkItem {
    <#
    .SYNOPSIS
        Fetch a work item from Azure DevOps and return clean title + description.
    #>
    param(
        [Parameter(Mandatory)][int]$Id
    )

    $org = $script:SarmaConfig.AdoOrg
    $project = [uri]::EscapeDataString($script:SarmaConfig.AdoWitProject)
    $url = "https://dev.azure.com/$org/$project/_apis/wit/workitems/$Id`?api-version=7.1"
    $headers = Get-SarmaAdoHeaders

    $wi = Invoke-RestMethod -Uri $url -Method Get -Headers $headers

    $title = $wi.fields."System.Title"
    $rawDesc = $wi.fields."System.Description"
    $wiType = $wi.fields."System.WorkItemType"
    $state = $wi.fields."System.State"

    # Strip HTML from description
    $desc = $rawDesc -replace "<br\s*/?>", "`n"
    $desc = $desc -replace "<li>", "- "
    $desc = $desc -replace "<[^>]+>", ""
    $desc = [System.Net.WebUtility]::HtmlDecode($desc)
    $desc = $desc.Trim()

    return [PSCustomObject]@{
        Id          = $Id
        Title       = $title
        Description = $desc
        Type        = $wiType
        State       = $state
    }
}
