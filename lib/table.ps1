# lib\table.ps1 — Task storage backed by Azure Blob Storage
# Uses a blob container "sarma" with JSON blobs instead of Table Storage.

function Get-BlobUrl {
    param([string]$Container, [string]$BlobName)
    $acct = $script:SarmaConfig.StorageAccount
    return "https://$acct.blob.core.windows.net/$Container/$BlobName"
}

function Initialize-SarmaContainer {
    <#
    .SYNOPSIS
        Create the sarma blob container if it doesn't exist.
    #>
    $acct = $script:SarmaConfig.StorageAccount
    $url = "https://$acct.blob.core.windows.net/sarma?restype=container"
    $headers = Get-SarmaStorageHeaders
    try {
        Invoke-RestMethod -Uri $url -Method Put -Headers $headers -ErrorAction SilentlyContinue
    } catch {}
}

function Set-SarmaTableEntity {
    <#
    .SYNOPSIS
        Save an entity as a JSON blob. TableName becomes a prefix, RowKey becomes blob name.
    #>
    param(
        [Parameter(Mandatory)][string]$TableName,
        [Parameter(Mandatory)][string]$PartitionKey,
        [Parameter(Mandatory)][string]$RowKey,
        [Parameter(Mandatory)][hashtable]$Properties
    )

    # Merge: read existing blob, merge properties, write back
    $existing = Get-SarmaTableEntity -TableName $TableName -PartitionKey $PartitionKey -RowKey $RowKey
    $merged = @{}
    if ($existing) {
        $existing.PSObject.Properties | ForEach-Object { $merged[$_.Name] = $_.Value }
    }
    $merged["PartitionKey"] = $PartitionKey
    $merged["RowKey"] = $RowKey
    foreach ($k in $Properties.Keys) { $merged[$k] = $Properties[$k] }

    $blobName = "$TableName/$PartitionKey/$RowKey.json"
    $url = Get-BlobUrl -Container "sarma" -BlobName $blobName
    $headers = Get-SarmaStorageHeaders
    $headers["Content-Type"] = "application/json"
    $headers["x-ms-blob-type"] = "BlockBlob"

    $json = $merged | ConvertTo-Json -Depth 5
    Invoke-RestMethod -Uri $url -Method Put -Headers $headers -Body $json
}

function Get-SarmaTableEntity {
    <#
    .SYNOPSIS
        Get a single entity from blob storage.
    #>
    param(
        [Parameter(Mandatory)][string]$TableName,
        [Parameter(Mandatory)][string]$PartitionKey,
        [Parameter(Mandatory)][string]$RowKey
    )

    $blobName = "$TableName/$PartitionKey/$RowKey.json"
    $url = Get-BlobUrl -Container "sarma" -BlobName $blobName
    $headers = Get-SarmaStorageHeaders

    try {
        return Invoke-RestMethod -Uri $url -Method Get -Headers $headers
    } catch {
        return $null
    }
}

function Get-SarmaTableEntities {
    <#
    .SYNOPSIS
        List entities by prefix, with optional client-side filtering.
    #>
    param(
        [Parameter(Mandatory)][string]$TableName,
        [string]$Filter = ""
    )

    $acct = $script:SarmaConfig.StorageAccount
    $prefix = "$TableName/task/"
    $url = "https://$acct.blob.core.windows.net/sarma?restype=container&comp=list&prefix=$prefix"
    $headers = Get-SarmaStorageHeaders

    $webResp = Invoke-WebRequest -Uri $url -Method Get -Headers $headers
    $content = $webResp.Content.TrimStart([char]0xFEFF, [char]0xFFFE)  # strip BOM
    $xmlDoc = New-Object System.Xml.XmlDocument
    $xmlDoc.LoadXml($content)
    $blobs = $xmlDoc.EnumerationResults.Blobs.Blob

    if (-not $blobs) { return @() }

    $entities = @()
    foreach ($blob in $blobs) {
        $blobUrl = Get-BlobUrl -Container "sarma" -BlobName $blob.Name
        try {
            $entity = Invoke-RestMethod -Uri $blobUrl -Method Get -Headers (Get-SarmaStorageHeaders)
            # Client-side OData-like filtering
            $include = $true
            if ($Filter) {
                $conditions = $Filter -split " and "
                foreach ($cond in $conditions) {
                    if ($cond -match "(\w+)\s+eq\s+'([^']*)'") {
                        $field = $Matches[1]
                        $val = $Matches[2]
                        if ($field -ne "PartitionKey" -and $entity.$field -ne $val) {
                            $include = $false
                            break
                        }
                    }
                }
            }
            if ($include) { $entities += $entity }
        } catch { continue }
    }
    return $entities
}

function Remove-SarmaTableEntity {
    <#
    .SYNOPSIS
        Delete an entity blob.
    #>
    param(
        [Parameter(Mandatory)][string]$TableName,
        [Parameter(Mandatory)][string]$PartitionKey,
        [Parameter(Mandatory)][string]$RowKey
    )

    $blobName = "$TableName/$PartitionKey/$RowKey.json"
    $url = Get-BlobUrl -Container "sarma" -BlobName $blobName
    $headers = Get-SarmaStorageHeaders
    Invoke-RestMethod -Uri $url -Method Delete -Headers $headers
}
