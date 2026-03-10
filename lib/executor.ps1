# lib\executor.ps1 — Run agency copilot inline in the current terminal

function Invoke-CopilotAgent {
    <#
    .SYNOPSIS
        Run agency copilot in the current terminal with autopilot mode.
        The agent handles everything: code changes, commit, push, and PR creation.
        After the agent exits, control returns to the worker.
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

    # Write prompt to a temp file (avoids quoting/escaping issues with long prompts)
    $promptFile = Join-Path $WorkDir ".sarma-prompt.txt"
    $Prompt | Set-Content -Path $promptFile -Encoding UTF8

    $prevDir = Get-Location
    try {
        Set-Location $WorkDir

        Write-Host "    ─── agency copilot session ───" -ForegroundColor DarkCyan
        $startTime = Get-Date

        # Write full task details to a file the agent can read
        $taskFile = Join-Path $WorkDir ".sarma-task.md"
        $Prompt | Set-Content -Path $taskFile -Encoding UTF8

        # Keep the CLI prompt short — point to the task file for details
        $shortPrompt = "Read the task file .sarma-task.md in the current directory and complete the work described in it. Follow all instructions exactly."
        & agency copilot --prompt $shortPrompt --autopilot --allow-all
        $exitCode = $LASTEXITCODE

        $endTime = Get-Date
        $duration = [Math]::Round(($endTime - $startTime).TotalSeconds, 1)
        Write-Host "    ─── session ended (${duration}s, rc=$exitCode) ───" -ForegroundColor DarkCyan

    } finally {
        Set-Location $prevDir
        Remove-Item $promptFile -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $WorkDir ".sarma-task.md") -Force -ErrorAction SilentlyContinue
    }

    return [PSCustomObject]@{
        ExitCode = $exitCode
        Stdout   = "Agent session: ${duration}s"
        Stderr   = ""
        Success  = ($exitCode -eq 0)
    }
}
