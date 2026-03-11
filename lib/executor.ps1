# lib\executor.ps1 — Launch agency copilot interactively via Win32 + SendKeys

# Win32 API for reliable window focus
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32Focus {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    public const int SW_RESTORE = 9;

    public static bool FocusWindow(IntPtr hWnd) {
        ShowWindow(hWnd, SW_RESTORE);
        return SetForegroundWindow(hWnd);
    }
}
"@ -ErrorAction SilentlyContinue

function Focus-AgentWindow {
    param([System.Diagnostics.Process]$Process)
    for ($retry = 0; $retry -lt 10; $retry++) {
        try {
            $Process.Refresh()
            $hwnd = $Process.MainWindowHandle
            if ($hwnd -ne [IntPtr]::Zero) {
                if ([Win32Focus]::FocusWindow($hwnd)) {
                    Start-Sleep -Milliseconds 300
                    return $true
                }
            }
        } catch {}
        Start-Sleep 1
    }
    return $false
}

function Send-ToAgent {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$Keys,
        [int]$PostDelay = 1
    )
    $wshell = New-Object -ComObject WScript.Shell
    $null = Focus-AgentWindow -Process $Process
    Start-Sleep -Milliseconds 200
    $wshell.SendKeys($Keys)
    Start-Sleep $PostDelay
}

function Invoke-CopilotAgent {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string]$WorkDir
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

    # Write task file
    $taskFile = Join-Path $WorkDir ".sarma-task.md"
    $Prompt | Set-Content -Path $taskFile -Encoding UTF8

    $shortPrompt = "Read the file .sarma-task.md in the current directory and complete all the work described in it. Follow every instruction exactly."
    $safePrompt = $shortPrompt -replace '([+^%~{}[\]()])', '{$1}'

    Write-Host "    --- launching agency copilot ---" -ForegroundColor DarkCyan
    $startTime = Get-Date

    # Pre-authenticate Azure tokens
    Write-Host "    Pre-authenticating Azure tokens..." -ForegroundColor DarkGray
    $null = az account get-access-token --resource "https://management.azure.com" 2>&1
    $null = az account get-access-token --resource "https://storage.azure.com" 2>&1
    $null = az account get-access-token --resource "499b84ac-1321-427f-aa17-267ca6975798" 2>&1

    # Launch agency copilot in a new window
    $escapedWorkDir = $WorkDir -replace "'", "''"
    $proc = Start-Process pwsh -ArgumentList '-NoExit', '-Command', `
        "Set-Location '$escapedWorkDir'; agency copilot" `
        -PassThru

    # Wait for copilot to fully load
    Write-Host "    Waiting for copilot to load..." -ForegroundColor DarkGray
    $agencyLogDir = "$env:USERPROFILE\.agency\logs"
    $preSessionCount = (Get-ChildItem $agencyLogDir -Directory -ErrorAction SilentlyContinue).Count
    $bootWait = 0
    while ($bootWait -lt 90) {
        Start-Sleep 3
        $bootWait += 3
        $currentCount = (Get-ChildItem $agencyLogDir -Directory -ErrorAction SilentlyContinue).Count
        if ($currentCount -gt $preSessionCount) {
            Write-Host "    Session detected - waiting for MCP servers..." -ForegroundColor DarkGray
            Start-Sleep 30
            break
        }
    }
    Write-Host "    Copilot ready (${bootWait}s)" -ForegroundColor DarkGray

    # Send commands — each call re-focuses the window via Win32 API
    Write-Host "    Sending commands..." -ForegroundColor DarkGray

    # 1. Set model
    Send-ToAgent -Process $proc -Keys "/model claude-opus-4.6-1m" -PostDelay 1
    Send-ToAgent -Process $proc -Keys "{ENTER}" -PostDelay 2

    # 2. Switch to autopilot mode (two Shift+Tabs)
    Send-ToAgent -Process $proc -Keys "+{TAB}" -PostDelay 1
    Send-ToAgent -Process $proc -Keys "+{TAB}" -PostDelay 2

    # 3. Permissions dialog appears — option 1 (Enable all) is pre-selected, just Enter
    Send-ToAgent -Process $proc -Keys "{ENTER}" -PostDelay 2

    # 4. Type prompt and submit
    Send-ToAgent -Process $proc -Keys $safePrompt -PostDelay 1
    Send-ToAgent -Process $proc -Keys "{ENTER}" -PostDelay 1

    Write-Host "    Prompt sent - agent is working..." -ForegroundColor DarkGray

    # Poll for .sarma-done
    $doneFile = Join-Path $WorkDir ".sarma-done"
    $maxWait = $script:SarmaConfig.ExecutorTimeout
    $agentCompleted = $false

    Write-Host "    Waiting for agent to complete (polling .sarma-done)..." -ForegroundColor DarkGray
    $waited = 0
    while (-not (Test-Path $doneFile) -and -not $proc.HasExited -and $waited -lt $maxWait) {
        Start-Sleep 5
        $waited += 5
    }

    if (Test-Path $doneFile) {
        $agentCompleted = $true
        Write-Host "    Agent completed - shutting down session..." -ForegroundColor Green
        Remove-Item $doneFile -Force -ErrorAction SilentlyContinue
        Start-Sleep 2
        Send-ToAgent -Process $proc -Keys "^c" -PostDelay 2
        Send-ToAgent -Process $proc -Keys "^c" -PostDelay 3
    } elseif ($waited -ge $maxWait) {
        Write-Host "    Timeout - killing agent session..." -ForegroundColor Yellow
        Send-ToAgent -Process $proc -Keys "^c" -PostDelay 2
        Send-ToAgent -Process $proc -Keys "^c" -PostDelay 3
    }

    # Wait for exit
    if (-not $proc.HasExited) {
        $proc.WaitForExit(10000) | Out-Null
        if (-not $proc.HasExited) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        }
    }

    $duration = [Math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)

    # Extract resume session ID from agency logs
    $sessionId = ""
    $latestSession = Get-ChildItem $agencyLogDir -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latestSession) {
        foreach ($f in (Get-ChildItem $latestSession.FullName -File -ErrorAction SilentlyContinue)) {
            $content = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
            if ($content -match '--resume=([a-f0-9\-]+)') {
                $sessionId = $Matches[1]
                break
            }
        }
    }

    Write-Host "    --- session ended (${duration}s) ---" -ForegroundColor DarkCyan
    if ($sessionId) {
        Write-Host "    Resume: copilot --resume=$sessionId" -ForegroundColor Cyan
    }

    Remove-Item $taskFile -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $WorkDir ".sarma-done") -Force -ErrorAction SilentlyContinue

    return [PSCustomObject]@{
        ExitCode  = $proc.ExitCode
        Stdout    = "Agent session: ${duration}s"
        Stderr    = ""
        Success   = $agentCompleted
        SessionId = $sessionId
    }
}
