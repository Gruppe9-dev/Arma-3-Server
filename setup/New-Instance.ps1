#Requires -Version 5.1
<# .SYNOPSIS
Create an isolated instance sharing the existing engine and mods. Does not
download Arma, start a server, create a Windows account, or modify the firewall.
Use -MigrateExisting only with a stopped existing profile; its source files remain.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9_-]{0,63}$')][string]$Profile,
    [ValidateRange(1024,65531)][int]$Port = 2402,
    [ValidatePattern('^(?:_template|[a-z0-9][a-z0-9_-]{0,63})$')][string]$SourceProfile = '_template',
    [switch]$MigrateExisting,
    [switch]$CopyMissions,
    [string]$BotUser = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts\Common.ps1')
$config = Get-FrameworkConfig
$control = Join-Path $root "profiles\$Profile"
$source = if ($MigrateExisting) { $control } else { Join-Path $root "profiles\$SourceProfile" }
$sourceJson = Join-Path $source 'profile.json'
if (-not (Test-Path -LiteralPath $sourceJson)) { throw 'Source profile does not exist.' }
if ((Test-Path -LiteralPath $control) -and -not $MigrateExisting) { throw 'Profile already exists. Choose another ID or explicitly migrate it.' }
$dataRoot = Get-InstanceDataRoot $config
$instanceDir = Assert-ChildPath (Join-Path $dataRoot $Profile) $dataRoot
if (Test-Path -LiteralPath $instanceDir) { throw 'Instance data already exists. Refusing to overwrite it.' }
$definition = Get-Content -LiteralPath $sourceJson -Raw | ConvertFrom-Json
if ($MigrateExisting) { $Port = [int]$definition.Port }
foreach ($name in @(Get-AvailableProfiles)) {
    if ($name -eq $Profile) { continue }
    $other = Get-Profile $name
    if ($Port -le ([int]$other.Port + 4) -and ($Port + 4) -ge [int]$other.Port) { throw "Port block overlaps profile '$name'." }
}
if (@((Get-OptionalValue $definition 'ExtraArgs' @())).Count -gt 0) { throw 'Remove unsupported ExtraArgs before migration.' }
if (-not $PSCmdlet.ShouldProcess($Profile, "Create isolated data at $instanceDir using shared game files")) { return }
$lock = Enter-FrameworkMaintenanceLock $config "provision:$Profile"
if (-not $lock) { throw 'Another framework operation is running.' }
try {
    Assert-ServersIdle
    if (Test-Path -LiteralPath $instanceDir) { throw 'Instance data was created by another operation. Refusing to overwrite it.' }
    if (-not $MigrateExisting -and (Test-Path -LiteralPath $control)) { throw 'Profile was created by another operation. Refusing to overwrite it.' }
    foreach ($name in @(Get-AvailableProfiles)) {
        if ($name -eq $Profile) { continue }
        $other = Get-Profile $name
        if ($Port -le ([int]$other.Port + 4) -and ($Port + 4) -ge [int]$other.Port) { throw "Port block overlaps profile '$name'." }
    }
    New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
    if ((Get-PathFileSystem $dataRoot) -ne 'NTFS') { throw 'INSTANCE_DATA_PATH must be on NTFS.' }
    if ($MigrateExisting) {
        $backupDir = Join-Path $root ".state\$Profile\migration"
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        Copy-Item -LiteralPath $sourceJson -Destination (Join-Path $backupDir ('profile-' + (Get-Date -Format 'yyyyMMddHHmmss') + '.json'))
    }
    $editable = Join-Path $instanceDir 'files\profile'
    $missions = Join-Path $instanceDir 'files\mpmissions'
    $runtimeProfiles = Join-Path $instanceDir 'runtime\profiles'
    foreach ($path in @($editable,$missions,$runtimeProfiles,$control)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    foreach ($name in @('server.cfg','basic.cfg','userconfig')) {
        $path = Join-Path $source $name
        if (Test-Path -LiteralPath $path) {
            Assert-NoReparsePoint $path
            Copy-Item -LiteralPath $path -Destination $editable -Recurse
        }
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $source -File -Filter '*.Arma3Profile')) {
        if ($file.Name -notlike '*.vars.Arma3Profile') {
            Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $editable "$Profile.Arma3Profile")
        }
    }
    # Arma writes named profiles and persistent saves under -profiles/Users/name.
    # Preserve the actual legacy user tree, not only flat template files.
    $sourceUsers = Join-Path $source 'Users'
    if ($MigrateExisting -and (Test-Path -LiteralPath $sourceUsers)) {
        Assert-NoReparsePoint $sourceUsers
        Copy-Item -LiteralPath $sourceUsers -Destination $runtimeProfiles -Recurse
    }
    $sourceName = if ($MigrateExisting) { $Profile } else { $SourceProfile }
    $sourceDifficulty = Join-Path $source "Users\$sourceName\$sourceName.Arma3Profile"
    if (Test-Path -LiteralPath $sourceDifficulty) {
        Copy-Item -LiteralPath $sourceDifficulty -Destination (Join-Path $editable "$Profile.Arma3Profile") -Force
    }
    if ($MigrateExisting) {
        foreach ($save in @(Get-ChildItem -LiteralPath $source -File -Filter '*.vars.Arma3Profile')) {
            Copy-Item -LiteralPath $save.FullName -Destination $runtimeProfiles
        }
    }
    if ($CopyMissions) {
        $sharedMissions = Join-Path $config.ServerInstallPath 'mpmissions'
        Assert-NoReparsePoint $sharedMissions
        if (Test-Path -LiteralPath $sharedMissions) {
            Get-ChildItem -LiteralPath $sharedMissions | Copy-Item -Destination $missions -Recurse
        }
    }
    Set-ObjectValue $definition 'ProfileName' $Profile
    Set-ObjectValue $definition 'Port' $Port
    Set-ObjectValue $definition 'Isolated' $true
    Set-ObjectValue $definition 'ExtraArgs' @()
    if (-not $MigrateExisting -and $SourceProfile -eq '_template') {
        # Community-specific server extensions are an operator choice.
        Set-ObjectValue $definition 'ServerMods' @()
        $marker = Join-Path $config.ServerInstallPath '.arma3-server-branch'
        if (Test-Path -LiteralPath $marker) { Set-ObjectValue $definition 'Branch' (Get-Content -LiteralPath $marker -Raw).Trim() }
    }
    $targetJson = Join-Path $control 'profile.json'
    $definition | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath "$targetJson.tmp" -Encoding UTF8
    Move-Item -LiteralPath "$targetJson.tmp" -Destination $targetJson -Force
    if ($BotUser) {
        $account = Get-LocalUser -Name $BotUser -ErrorAction Stop
        & icacls.exe $instanceDir /grant:r "*$($account.SID.Value):(OI)(CI)M" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Could not grant bot access to instance runtime data.' }
    }
    Write-Log "Created instance '$Profile'. SFTP data: $($instanceDir)\files" 'Success'
    Write-Log 'Review server.cfg passwords, approved mods, and Discord access before starting.'
} finally { Exit-FrameworkMaintenanceLock $lock $config }
