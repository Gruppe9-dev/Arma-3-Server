#Requires -Version 5.1
<#
.SYNOPSIS
    Stops the Arma 3 server (and Headless Clients) for the specified profile.

.DESCRIPTION
    Reads the PID file(s) written by Start-Server.ps1 and terminates the
    corresponding processes. Falls back to killing all arma3server* processes
    if -Force is specified or no PID file is found.

.PARAMETER Profile
    Profile name to stop. If omitted, shows a list of running server processes.

.PARAMETER Force
    Kill all arma3server* processes on the machine (regardless of profile).

.PARAMETER HCOnly
    Stop only the Headless Client processes, leave the main server running.

.EXAMPLE
    .\Stop-Server.ps1 -Profile main
    .\Stop-Server.ps1 -Profile main -HCOnly
    .\Stop-Server.ps1 -Force
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Profile,

    [switch]$Force,

    [switch]$HCOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptRoot "Common.ps1")

# ---------------------------------------------------------------------------
# -Force: kill everything
# ---------------------------------------------------------------------------
if ($Force) {
    Write-Log "=== Force Stop: all arma3server* processes ===" "Header"
    $procs = Get-ServerProcesses
    if (-not $procs) {
        Write-Log "No running arma3server processes found." "Info"
        exit 0
    }
    foreach ($p in $procs) {
        Write-Log "Stopping PID $($p.Id)  [$($p.ProcessName)]..." "Info"
        $p | Stop-Process -Force
    }
    Write-Log "Stopped $($procs.Count) process(es)." "Success"
    exit 0
}

# ---------------------------------------------------------------------------
# No profile: list running processes
# ---------------------------------------------------------------------------
if (-not $Profile) {
    $procs = Get-ServerProcesses
    if ($procs) {
        Write-Log "Running arma3server processes:" "Info"
        $procs | ForEach-Object {
            Write-Log "  PID $($_.Id)  started $(($_.StartTime).ToString('HH:mm:ss'))  $($_.ProcessName)" "Info"
        }
        Write-Log "Use: .\Stop-Server.ps1 -Profile <name>  or  -Force to stop all." "Info"
    } else {
        Write-Log "No running arma3server processes found." "Info"
    }
    exit 0
}

# ---------------------------------------------------------------------------
# Profile-specific stop
# ---------------------------------------------------------------------------
$Config = Get-FrameworkConfig
$Prof   = Get-Profile -ProfileName $Profile

Write-Log "=== Stopping Profile: $Profile ===" "Header"

function Stop-ByPidFile {
    param([string]$PidFile, [string]$Label)

    if (-not (Test-Path $PidFile)) {
        Write-Log "$Label PID file not found at '$PidFile'." "Warning"
        return $false
    }

    $pids = Get-Content $PidFile | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }

    if ($pids.Count -eq 0) {
        Write-Log "$Label PID file is empty." "Warning"
        Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
        return $false
    }

    $stopped = 0
    foreach ($procId in $pids) {
        $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
        if ($proc) {
            Write-Log "  Stopping $Label PID $procId [$($proc.ProcessName)]..." "Info"
            $proc | Stop-Process -Force
            $stopped++
        } else {
            Write-Log "  $Label PID $procId is no longer running." "Info"
        }
    }

    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue

    if ($stopped -gt 0) {
        Write-Log "${Label}: stopped $stopped process(es)." "Success"
    }
    return $true
}

# Stop HCs first
$hcPidFile     = Join-Path $Prof.ProfileDir "headless.pids"
Stop-ByPidFile -PidFile $hcPidFile -Label "Headless Clients" | Out-Null

# Stop main server (unless -HCOnly)
if (-not $HCOnly) {
    $serverPidFile = Join-Path $Prof.ProfileDir "server.pid"
    $found = Stop-ByPidFile -PidFile $serverPidFile -Label "Server"

    if (-not $found) {
        # Fallback: try to identify by checking all arma3server processes
        Write-Log "Falling back to process name search..." "Info"
        $procs = Get-ServerProcesses | Where-Object { $_.ProcessName -notlike "*client*" }
        if ($procs) {
            Write-Log "Found $($procs.Count) arma3server process(es). Stopping..." "Warning"
            $procs | Stop-Process -Force
            Write-Log "Stopped." "Success"
        } else {
            Write-Log "No running server processes found for profile '$Profile'." "Info"
        }
    }
}

Write-Log "=== Stop complete ===" "Header"
