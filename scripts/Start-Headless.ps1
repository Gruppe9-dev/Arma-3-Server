#Requires -Version 5.1
<#
.SYNOPSIS
    Starts a single Arma 3 Headless Client for the given profile.

.DESCRIPTION
    Launched automatically by Start-Server.ps1 but can also be called manually
    to start an additional HC or restart a crashed one.

.PARAMETER Profile
    Profile name (folder under profiles\).

.PARAMETER HCIndex
    Numeric index for this HC instance (used for the profile name HC1, HC2, ...).
    Default: 1.

.PARAMETER ServerHost
    IP address of the Arma 3 server to connect to. Default: 127.0.0.1.

.PARAMETER PassThru
    Return the started Process object (used by Start-Server.ps1).

.EXAMPLE
    .\Start-Headless.ps1 -Profile main
    .\Start-Headless.ps1 -Profile main -HCIndex 2 -ServerHost 127.0.0.1
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Profile,

    [int]$HCIndex = 1,

    [string]$ServerHost = "127.0.0.1",

    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptRoot "Common.ps1")

$Config = Get-FrameworkConfig
$Prof   = Get-Profile -ProfileName $Profile

$hcName = "HC$HCIndex"

Write-Log "=== Headless Client ${HCIndex}: $Profile ===" "Header"
Write-Log "Server    : $ServerHost`:$($Prof.Port)" "Info"
Write-Log "HC Name   : $hcName" "Info"

# ---------------------------------------------------------------------------
# HC always uses the standard server binary (not profiling binary)
# The profiling binary difference is server-side only
# ---------------------------------------------------------------------------
$binary = Join-Path $Config.ServerInstallPath "arma3server_x64.exe"
if (-not (Test-Path $binary)) {
    Write-Log "arma3server_x64.exe not found at '$binary'." "Error"
    exit 1
}

# ---------------------------------------------------------------------------
# Build mod string (HC must load the same mods as the server)
# ---------------------------------------------------------------------------
$modString = ""
if ($Prof.PSObject.Properties.Name -contains "Mods" -and @($Prof.Mods).Count -gt 0) {
    $modString = Build-ModString -Mods $Prof.Mods -ServerInstallPath $Config.ServerInstallPath
}

# ---------------------------------------------------------------------------
# Read join password from server.cfg
# ---------------------------------------------------------------------------
$joinPassword = ""
if (Test-Path $Prof.ServerCfg) {
    $cfgContent = Get-Content $Prof.ServerCfg -Raw
    if ($cfgContent -match 'password\s*=\s*"([^"]*)"') {
        $joinPassword = $Matches[1]
    }
}

# ---------------------------------------------------------------------------
# Build HC argument list
# HC uses -client instead of acting as a server; NO -serverMod= allowed
# ---------------------------------------------------------------------------
$hcArgs = [System.Collections.Generic.List[string]]::new()

$hcArgs.Add("-client")
$hcArgs.Add("-connect=$ServerHost")
$hcArgs.Add("-port=$($Prof.Port)")
$hcArgs.Add("-profiles=`"$($Prof.ProfileDir)`"")
$hcArgs.Add("-name=$hcName")
$hcArgs.Add("-nosound")
$hcArgs.Add("-world=empty")

if ($joinPassword) {
    $hcArgs.Add("-password=`"$joinPassword`"")
}

if ($modString) {
    $hcArgs.Add("-mod=`"$modString`"")
}

Write-Log "Command: $binary $($hcArgs -join ' ')" "Info"

# ---------------------------------------------------------------------------
# Start HC process
# ---------------------------------------------------------------------------
$proc = Start-Process -FilePath $binary `
                       -ArgumentList ($hcArgs -join " ") `
                       -WorkingDirectory $Config.ServerInstallPath `
                       -PassThru

Write-Log "HC $HCIndex started (PID: $($proc.Id))" "Success"

if ($PassThru) {
    return $proc
}
