#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Profile, [Parameter(Mandatory)][string]$Preset)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
if ($Preset -cnotmatch '^[a-z0-9][a-z0-9_-]{0,63}$') { throw 'Invalid preset ID.' }
$config = Get-FrameworkConfig
$lock = Enter-FrameworkMaintenanceLock -Config $config -Purpose "preset:$Profile"
if (-not $lock) { throw 'Another framework operation is running.' }
try {
    $prof = Get-Profile $Profile -IgnorePreset
    if (@(Get-InstanceProcesses $prof).Count -gt 0) { throw 'Stop this instance before selecting a preset.' }
    $presets = Get-OptionalValue $prof 'Presets' ([PSCustomObject]@{})
    if ($Preset -ne 'default' -and $presets.PSObject.Properties.Name -notcontains $Preset) { throw 'This preset is not approved for the instance.' }
    New-Item -ItemType Directory -Path $prof.StateDir -Force | Out-Null
    $path = Join-Path $prof.StateDir 'preset.json'
    $selected = if ($Preset -eq 'default') { '' } else { $Preset }
    @{ Preset = $selected } | ConvertTo-Json | Set-Content -LiteralPath "$path.tmp" -Encoding UTF8
    Move-Item -LiteralPath "$path.tmp" -Destination $path -Force
    Write-Log "Selected preset '$Preset' for '$Profile'." 'Success'
} finally { Exit-FrameworkMaintenanceLock -Lock $lock -Config $config }
