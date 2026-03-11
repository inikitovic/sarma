# lib\config.ps1 — Sarma Launcher configuration

$script:SarmaConfig = @{
    StorageAccount  = if ($env:SARMA_STORAGE_ACCOUNT) { $env:SARMA_STORAGE_ACCOUNT } else { "dbjekovicsa" }
    LocalRepo       = if ($env:SARMA_LOCAL_REPO) { $env:SARMA_LOCAL_REPO } elseif (Test-Path "Q:\src\DsMainDev\.git") { "Q:\src\DsMainDev" } else { "" }
    DefaultRepo     = if ($env:SARMA_DEFAULT_REPO) { $env:SARMA_DEFAULT_REPO } else { "https://dev.azure.com/msdata/Database%20Systems/_git/DsMainDev" }
    DefaultBranch   = if ($env:SARMA_DEFAULT_BRANCH) { $env:SARMA_DEFAULT_BRANCH } else { "master" }
    AdoOrg          = if ($env:ADO_ORG) { $env:ADO_ORG } else { "msdata" }
    AdoProject      = if ($env:ADO_PROJECT) { $env:ADO_PROJECT } else { "Database Systems" }
    AdoWitProject   = if ($env:ADO_WIT_PROJECT) { $env:ADO_WIT_PROJECT } else { "Azure SQL Data Warehouse" }
    AdoPat          = if ($env:AZURE_DEVOPS_PAT) { $env:AZURE_DEVOPS_PAT } else { "" }
    CopilotCliCmd   = if ($env:COPILOT_CLI_CMD) { $env:COPILOT_CLI_CMD } else { "copilot" }
    CopilotCliArgs  = if ($env:COPILOT_CLI_ARGS) { $env:COPILOT_CLI_ARGS } else { "" }
    WorkerTaskTypes = if ($env:WORKER_TASK_TYPES) { $env:WORKER_TASK_TYPES -split "," } else { @("backend","frontend","test","docs","revise","reserve") }
    WorktreeDir     = if ($env:WORKTREE_DIR) { $env:WORKTREE_DIR } else { "./worktrees" }
    ExecutorTimeout = if ($env:EXECUTOR_TIMEOUT) { [int]$env:EXECUTOR_TIMEOUT } else { 3600 }
    WorkerId        = if ($env:WORKER_ID) { $env:WORKER_ID } else { $env:COMPUTERNAME }
    UserAlias       = if ($env:SARMA_ALIAS) { $env:SARMA_ALIAS } else { $env:USERNAME }
}

# Token cache
$script:_tokenCache = $null
$script:_tokenExpiry = [datetime]::MinValue

function Get-SarmaToken {
    <#
    .SYNOPSIS
        Get an Azure Entra ID bearer token for Storage API calls. Caches for 5 minutes.
    #>
    param(
        [string]$Resource = "https://storage.azure.com"
    )

    $now = [datetime]::UtcNow
    if ($script:_tokenCache -and $now -lt $script:_tokenExpiry) {
        return $script:_tokenCache
    }

    $result = az account get-access-token --resource $Resource --query accessToken -o tsv 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to get Azure token. Run 'az login' first. Error: $result"
    }

    $script:_tokenCache = $result.Trim()
    $script:_tokenExpiry = $now.AddMinutes(5)
    return $script:_tokenCache
}

function Get-SarmaAdoHeaders {
    <#
    .SYNOPSIS
        Get Authorization headers for Azure DevOps REST API using PAT.
    #>
    $pat = $script:SarmaConfig.AdoPat
    if (-not $pat) { throw "AZURE_DEVOPS_PAT is required" }
    $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat"))
    return @{
        "Authorization" = "Basic $b64"
        "Content-Type"  = "application/json"
    }
}

function Get-SarmaStorageHeaders {
    <#
    .SYNOPSIS
        Get Authorization headers for Azure Storage REST API using Entra token.
    #>
    $token = Get-SarmaToken
    return @{
        "Authorization" = "Bearer $token"
        "x-ms-version"  = "2023-11-03"
        "x-ms-date"     = [datetime]::UtcNow.ToString("R")
    }
}
