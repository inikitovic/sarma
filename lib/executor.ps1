# lib\executor.ps1 — Launch agency copilot interactively via SendKeys

function Invoke-CopilotAgent {
    <#
    .SYNOPSIS
        Launch agency copilot in a new interactive terminal window.
        Uses SendKeys to automate: /allow-all → autopilot mode → paste prompt.
        Monitors the process for completion and captures the resume session ID.
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
            ExitCode  = -3
            Stdout    = ""
            Stderr    = "Working directory does not exist: $WorkDir"
            Success   = $false
            SessionId = ""
        }
    }

    # Write task details to a file the agent can read
    $taskFile = Join-Path $WorkDir ".sarma-task.md"
    $Prompt | Set-Content -Path $taskFile -Encoding UTF8

    # Escape special SendKeys characters in the short prompt
    $shortPrompt = "Read the file .sarma-task.md in the current directory and complete all the work described in it. Follow every instruction exactly."
    $safePrompt = $shortPrompt -replace '([+^%~{}[\]()])', '{$1}'

    $escapedWorkDir = $WorkDir -replace "'", "''"

    # Capture output to a log file so we can extract the resume session ID
    $logFile = Join-Path $WorkDir ".sarma-agent.log"

    Write-Host "    ─── launching agency copilot ───" -ForegroundColor DarkCyan
    $startTime = Get-Date

    # Launch interactive agency copilot in a new window, tee output to log
    $proc = Start-Process pwsh -ArgumentList '-NoExit', '-Command', `
        "Set-Location '$escapedWorkDir'; agency copilot 2>&1 | Tee-Object -FilePath '$($logFile -replace "'","''")'" `
        -PassThru

    # Wait for agency copilot to boot
    Start-Sleep 15

    # Automate the interactive session
    $wshell = New-Object -ComObject WScript.Shell

    # Activate the window
    $wshell.AppActivate($proc.Id) | Out-Null
    Start-Sleep 1

    # 1. Allow all tools
    $wshell.SendKeys("/allow-all")
    Start-Sleep 1
    $wshell.SendKeys("{ENTER}")
    Start-Sleep 2

    # 2. Switch to autopilot mode (two Shift+Tabs)
    $wshell.SendKeys("+{TAB}")
    Start-Sleep 1
    $wshell.SendKeys("+{TAB}")
    Start-Sleep 1

    # 3. Type the prompt and submit
    $wshell.SendKeys($safePrompt)
    Start-Sleep 1
    $wshell.SendKeys("{ENTER}")

    Write-Host "    Prompt sent — agent is working…" -ForegroundColor DarkGray
    Write-Host "    (You can watch the agent window. Don't switch focus during SendKeys.)" -ForegroundColor DarkGray

    # Wait for the process to exit
    $proc.WaitForExit()

    $endTime = Get-Date
    $duration = [Math]::Round(($endTime - $startTime).TotalSeconds, 1)

    # Try to extract resume session ID from the log
    $sessionId = ""
    if (Test-Path $logFile) {
        $logContent = Get-Content $logFile -Raw -ErrorAction SilentlyContinue
        if ($logContent -match '--resume=([a-f0-9\-]+)') {
            $sessionId = $Matches[1]
        }
    }

    $exitCode = $proc.ExitCode
    Write-Host "    ─── session ended (${duration}s, rc=$exitCode) ───" -ForegroundColor DarkCyan
    if ($sessionId) {
        Write-Host "    Resume ID: $sessionId" -ForegroundColor Cyan
        Write-Host "    To resume: copilot --resume=$sessionId" -ForegroundColor DarkGray
    }

    # Cleanup task file (keep log for debugging)
    Remove-Item $taskFile -Force -ErrorAction SilentlyContinue

    return [PSCustomObject]@{
        ExitCode  = $exitCode
        Stdout    = "Agent session: ${duration}s"
        Stderr    = ""
        Success   = ($exitCode -eq 0 -or $exitCode -eq $null)
        SessionId = $sessionId
    }
}
