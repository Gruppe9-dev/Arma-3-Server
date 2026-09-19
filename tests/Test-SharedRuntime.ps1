#Requires -Version 5.1
# Filesystem integration only: copies scripts into a temporary sandbox, creates
# dummy game files, and never launches Arma, SteamCMD, SSH, or Windows accounts.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = Split-Path -Parent $PSScriptRoot
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('arma-runtime-tests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$script:checks=0
function Assert-True { param([bool]$Value,[string]$Message) if (-not $Value) { throw $Message }; $script:checks++ }
function Remove-FixtureNode {
    param([string]$Path)
    $absolute=[IO.Path]::GetFullPath($Path)
    if ($absolute -ne $fixture -and -not $absolute.StartsWith($fixture + '\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup.' }
    $item=Get-Item -LiteralPath $absolute -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { $item.Delete(); return }
    if ($item.PSIsContainer) { foreach ($child in @(Get-ChildItem -LiteralPath $absolute -Force)) { Remove-FixtureNode $child.FullName } }
    Remove-Item -LiteralPath $absolute -Force
}
try {
    # The bot account may use files but not the Storage CIM provider. Neither
    # provisioning nor runtime preparation may depend on Get-Volume access.
    function Get-Volume { throw 'Storage CIM access denied (fixture).' }
    foreach ($name in @('scripts','setup','mods')) { Copy-Item -LiteralPath (Join-Path $repo $name) -Destination $fixture -Recurse }
    New-Item -ItemType Directory -Path (Join-Path $fixture 'profiles') | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo 'profiles\_template') -Destination (Join-Path $fixture 'profiles') -Recurse
    $engine=Join-Path $fixture 'shared'
    foreach ($dir in @('addons','dta','keys','@CBA_A3\keys','mpmissions')) { New-Item -ItemType Directory -Path (Join-Path $engine $dir) -Force | Out-Null }
    foreach ($file in @('arma3server_x64.exe','addons\fixture.pbo','@CBA_A3\keys\cba.bikey','keys\a3.bikey','mpmissions\main-only.Altis.pbo')) { Set-Content -LiteralPath (Join-Path $engine $file) -Value 'fixture data' }
    Set-Content -LiteralPath (Join-Path $engine '.arma3-server-branch') -Value 'public'
    @("SERVER_INSTALL_PATH=$engine", "STEAMCMD_PATH=$fixture\steamcmd", "WORKSHOP_STAGING_PATH=$fixture\workshop", "INSTANCE_DATA_PATH=$fixture\instances") |
        Set-Content -LiteralPath (Join-Path $fixture '.env')
    # Provisioning checks every existing profile for port conflicts. Null lists
    # in an unrelated legacy profile must not prevent a new instance being made.
    $emptyProfile=Join-Path $fixture 'profiles\empty'
    Copy-Item -LiteralPath (Join-Path $fixture 'profiles\_template') -Destination $emptyProfile -Recurse
    $emptyDefinitionPath=Join-Path $emptyProfile 'profile.json'
    $emptyDefinition=Get-Content -LiteralPath $emptyDefinitionPath -Raw | ConvertFrom-Json
    $emptyDefinition.Port=2602
    $emptyDefinition.Mods=$null; $emptyDefinition.ServerMods=$null; $emptyDefinition.ExtraArgs=$null
    $emptyDefinition | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $emptyDefinitionPath
    & (Join-Path $fixture 'setup\New-Instance.ps1') -Profile 60th -Port 2502
    & (Join-Path $fixture 'setup\New-Instance.ps1') -Profile friend -Port 2402
    . (Join-Path $fixture 'scripts\Common.ps1')
    $config=Get-FrameworkConfig
    $newProfile=Get-Profile 60th
    Assert-True ($newProfile.Port -eq 2502 -and $newProfile.Isolated -eq $true) 'An existing profile with null lists blocked instance provisioning.'
    $loadedEmpty=Get-Profile empty
    Assert-True ($loadedEmpty.Mods.Count -eq 0 -and $loadedEmpty.ServerMods.Count -eq 0) 'Loading the legacy profile did not normalize empty mod lists.'
    $prof=Get-Profile friend
    Assert-True ((Get-PathFileSystem $prof.RuntimeProfileDir) -eq 'NTFS') 'The native filesystem query failed for the fixture volume.'
    $volumeLink=Join-Path $fixture 'volume link #'
    New-Item -ItemType Junction -Path $volumeLink -Target $repo | Out-Null
    Assert-True ((Get-PathFileSystem (Join-Path $volumeLink 'profiles')) -eq (Get-PathFileSystem (Join-Path $repo 'profiles'))) 'The native filesystem query did not follow the junction target volume.'
    $nativeVolumeQuery=${function:Get-PathFileSystem}
    try {
        function Get-PathFileSystem { param($Path) return 'ReFS' }
        $volumeError=''
        try { Prepare-InstanceRuntime $prof $config } catch { $volumeError=$_.Exception.Message }
        Assert-True ($volumeError -like '*require an NTFS*') 'Runtime preparation accepted a non-NTFS volume.'
    } finally { Set-Item Function:\Get-PathFileSystem $nativeVolumeQuery }
    Set-Content -LiteralPath (Join-Path $prof.MissionDir 'friend-only.Altis.pbo') -Value 'friend mission'
    Prepare-InstanceRuntime $prof $config
    $addonLink=Get-Item -LiteralPath (Join-Path $prof.GameDir 'addons') -Force
    Assert-True ([bool]($addonLink.Attributes -band [IO.FileAttributes]::ReparsePoint)) 'Engine addons were copied instead of linked.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $prof.GameDir 'addons\fixture.pbo')) -eq 'fixture data') 'Shared engine link is broken.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $prof.GameDir '@CBA_A3'))) 'Shared mod was copied into the instance.'
    Assert-True (Test-Path -LiteralPath (Join-Path $prof.GameDir 'mpmissions\friend-only.Altis.pbo')) 'Own mission was not deployed.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $prof.GameDir 'mpmissions\main-only.Altis.pbo'))) 'Foreign mission leaked into the instance.'
    Assert-True (Test-Path -LiteralPath (Join-Path $prof.GameDir 'keys\cba.bikey')) 'Approved mod key is missing.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $engine 'userconfig'))) 'Global userconfig was modified.'
    Assert-True (Test-Path -LiteralPath (Join-Path $prof.RuntimeProfileDir 'Users\friend\friend.Arma3Profile')) 'Difficulty settings were not deployed to the named Arma user directory.'
    $save=Join-Path $prof.RuntimeProfileDir 'Users\friend\friend.vars.Arma3Profile'
    Set-Content -LiteralPath $save -Value 'persistent fixture'
    $original=Get-Content -LiteralPath $prof.ServerCfg -Raw
    Add-Content -LiteralPath (Join-Path $prof.ConfigDir 'server.cfg') -Value '// upload changed after deployment'
    Assert-True ((Get-Content -LiteralPath $prof.ServerCfg -Raw) -eq $original) 'A live SFTP edit changed the runtime configuration.'
    Prepare-InstanceRuntime $prof $config
    Assert-True ((Get-Content -LiteralPath $prof.ServerCfg -Raw) -ne $original) 'The next deployment did not apply new settings.'
    Assert-True ((Get-Content -LiteralPath $save) -eq 'persistent fixture') 'A restart deployment replaced mission saves.'

    # Imports must preserve isolation/preset metadata and must not force GRP9 mods.
    $definitionPath=Join-Path $fixture 'profiles\friend\profile.json'
    $definition=Get-Content -LiteralPath $definitionPath -Raw | ConvertFrom-Json
    $definition | Add-Member NoteProperty Presets ([PSCustomObject]@{ training=[PSCustomObject]@{ Mods=@('@CBA_A3'); ServerMods=@(); WorkshopIds=@() } })
    $definition | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $definitionPath
    $html=Join-Path $fixture 'single.html'
    '<html><table><tr data-type="ModContainer"><td data-type="DisplayName">CBA A3</td><td><a data-type="Link">https://steamcommunity.com/sharedfiles/filedetails/?id=450814997</a></td></tr></table></html>' | Set-Content -LiteralPath $html
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $fixture 'mods\Import-Preset.ps1') -Profile friend -PresetFile $html
    Assert-True ($LASTEXITCODE -eq 0) 'Preset import failed.'
    $updated=Get-Content -LiteralPath $definitionPath -Raw | ConvertFrom-Json
    Assert-True ($updated.Isolated -eq $true -and $updated.Presets.PSObject.Properties.Name -contains 'training') 'Preset import discarded control metadata.'
    Assert-True ('@grp9_stats_server' -notin $updated.ServerMods) 'A foreign community received an unrequested stats extension.'

    $collision=$false
    try { $null=Get-SharedWorkshopCatalog -AdditionalEntries @([PSCustomObject]@{ Id='123456'; FolderName='@CBA_A3' }) } catch { $collision=$true }
    Assert-True $collision 'A different Workshop ID could overwrite a shared mod folder.'
    $collision=$false
    try { $null=Get-SharedWorkshopCatalog -AdditionalEntries @([PSCustomObject]@{ Id='450814997'; FolderName='@renamed_cba' }) } catch { $collision=$true }
    Assert-True $collision 'Duplicate shared downloads under different folder names were accepted.'

    # Migration preserves the actual Arma Users tree and its active difficulty.
    $legacy=Join-Path $fixture 'profiles\main'
    Copy-Item -LiteralPath (Join-Path $fixture 'profiles\_template') -Destination $legacy -Recurse
    $legacyUser=Join-Path $legacy 'Users\main'
    New-Item -ItemType Directory -Path $legacyUser -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $legacyUser 'main.vars.Arma3Profile') -Value 'legacy mission save'
    Set-Content -LiteralPath (Join-Path $legacyUser 'main.Arma3Profile') -Value 'legacy difficulty'
    & (Join-Path $fixture 'setup\New-Instance.ps1') -Profile main -MigrateExisting -CopyMissions
    $migrated=Get-Profile main
    Assert-True ((Get-Content -LiteralPath (Join-Path $migrated.RuntimeProfileDir 'Users\main\main.vars.Arma3Profile')) -eq 'legacy mission save') 'Migration lost an existing named-profile save.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $migrated.ConfigDir 'main.Arma3Profile')) -eq 'legacy difficulty') 'Migration replaced active difficulty with a stale template.'
    Assert-True (Test-Path -LiteralPath (Join-Path $migrated.MissionDir 'main-only.Altis.pbo')) 'Requested legacy mission migration failed.'
    $mainDefinitionPath=Join-Path $legacy 'profile.json'
    $mainDefinition=Get-Content -LiteralPath $mainDefinitionPath -Raw | ConvertFrom-Json
    $mainDefinition.WorkshopIds[0].Id='123456'
    $mainDefinition | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $mainDefinitionPath
    # No SteamCMD exists in this fixture. Collision rejection must precede any
    # update/download preparation, even when only the friend profile is selected.
    $syncCommand=Join-Path $fixture 'mods\Sync-Mods.ps1'
    $previousPreference=$ErrorActionPreference
    $ErrorActionPreference='Continue'
    $syncOutput=@(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $syncCommand -Profile friend -Force 2>&1)
    $syncCode=$LASTEXITCODE
    $ErrorActionPreference=$previousPreference
    Assert-True ($syncCode -ne 0 -and ($syncOutput -join "`n") -match 'Conflicting shared mod mapping') 'Concrete-profile sync did not reject a cross-profile collision before deployment.'
    Write-Host "Passed $script:checks shared-runtime filesystem checks. No game processes were started."
} finally { Remove-FixtureNode $fixture }
