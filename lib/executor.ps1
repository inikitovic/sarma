# lib\executor.ps1 — Copilot CLI subprocess wrapper

function Invoke-CopilotAgent {
    <#
    .SYNOPSIS
        Run the Copilot CLI agent with a prompt in a working directory.
    .PARAMETER Live
        If set, streams output directly to terminal instead of capturing.
    #>
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string]$WorkDir,
        [switch]$Live
    )

    $cmd = $script:SarmaConfig.CopilotCliCmd
    $timeout = $script:SarmaConfig.ExecutorTimeout

    if ($Live) {
        # Stream directly to terminal
        $proc = Start-Process -FilePath $cmd -ArgumentList "--prompt", "`"$Prompt`"" `
            -WorkingDirectory $WorkDir -NoNewWindow -Wait -PassThru
        return [PSCustomObject]@{
            ExitCode = $proc.ExitCode
            Stdout   = "(live output — see terminal)"
            Stderr   = ""
            Success  = ($proc.ExitCode -eq 0)
        }
    } else {
        # Capture output
        $stdoutFile = [System.IO.Path]::GetTempFileName()
        $stderrFile = [System.IO.Path]::GetTempFileName()

        try {
            $proc = Start-Process -FilePath $cmd -ArgumentList "--prompt", "`"$Prompt`"" `
                -WorkingDirectory $WorkDir -NoNewWindow -Wait -PassThru `
                -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile

            $stdout = Get-Content $stdoutFile -Raw -ErrorAction SilentlyContinue
            $stderr = Get-Content $stderrFile -Raw -ErrorAction SilentlyContinue

            return [PSCustomObject]@{
                ExitCode = $proc.ExitCode
                Stdout   = if ($stdout) { $stdout } else { "" }
                Stderr   = if ($stderr) { $stderr } else { "" }
                Success  = ($proc.ExitCode -eq 0)
            }
        } finally {
            Remove-Item $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
        }
    }
}
