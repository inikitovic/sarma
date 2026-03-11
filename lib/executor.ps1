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

    # Launch interactive agency copilot in a new window (no Tee — breaks interactive terminal)
    $escapedWorkDir = $WorkDir -replace "'", "''"
    $proc = Start-Process pwsh -ArgumentList '-NoExit', '-Command', `
        "Set-Location '$escapedWorkDir'; agency copilot" `
        -PassThru

    # Wait for copilot to fully load (MCP servers, etc.)
    # Poll the agency log directory for a new session to confirm it's ready
    Write-Host "    Waiting for copilot to load…" -ForegroundColor DarkGray
    $agencyLogDir = "$env:USERPROFILE\.agency\logs"
    $preSessionCount = (Get-ChildItem $agencyLogDir -Directory -ErrorAction SilentlyContinue).Count
    $bootWait = 0
    $maxBootWait = 60
    while ($bootWait -lt $maxBootWait) {
        Start-Sleep 3
        $bootWait += 3
        $currentCount = (Get-ChildItem $agencyLogDir -Directory -ErrorAction SilentlyContinue).Count
        if ($currentCount -gt $preSessionCount) {
            # New session appeared — copilot is loading
            Start-Sleep 10  # give it extra time to finish loading MCP servers
            break
        }
    }
    Write-Host "    Copilot loaded (${bootWait}s)" -ForegroundColor DarkGray

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

    # Poll for .sarma-done file — agent creates it when finished
    $doneFile = Join-Path $WorkDir ".sarma-done"
    $pollInterval = 5
    $maxWait = $script:SarmaConfig.ExecutorTimeout

    Write-Host "    Waiting for agent to complete (polling .sarma-done)…" -ForegroundColor DarkGray
    $waited = 0
    while (-not (Test-Path $doneFile) -and -not $proc.HasExited -and $waited -lt $maxWait) {
        Start-Sleep $pollInterval
        $waited += $pollInterval
    }

    if (Test-Path $doneFile) {
        Write-Host "    Agent signaled completion — shutting down session…" -ForegroundColor Green
        Remove-Item $doneFile -Force -ErrorAction SilentlyContinue

        # Send Ctrl+C twice to gracefully exit copilot (captures resume ID)
        Start-Sleep 2
        $wshell.AppActivate($proc.Id) | Out-Null
        Start-Sleep 1
        $wshell.SendKeys("^c")
        Start-Sleep 2
        $wshell.SendKeys("^c")
        Start-Sleep 3
    } elseif ($waited -ge $maxWait) {
        Write-Host "    Timeout — killing agent session…" -ForegroundColor Yellow
        $wshell.AppActivate($proc.Id) | Out-Null
        Start-Sleep 1
        $wshell.SendKeys("^c")
        Start-Sleep 2
        $wshell.SendKeys("^c")
        Start-Sleep 3
    }

    # Wait for process to fully exit
    if (-not $proc.HasExited) {
        $proc.WaitForExit(10000) | Out-Null
        if (-not $proc.HasExited) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        }
    }

    $endTime = Get-Date
    $duration = [Math]::Round(($endTime - $startTime).TotalSeconds, 1)

    # Try to extract resume session ID from the agency log directory
    $sessionId = ""
    $agencyLogDir = "$env:USERPROFILE\.agency\logs"
    $latestSession = Get-ChildItem $agencyLogDir -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latestSession) {
        # Check for resume ID in session logs
        $sessionLogs = Get-ChildItem $latestSession.FullName -File -ErrorAction SilentlyContinue
        foreach ($f in $sessionLogs) {
            $content = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
            if ($content -match '--resume=([a-f0-9\-]+)') {
                $sessionId = $Matches[1]
                break
            }
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
    Remove-Item (Join-Path $WorkDir ".sarma-done") -Force -ErrorAction SilentlyContinue

    return [PSCustomObject]@{
        ExitCode  = $exitCode
        Stdout    = "Agent session: ${duration}s"
        Stderr    = ""
        Success   = ($exitCode -eq 0 -or $exitCode -eq $null)
        SessionId = $sessionId
    }
}
