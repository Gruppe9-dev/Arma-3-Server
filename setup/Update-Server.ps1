#Requires -Version 5.1
<#
.SYNOPSIS
    Updates the Arma 3 Dedicated Server via SteamCMD. Supports branch switching.

.DESCRIPTION
    Runs SteamCMD app_update for App ID 233780.
    Can switch between branches (public / profiling / development).
    Stops running server processes before updating if -StopFirst is specified.

.PARAMETER Branch
    Target Steam branch. Valid values: "public", "profiling", "development".
    Omit to update on the currently installed branch (SteamCMD remembers the last branch).

.PARAMETER StopFirst
    Stop any running arma3server processes before updating.

.PARAMETER Validate
    Pass the 'validate' flag to SteamCMD (verifies all files, slower but thorough).

.EXAMPLE
    .\Update-Server.ps1
    .\Update-Server.ps1 -Branch profiling
    .\Update-Server.ps1 -Branch public -StopFirst -Validate
#>

[CmdletBinding()]
param(
    [ValidateSet("public", "profiling", "development")]
    [string]$Branch,

    [switch]$StopFirst,
    [switch]$Validate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Load shared utilities and framework config
# ---------------------------------------------------------------------------
$ScriptRoot    = Split-Path -Parent $MyInvocation.MyCommand.Path
$FrameworkRoot = Split-Path -Parent $ScriptRoot
$CommonScript  = Join-Path $FrameworkRoot "scripts\Common.ps1"

if (-not (Test-Path $CommonScript)) {
    Write-Error "Common.ps1 not found at '$CommonScript'."
}
. $CommonScript

$Config = Get-FrameworkConfig

# ---------------------------------------------------------------------------
# Optional: stop running server processes
# ---------------------------------------------------------------------------
if ($StopFirst) {
    Write-Log "Stopping running Arma 3 server processes..." "Info"
    $procs = Get-Process -Name "arma3server*" -ErrorAction SilentlyContinue
    if ($procs) {
        $procs | Stop-Process -Force
        Write-Log "Stopped $($procs.Count) process(es)." "Success"
        Start-Sleep -Seconds 3
    } else {
        Write-Log "No running arma3server processes found." "Info"
    }
}

# ---------------------------------------------------------------------------
# Build SteamCMD arguments
# ---------------------------------------------------------------------------
$steamCmdExe = Join-Path $Config.SteamCMDPath "steamcmd.exe"
if (-not (Test-Path $steamCmdExe)) {
    Write-Log "steamcmd.exe not found at '$steamCmdExe'." "Error"
    Write-Log "Run .\setup\Install-Framework.ps1 first." "Error"
    exit 1
}

# App ID 233780 (Arma 3 Dedicated Server) is a free anonymous download.
$appUpdateCmd = "app_update 233780"
if ($Branch) {
    $appUpdateCmd += " -beta $Branch"
    Write-Log "Branch: $Branch" "Info"
} else {
    Write-Log "Branch: (current / SteamCMD default)" "Info"
}

if ($Validate) {
    $appUpdateCmd += " validate"
    Write-Log "Validate: enabled" "Info"
}

# ---------------------------------------------------------------------------
# Run SteamCMD via script file (handles special chars in password safely)
# ---------------------------------------------------------------------------
Write-Log "Starting server update..." "Info"
Write-Log "Target: $($Config.ServerInstallPath)" "Info"

$exitCode = Invoke-SteamCMD -SteamCMDExe $steamCmdExe `
                              -Anonymous `
                              -Commands @(
                                  "force_install_dir `"$($Config.ServerInstallPath)`""
                                  $appUpdateCmd
                              )

if ($exitCode -ne 0) {
    Write-Log "SteamCMD exited with code $exitCode. Check output above." "Error"
    exit 1
}

Write-Log "Server update complete." "Success"

# ---------------------------------------------------------------------------
# Report installed binary versions
# ---------------------------------------------------------------------------
$binaries = @(
    "arma3server_x64.exe",
    "arma3serverprofiling_x64.exe"
)

Write-Log "" "Info"
Write-Log "Installed binaries:" "Info"
foreach ($bin in $binaries) {
    $binPath = Join-Path $Config.ServerInstallPath $bin
    if (Test-Path $binPath) {
        $ver = (Get-Item $binPath).VersionInfo.FileVersion
        Write-Log "  $bin  (version: $ver)" "Info"
    }
}
