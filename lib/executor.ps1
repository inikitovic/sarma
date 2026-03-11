# lib/executor.ps1 — Launch agency copilot via ConPTY (no window focus required)

. "$PSScriptRoot\conpty.ps1"

function Strip-Ansi {
    param([string]$Text)
    # Strip ANSI escape sequences (CSI, OSC) from terminal output
    return $Text -replace '\x1b\[[0-9;]*[a-zA-Z]', '' -replace '\x1b\][^\x07]*\x07', '' -replace '\x1b\[[\?0-9;]*[a-zA-Z]', ''
}

function Invoke-CopilotAgent {
    <#
    .SYNOPSIS
        Launch agency copilot via ConPTY pseudo-terminal.
        Writes commands through pipes — no window focus or SendKeys needed.
    .PARAMETER KeepAlive
        If set, after task completes, open a visible terminal with --resume
        so the user can continue the copilot session interactively.
    #>
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string]$WorkDir,
        [switch]$KeepAlive
    )

    if (-not [System.IO.Path]::IsPathRooted($WorkDir)) {
        $WorkDir = [System.IO.Path]::GetFullPath($WorkDir)
    }
    if (-not (Test-Path $WorkDir)) {
        return [PSCustomObject]@{
            ExitCode = -3; Stdout = ""; Stderr = "Working directory does not exist: $WorkDir"
            Success = $false; SessionId = ""
        }
    }

    # Write task file to temp directory (keeps repo clean)
    $taskDir = Join-Path $env:TEMP "sarma"
    if (-not (Test-Path $taskDir)) { New-Item -ItemType Directory -Path $taskDir -Force | Out-Null }
    $taskId = [guid]::NewGuid().ToString().Substring(0, 8)
    $taskFile = Join-Path $taskDir "task-$taskId.md"
    $doneFile = Join-Path $taskDir "done-$taskId"

    # Append completion signal instruction to prompt
    $doneFileFwd = $doneFile -replace '\\', '/'
    $fullPrompt = $Prompt + @"


COMPLETION SIGNAL: When ALL work above is finished, as the VERY LAST step, run:
    echo done > "$doneFileFwd"
