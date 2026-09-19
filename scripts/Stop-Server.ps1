#Requires -Version 5.1
<# .SYNOPSIS
Stop only processes whose executable and profile directory match the instance.
Missing or stale PID files never broaden a profile-specific stop.
#>
[CmdletBinding(SupportsShouldProcess)]
param([string]$Profile, [switch]$Force, [switch]$HCOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
if ($Force -and $Profile) { throw '-Force cannot be combined with a profile.' }
$config = Get-FrameworkConfig
$lock = Enter-FrameworkMaintenanceLock -Config $config -Purpose "stop:$Profile"
if (-not $lock) { throw 'Another start, stop, or maintenance operation is running.' }
try {
    if ($Force) {
        if ($PSCmdlet.ShouldProcess('All Arma server processes', 'Force stop')) { Get-ServerProcesses | Stop-Process -Force }
    } elseif ($Profile) {
        $prof = Get-Profile $Profile
        if ($PSCmdlet.ShouldProcess($Profile, 'Stop instance')) { Stop-InstanceProcesses $prof -HCOnly:$HCOnly }
        Write-Log "Stop complete for '$Profile'. Other instances were not targeted." 'Success'
    } else { Get-ServerProcesses | Select-Object Id, ProcessName }
} finally { Exit-FrameworkMaintenanceLock -Lock $lock -Config $config }
