# lib\executor.ps1 — Launch agency copilot in a new pwsh window

function Invoke-CopilotAgent {
    <#
    .SYNOPSIS
        Launch agency copilot in a new PowerShell 7 window with autopilot mode.
        The agent handles everything: code changes, commit, push, and PR creation.
    #>
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string]$WorkDir
    )

    # Resolve to absolute path
    if (-not [System.IO.Path]::IsPathRooted($WorkDir)) {
        $WorkDir = [System.IO.Path]::GetFullPath($WorkDir)
    }
    if (-not (Test-Path $WorkDir)) {
        return [PSCustomObject]@{
            ExitCode = -3
            Stdout   = ""
            Stderr   = "Working directory does not exist: $WorkDir"
            Success  = $false
        }
    }

    # Write prompt to a temp file (avoids quoting/escaping issues)
    $promptFile = Join-Path $WorkDir ".sarma-prompt.txt"
    $Prompt | Set-Content -Path $promptFile -Encoding UTF8

    # Build the command to run in the new window
    # Agency copilot reads the prompt, runs autonomously, then writes a result file
    $resultFile = Join-Path $WorkDir ".sarma-result.json"
    $escapedWorkDir = $WorkDir -replace "'", "''"
    $escapedPromptFile = $promptFile -replace "'", "''"
    $escapedResultFile = $resultFile -replace "'", "''"

    $innerCommand = @"
Set-Location '$escapedWorkDir'
`$prompt = Get-Content '$escapedPromptFile' -Raw
`$startTime = Get-Date -Format o
Write-Host '═══ Sarma Agent Session ═══' -ForegroundColor Cyan
Write-Host "Prompt: `$(`$prompt.Substring(0, [Math]::Min(200, `$prompt.Length)))..." -ForegroundColor DarkGray
Write-Host ''

agency copilot --prompt `$prompt --autopilot --allow-all
`$exitCode = `$LASTEXITCODE
`$endTime = Get-Date -Format o

# Write result file for the worker to pick up
@{
    exitCode  = `$exitCode
    startTime = `$startTime
    endTime   = `$endTime
    success   = (`$exitCode -eq 0)
} | ConvertTo-Json | Set-Content '$escapedResultFile' -Encoding UTF8

if (`$exitCode -eq 0) {
    Write-Host '' 
    Write-Host '═══ Agent completed successfully ═══' -ForegroundColor Green
} else {
    Write-Host ''
    Write-Host "═══ Agent failed (exit code `$exitCode) ═══" -ForegroundColor Red
}

Start-Sleep -Seconds 3
"@

    # Launch in a new pwsh window
    $proc = Start-Process pwsh -ArgumentList '-NoExit', '-Command', $innerCommand `
        -PassThru

    Write-Host "    Agent launched in window (PID: $($proc.Id))" -ForegroundColor DarkGray

    # Wait for the process to exit
    $proc.WaitForExit()

    # Read result file if it exists
    if (Test-Path $resultFile) {
        $result = Get-Content $resultFile -Raw | ConvertFrom-Json
        Remove-Item $resultFile -Force -ErrorAction SilentlyContinue
        Remove-Item $promptFile -Force -ErrorAction SilentlyContinue
        return [PSCustomObject]@{
            ExitCode = $result.exitCode
            Stdout   = "Agent session: $($result.startTime) → $($result.endTime)"
            Stderr   = ""
            Success  = $result.success
        }
    }

    # Fallback — no result file (window was closed manually)
    Remove-Item $promptFile -Force -ErrorAction SilentlyContinue
    return [PSCustomObject]@{
        ExitCode = $proc.ExitCode
        Stdout   = "Agent window closed"
        Stderr   = ""
        Success  = ($proc.ExitCode -eq 0)
    }
}
