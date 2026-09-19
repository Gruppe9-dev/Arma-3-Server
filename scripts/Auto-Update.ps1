#Requires -Version 5.1
<# .SYNOPSIS
Run idle-only maintenance. Each mutating child holds its own host-wide lock and
rechecks idleness. A start between phases causes the next phase to refuse work.
#>
[CmdletBinding()]
param([switch]$DryRun)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$config = Get-FrameworkConfig
$lock = Enter-FrameworkMaintenanceLock -Config $config -Purpose 'automatic-update-check'
if (-not $lock) { Write-Log 'AUTO_UPDATE_RESULT=skipped_locked'; exit 0 }
try {
    if (@(Get-ServerProcesses).Count -gt 0) { Write-Log 'AUTO_UPDATE_RESULT=skipped_active'; exit 0 }
    if ($DryRun) { Write-Log 'AUTO_UPDATE_RESULT=dry_run'; exit 0 }
} finally { Exit-FrameworkMaintenanceLock -Lock $lock -Config $config }
try {
    if (-not $config.SteamUsername -or -not $config.SteamPassword) { throw 'Automatic Workshop updates require non-interactive Steam credentials.' }
    $root = Split-Path -Parent $PSScriptRoot
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $root 'setup\Update-Server.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Server update failed or was blocked by an active instance.' }
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $root 'mods\Sync-Mods.ps1') -Profile _all -Update
    if ($LASTEXITCODE -ne 0) { throw 'Mod update failed or was blocked by an active instance.' }
    Write-Log 'AUTO_UPDATE_RESULT=complete' 'Success'
} catch {
    Write-Log $_.Exception.Message 'Error'
    Write-Log 'AUTO_UPDATE_RESULT=failed' 'Error'
    exit 1
}