This signals the orchestrator that you are done. Do NOT skip this step.
"@
    $fullPrompt | Set-Content -Path $taskFile -Encoding UTF8

    $taskFileFwd = $taskFile -replace '\\', '/'
    $shortPrompt = "Read the file '$taskFileFwd' and complete all the work described in it. Follow every instruction exactly."

    Write-Host "    --- launching agency copilot (ConPTY) ---" -ForegroundColor DarkCyan
    $startTime = Get-Date

    # Pre-authenticate Azure tokens
    Write-Host "    Pre-authenticating Azure tokens..." -ForegroundColor DarkGray
    $null = az account get-access-token --resource "https://management.azure.com" 2>&1
    $null = az account get-access-token --resource "https://storage.azure.com" 2>&1
    $null = az account get-access-token --resource "499b84ac-1321-427f-aa17-267ca6975798" 2>&1

    # Build command line for pwsh inside ConPTY
    $escapedWorkDir = $WorkDir -replace "'", "''"
    $initScript = Join-Path $WorkDir "init.ps1"
    $initCmd = if (Test-Path $initScript) { ". '$($initScript -replace "'","''")'; " } else { "" }
    $cmdLine = "pwsh -NoLogo -Command `"${initCmd}Set-Location '$escapedWorkDir'; agency copilot`""

    $pty = New-Object SarmaConPty
    $exitCode = 0
    $agentCompleted = $false
    $sessionId = ""

    try {
        $pty.Start($cmdLine, $WorkDir)
        Write-Host "    Process started (PID: $($pty.ProcessId))" -ForegroundColor DarkGray

        # ── Wait for copilot to fully load ────────────────────
        Write-Host "    Waiting for copilot to load..." -ForegroundColor DarkGray
        $allOutput = ""
        $bootWait = 0
        $maxBoot = 300
        while ($bootWait -lt $maxBoot -and -not $pty.HasExited) {
            $chunk = $pty.Read(3000)
            $bootWait += 3
            if ($chunk) {
                $allOutput += $chunk
                $clean = Strip-Ansi $allOutput
                if ($clean -match 'Environment loaded:') {
                    Write-Host "    Copilot ready (${bootWait}s)" -ForegroundColor DarkGray
                    Start-Sleep 3
                    break
                }
            }
        }

        if ($pty.HasExited) {
            throw "Copilot process exited during startup (exit code: $($pty.ExitCode))"
        }
        if ($bootWait -ge $maxBoot) {
            Write-Host "    Warning: boot timeout reached, proceeding..." -ForegroundColor Yellow
        }

        # ── Send initialization commands ──────────────────────
        # No window focus needed — writing directly to PTY input pipe
        Write-Host "    Sending commands..." -ForegroundColor DarkGray

        # PTY output log for debugging
        $ptyLogFile = Join-Path $taskDir "ptylog-$taskId.txt"
        function Log-PtyOutput {
            param([string]$Label)
            $raw = $pty.Read(2000)
            if ($raw) {
                $clean = Strip-Ansi $raw
                $entry = "[$Label] $(Get-Date -Format 'HH:mm:ss')`n$clean`n"
                Add-Content -Path $ptyLogFile -Value $entry -Encoding UTF8
                Write-Host "    [$Label] $(($clean -split "`n" | Select-Object -First 1).Trim())" -ForegroundColor DarkGray
            }
        }

        # /allow-all — enable autopilot permissions
        $pty.Write("/allow-all`r")
        Start-Sleep 3
        Log-PtyOutput "allow-all"

        # /model — set the model
        $pty.Write("/model claude-opus-4.6-1m`r")
        Start-Sleep 3
        Log-PtyOutput "model"

        # Shift+Tab x2 — switch to agent mode (ask → edit → agent)
        # In terminal, Shift+Tab = ESC [ Z
        $pty.Write("`e[Z")
        Start-Sleep 1
        $pty.Write("`e[Z")
        Start-Sleep 2
        Log-PtyOutput "shift-tab"

        # Send the task prompt
        $pty.Write("$shortPrompt`r")
        Start-Sleep 1
        Log-PtyOutput "prompt"

        Write-Host "    Prompt sent — agent is working..." -ForegroundColor DarkGray
        Write-Host "    PTY log: $ptyLogFile" -ForegroundColor DarkGray

        # ── Poll for completion ───────────────────────────────
        $maxWait = $script:SarmaConfig.ExecutorTimeout
        $waited = 0
        while (-not (Test-Path $doneFile) -and -not $pty.HasExited -and $waited -lt $maxWait) {
            Start-Sleep 5
            $waited += 5
            # Drain PTY output periodically (prevents pipe buffer from filling)
            $chunk = $pty.Read(500)
            if ($chunk -and $waited % 30 -eq 0) {
                $clean = (Strip-Ansi $chunk).Trim()
                if ($clean) {
                    $preview = if ($clean.Length -gt 100) { $clean.Substring(0,100) + "..." } else { $clean }
                    Write-Host "    [${waited}s] $preview" -ForegroundColor DarkGray
                    Add-Content -Path $ptyLogFile -Value "[poll ${waited}s] $(Get-Date -Format 'HH:mm:ss')`n$clean`n" -Encoding UTF8
                }
            }
        }

        $agentCompleted = Test-Path $doneFile
        if ($agentCompleted) {
            Remove-Item $doneFile -Force -ErrorAction SilentlyContinue

            if ($KeepAlive) {
                Write-Host "    Agent completed — preparing interactive session..." -ForegroundColor Green
            } else {
                Write-Host "    Agent completed — shutting down copilot..." -ForegroundColor Green
                Start-Sleep 3
                # Ctrl+C twice to exit copilot cleanly
                $pty.Write("`u{03}")
                Start-Sleep 1
                $pty.Write("`u{03}")
                Start-Sleep 2
                $pty.Write("exit`r")
                Start-Sleep 2
            }
        } elseif ($waited -ge $maxWait) {
            Write-Host "    Timeout — killing agent..." -ForegroundColor Yellow
            $pty.Write("`u{03}")
            Start-Sleep 1
            $pty.Write("`u{03}")
            Start-Sleep 2
        }

        # Capture exit code before cleanup
        $exitCode = if ($pty.HasExited) { $pty.ExitCode } else { 0 }

        # Extract session ID from agency logs
        $agencyLogDir = "$env:USERPROFILE\.agency\logs"
        if (Test-Path $agencyLogDir) {
            $latestSession = Get-ChildItem $agencyLogDir -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.CreationTime -gt $startTime } |
                Sort-Object CreationTime -Descending |
                Select-Object -First 1
            if ($latestSession) {
                foreach ($f in (Get-ChildItem $latestSession.FullName -File -ErrorAction SilentlyContinue)) {
                    $content = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
                    if ($content -match '--resume=([a-f0-9\-]+)') {
                        $sessionId = $Matches[1]
                        break
                    }
                }
            }
        }

        # For KeepAlive: close headless PTY, open a visible terminal with --resume
        if ($KeepAlive -and $agentCompleted -and $sessionId) {
            Write-Host "    Opening interactive terminal (session: $sessionId)..." -ForegroundColor Cyan
            $resumeCmd = "${initCmd}Set-Location '$escapedWorkDir'; agency copilot --resume=$sessionId"
            Start-Process pwsh -ArgumentList @('-NoExit', '-NoLogo', '-Command', $resumeCmd)
        } elseif ($KeepAlive -and $agentCompleted) {
            Write-Host "    Warning: could not extract session ID for resume" -ForegroundColor Yellow
        }

    } catch {
        Write-Host "    ConPTY error: $($_.Exception.Message)" -ForegroundColor Red
        $exitCode = -1
    } finally {
        # Cleanup: kill process and close all handles
        if (-not $pty.HasExited) { $pty.Kill() }
        $pty.WaitForExit(5000)
        $pty.Dispose()
    }

    $duration = [Math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)
    Write-Host "    --- session ended (${duration}s) ---" -ForegroundColor DarkCyan
    if ($sessionId) {
        Write-Host "    Resume: agency copilot --resume=$sessionId" -ForegroundColor Cyan
    }

    # Cleanup temp files
    Remove-Item $taskFile -Force -ErrorAction SilentlyContinue
    Remove-Item $doneFile -Force -ErrorAction SilentlyContinue

    return [PSCustomObject]@{
        ExitCode  = $exitCode
        Stdout    = "Agent session: ${duration}s"
        Stderr    = ""
        Success   = $agentCompleted
        SessionId = $sessionId
    }
}
