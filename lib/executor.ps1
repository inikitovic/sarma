# lib\executor.ps1 — Run agency copilot in a fresh pwsh subprocess

function Invoke-CopilotAgent {
    <#
    .SYNOPSIS
        Run agency copilot in a fresh pwsh child process to avoid stale state.
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

    # Write full task details to a file the agent can read
    $taskFile = Join-Path $WorkDir ".sarma-task.md"
    $Prompt | Set-Content -Path $taskFile -Encoding UTF8

    $shortPrompt = "Read the task file .sarma-task.md in the current directory and complete the work described in it. Follow all instructions exactly."
    $escapedWorkDir = $WorkDir -replace "'", "''"
    $escapedPrompt = $shortPrompt -replace "'", "''"

    Write-Host "    ─── agency copilot session (subprocess) ───" -ForegroundColor DarkCyan
    $startTime = Get-Date

    # Run in a fresh pwsh subprocess — inherits env/auth but clean process state
    $proc = Start-Process pwsh -ArgumentList '-Command', "Set-Location '$escapedWorkDir'; agency copilot --prompt '$escapedPrompt' --autopilot --allow-all; exit `$LASTEXITCODE" `
        -NoNewWindow -Wait -PassThru

    $endTime = Get-Date
    $duration = [Math]::Round(($endTime - $startTime).TotalSeconds, 1)
    Write-Host "    ─── session ended (${duration}s, rc=$($proc.ExitCode)) ───" -ForegroundColor DarkCyan

    # Cleanup
    Remove-Item $taskFile -Force -ErrorAction SilentlyContinue

    return [PSCustomObject]@{
        ExitCode = $proc.ExitCode
        Stdout   = "Agent session: ${duration}s"
        Stderr   = ""
        Success  = ($proc.ExitCode -eq 0)
    }
}
