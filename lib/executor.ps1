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
        [switch]$KeepAlive,
        [switch]$SkipInit
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
    $initCmd = if (-not $SkipInit -and (Test-Path $initScript)) { ". '$($initScript -replace "'","''")'; " } else { "" }
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
        $maxBoot = 1800  # 30min — enlistment can be very slow; loop exits on HasExited or readiness
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

        # PTY output log for debugging (raw output goes to file, clean summaries to console)
        $ptyLogFile = Join-Path $taskDir "ptylog-$taskId.txt"
        function Drain-Pty {
            param([string]$Label, [int]$TimeoutMs = 2000)
            $raw = $pty.Read($TimeoutMs)
            if ($raw) {
                $clean = Strip-Ansi $raw
                Add-Content -Path $ptyLogFile -Value "[${Label}] $(Get-Date -Format 'HH:mm:ss')`n$clean`n---`n" -Encoding UTF8
            }
            return $raw
        }

        # /allow-all — enable autopilot permissions
        $pty.Write("/allow-all")
        Start-Sleep -Milliseconds 300
        $pty.Write("`r")
        # /allow-all triggers environment reload — wait for it to finish
        $reloadOutput = ""
        $reloadWait = 0
        while ($reloadWait -lt 30) {
            $chunk = $pty.Read(2000)
            $reloadWait += 2
            if ($chunk) {
                $reloadOutput += $chunk
                $clean = Strip-Ansi $reloadOutput
                if ($clean -match 'All permissions.*enabled') {
                    Start-Sleep 2
                    break
                }
            }
        }
        Add-Content -Path $ptyLogFile -Value "[allow-all] $(Get-Date -Format 'HH:mm:ss')`n$(Strip-Ansi $reloadOutput)`n---`n" -Encoding UTF8
        Write-Host "    ✓ /allow-all" -ForegroundColor DarkGray

        # /model — set the model (send AFTER reload settles)
        $pty.Write("/model claude-opus-4.6-1m")
        Start-Sleep -Milliseconds 300
        $pty.Write("`r")
        Start-Sleep 5
        $null = Drain-Pty "model"
        Write-Host "    ✓ /model" -ForegroundColor DarkGray

        # Shift+Tab x2 — switch to agent mode (ask → plan → autopilot)
        $pty.Write("`e[Z")
        Start-Sleep 2
        $pty.Write("`e[Z")
        Start-Sleep 3
        $null = Drain-Pty "shift-tab"
        Write-Host "    ✓ autopilot mode" -ForegroundColor DarkGray

        # Send the task prompt — text and Enter SEPARATELY
        # Longer delay before Enter: TUI needs time to process pasted text
        $pty.Write($shortPrompt)
        Start-Sleep 2
        $pty.Write("`r")
        Start-Sleep 5

        # Verify submission — check if copilot started working
        $postSubmit = $pty.Read(8000)
        $postClean = Strip-Ansi $postSubmit
        Add-Content -Path $ptyLogFile -Value "[prompt-response] $(Get-Date -Format 'HH:mm:ss')`n$postClean`n---`n" -Encoding UTF8

        if ($postClean -and ($postClean -match 'report_intent|view|powershell|grep|Reading|Exploring|Fetchi|cancel')) {
            Write-Host "    ✓ prompt submitted — agent is working" -ForegroundColor DarkGray
        } else {
            # Retry Enter
            Write-Host "    ⟳ retrying submit..." -ForegroundColor Yellow
            $pty.Write("`r")
            Start-Sleep 5
            $null = Drain-Pty "retry-submit"
        }

        Write-Host "    PTY log: $ptyLogFile" -ForegroundColor DarkGray

        # ── Poll for completion ───────────────────────────────
        $maxWait = $script:SarmaConfig.ExecutorTimeout
        $waited = 0
        while (-not (Test-Path $doneFile) -and -not $pty.HasExited -and $waited -lt $maxWait) {
            Start-Sleep 5
            $waited += 5
            # Drain PTY output (prevents pipe buffer from filling + shows progress)
            $chunk = $pty.Read(500)
            if ($chunk) {
                $clean = (Strip-Ansi $chunk).Trim()
                # Extract meaningful status lines (tool calls, not TUI noise)
                $lines = $clean -split "`n" | Where-Object {
                    $_ -match '^\s*[◎○∘●✓✗└►▸]' -or $_ -match 'cancel\)' -or $_ -match 'Esc to'
                } | ForEach-Object { $_.Trim() } | Select-Object -First 2
                foreach ($line in $lines) {
                    if ($line.Length -gt 2) {
                        $short = if ($line.Length -gt 90) { $line.Substring(0,90) + "…" } else { $line }
                        Write-Host "    $short" -ForegroundColor DarkGray
                    }
                }
                Add-Content -Path $ptyLogFile -Value "[poll ${waited}s]`n$clean`n---`n" -Encoding UTF8
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
