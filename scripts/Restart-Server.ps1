#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Profile)
$ErrorActionPreference = 'Stop'
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Stop-Server.ps1') -Profile $Profile
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Start-Server.ps1') -Profile $Profile
exit $LASTEXITCODE
