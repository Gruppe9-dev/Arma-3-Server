# Shared-installation instance helpers. Dot-sourced by Common.ps1.
# Control metadata stays in the framework; SFTP users only edit upload/config data.

function Get-OptionalValue {
    param($Object, [string]$Name, $Default = $null)
    if ($null -ne $Object) {
        $property = $Object.PSObject.Properties[$Name]
        # Optional JSON fields can be present but null, including empty lists
        # written by older importers. Keep explicit false and zero values.
        if ($null -ne $property -and $null -ne $property.Value) { return $property.Value }
    }
    return $Default
}

function Set-ObjectValue {
    param($Object, [string]$Name, $Value)
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function Get-InstanceDataRoot {
    param($Config)
    $path = [string](Get-OptionalValue $Config 'InstanceDataPath' '')
    if (-not $path) { $path = Join-Path (Split-Path -Parent $PSScriptRoot) 'instances' }
    $full = [IO.Path]::GetFullPath($path).TrimEnd('\')
    $shared = [IO.Path]::GetFullPath($Config.ServerInstallPath).TrimEnd('\')
    if ($full -eq $shared -or $full.StartsWith($shared + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $shared.StartsWith($full + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Instance data and the shared installation must be separate, non-overlapping directories.'
    }
    return $full
}

function Assert-ChildPath {
    param([string]$Path, [string]$Root)
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    if (-not $full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside the required directory: $Path"
    }
    return $full
}

function Assert-NoReparsePoint {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $items = @((Get-Item -LiteralPath $Path -Force))
    if ($items[0].Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Reparse points are not allowed in writable instance data: $Path"
    }
    if ($items[0].PSIsContainer) {
        # Do not traverse user-created links, even on PowerShell versions which
        # recurse through junctions. Visit each real directory explicitly.
        foreach ($child in @(Get-ChildItem -LiteralPath $Path -Force)) {
            Assert-NoReparsePoint -Path $child.FullName
        }
    }
    foreach ($item in $items) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Reparse points are not allowed in writable instance data: $($item.FullName)"
        }
    }
}

function Initialize-ProfilePaths {
    param($Profile, [string]$ProfileId, [switch]$IgnorePreset)
    $config = Get-FrameworkConfig
    $root = Split-Path -Parent $PSScriptRoot
    $isolated = (Get-OptionalValue $Profile 'Isolated' $false) -eq $true
    Set-ObjectValue $Profile 'ProfileId' $ProfileId
    Set-ObjectValue $Profile 'Isolated' $isolated
    Set-ObjectValue $Profile 'StateDir' (Join-Path $root ".state\$ProfileId")
    Set-ObjectValue $Profile 'RuntimeProfileDir' $Profile.ProfileDir
    Set-ObjectValue $Profile 'GameDir' $config.ServerInstallPath
    Set-ObjectValue $Profile 'ConfigDir' $Profile.ProfileDir
    Set-ObjectValue $Profile 'MissionDir' (Join-Path $config.ServerInstallPath 'mpmissions')
    if ($isolated) {
        $instanceDir = Assert-ChildPath (Join-Path (Get-InstanceDataRoot $config) $ProfileId) (Get-InstanceDataRoot $config)
        Set-ObjectValue $Profile 'InstanceDir' $instanceDir
        Set-ObjectValue $Profile 'UploadDir' (Join-Path $instanceDir 'files')
        Set-ObjectValue $Profile 'ConfigDir' (Join-Path $instanceDir 'files\profile')
        Set-ObjectValue $Profile 'MissionDir' (Join-Path $instanceDir 'files\mpmissions')
        Set-ObjectValue $Profile 'RuntimeProfileDir' (Join-Path $instanceDir 'runtime\profiles')
        Set-ObjectValue $Profile 'GameDir' (Join-Path $instanceDir 'runtime\game')
        Set-ObjectValue $Profile 'RuntimeConfigDir' (Join-Path $instanceDir 'runtime\config')
        Set-ObjectValue $Profile 'ServerCfg' (Join-Path $Profile.RuntimeConfigDir 'server.cfg')
        Set-ObjectValue $Profile 'BasicCfg' (Join-Path $Profile.RuntimeConfigDir 'basic.cfg')
        Set-ObjectValue $Profile 'LogDir' (Join-Path $Profile.RuntimeProfileDir 'logs')
    }
    $selectionPath = Join-Path $Profile.StateDir 'preset.json'
    $selected = ''
    if (-not $IgnorePreset -and (Test-Path -LiteralPath $selectionPath)) {
        $selected = [string]((Get-Content -LiteralPath $selectionPath -Raw | ConvertFrom-Json).Preset)
    }
    $presets = Get-OptionalValue $Profile 'Presets' ([PSCustomObject]@{})
    if ($selected) {
        if ($selected -cnotmatch '^[a-z0-9][a-z0-9_-]{0,63}$' -or $presets.PSObject.Properties.Name -notcontains $selected) {
            throw "Selected preset '$selected' is no longer approved for '$ProfileId'."
        }
        $preset = $presets.$selected
        foreach ($key in @('Mods', 'ServerMods', 'WorkshopIds', 'HeadlessClientCount', 'FPSLimit', 'EnableAutoInit')) {
            if ($preset.PSObject.Properties.Name -contains $key) { Set-ObjectValue $Profile $key $preset.$key }
        }
    }
    Set-ObjectValue $Profile 'SelectedPreset' $selected
    Assert-ProfileSettings $Profile
}

function Assert-ProfileSettings {
    param($Profile)
    foreach ($bound in @(@('Port',1024,65531), @('HeadlessClientCount',0,16), @('FPSLimit',0,1000))) {
        $value = Get-OptionalValue $Profile $bound[0] 0
        if ($value -isnot [int] -and $value -isnot [long]) { throw "$($bound[0]) must be an integer." }
        if ($value -lt $bound[1] -or $value -gt $bound[2]) { throw "$($bound[0]) is outside its allowed range." }
    }
    if ($Profile.Branch -notin @('public','profiling','development')) { throw 'Invalid server branch.' }
    $profileId = Get-OptionalValue $Profile 'ProfileId' (Get-OptionalValue $Profile 'ProfileName' '<unknown>')
    foreach ($field in @('Mods', 'ServerMods')) {
        $mods = @((Get-OptionalValue $Profile $field @()))
        for ($index = 0; $index -lt $mods.Count; $index++) {
            $mod = $mods[$index]
            if ($mod -isnot [string] -or $mod -notmatch '^@[\w.-]+$' -or $mod -match '\.\.') {
                throw "Invalid mod folder in profile '$profileId', ${field}[$index]: '$mod'. Expected a folder such as '@CBA_A3'; use [] for an empty mod list."
            }
        }
        # Runtime preparation and launch code also read these properties directly.
        Set-ObjectValue $Profile $field $mods
    }
    if ($Profile.Isolated -and @((Get-OptionalValue $Profile 'ExtraArgs' @())).Count -gt 0) {
        throw 'Isolated instances do not accept ExtraArgs. Use the supported profile settings.'
    }
}

function Get-ArmaCommandArguments {
    param([string]$CommandLine)
    if (-not ('Arma3.CommandLineParser' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Arma3 {
    public static class CommandLineParser {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr CommandLineToArgvW(string commandLine, out int argc);
        [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr p);
        public static string[] Parse(string commandLine) {
            int count; IntPtr p = CommandLineToArgvW(commandLine, out count);
            if (p == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
            try {
                string[] result = new string[count];
                for (int i = 0; i < count; i++) result[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(p, i * IntPtr.Size));
                return result;
            } finally { LocalFree(p); }
        }
    }
}
'@
    }
    return [Arma3.CommandLineParser]::Parse($CommandLine)
}

function Test-InstanceProcess {
    param($Process, $Profile)
    if (-not $Process.CommandLine -or -not $Process.ExecutablePath) { return $false }
    $allowed = @('arma3server_x64.exe','arma3serverprofiling_x64.exe','arma3server.exe') |
        ForEach-Object { [IO.Path]::GetFullPath((Join-Path $Profile.GameDir $_)) }
    if ([IO.Path]::GetFullPath($Process.ExecutablePath) -notin $allowed) { return $false }
    $arguments = @(Get-ArmaCommandArguments $Process.CommandLine)
    $profileArgs = @($arguments | Where-Object { $_ -like '-profiles=*' })
    if ($profileArgs.Count -ne 1) { return $false }
    $actual = [IO.Path]::GetFullPath($profileArgs[0].Substring(10)).TrimEnd('\')
    return $actual -eq [IO.Path]::GetFullPath($Profile.RuntimeProfileDir).TrimEnd('\')
}

function Get-InstanceProcesses {
    param($Profile)
    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name LIKE 'arma3server%'" -ErrorAction Stop)) {
        if (Test-InstanceProcess $process $Profile) { $process }
    }
}

function Stop-InstanceProcesses {
    param($Profile, [switch]$HCOnly)
    foreach ($candidate in @(Get-InstanceProcesses $Profile)) {
        $arguments = @(Get-ArmaCommandArguments $candidate.CommandLine)
        if ($HCOnly -and '-client' -notin $arguments) { continue }
        $process = Get-Process -Id $candidate.ProcessId -ErrorAction SilentlyContinue
        if (-not $process) { continue }
        # Acquire a handle before validating identity to prevent PID reuse from
        # redirecting the later kill to a different process.
        $null = $process.Handle
        $current = Get-CimInstance Win32_Process -Filter "ProcessId=$($candidate.ProcessId)" -ErrorAction Stop
        if ($current -and $current.CreationDate -eq $candidate.CreationDate -and (Test-InstanceProcess $current $Profile)) {
            Write-Log "Stopping instance '$($Profile.ProfileId)' process $($candidate.ProcessId)."
            $process.Kill()
            if (-not $process.WaitForExit(15000)) { throw 'A server process did not stop within 15 seconds.' }
        }
    }
}

function Assert-ServersIdle {
    if (@(Get-ServerProcesses).Count -gt 0) { throw 'Shared files cannot be changed while any Arma server or headless client is running.' }
}

function Get-ConfiguredLimit {
    param($Config, [string]$Name, [int]$Default, [int]$Maximum = 64)
    $raw = [string](Get-OptionalValue $Config $Name '')
    if (-not $raw) { return $Default }
    $value = 0
    if (-not [int]::TryParse($raw, [ref]$value) -or $value -lt 0 -or $value -gt $Maximum) { throw "Invalid $Name limit." }
    return $value
}

function Assert-StartCapacity {
    param($Profile, $Config, [int]$HeadlessCount)
    if (@(Get-InstanceProcesses $Profile).Count -gt 0) { throw "Instance '$($Profile.ProfileId)' is already running (or still has headless clients)." }
    $servers = 0; $clients = 0
    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name LIKE 'arma3server%'" -ErrorAction Stop)) {
        if (-not $process.CommandLine) { throw 'Cannot identify a running Arma process. Refusing to start.' }
        if ('-client' -in @(Get-ArmaCommandArguments $process.CommandLine)) { $clients++ } else { $servers++ }
    }
    if ($servers -ge (Get-ConfiguredLimit $Config 'MaxRunningInstances' 2)) { throw 'Maximum running instance count reached.' }
    if ($clients + $HeadlessCount -gt (Get-ConfiguredLimit $Config 'MaxTotalHeadlessClients' 4)) { throw 'Headless client capacity exceeded.' }
    $ports = ([int]$Profile.Port)..([int]$Profile.Port + 4)
    $busy = @(Get-NetUDPEndpoint -ErrorAction Stop | Where-Object { $_.LocalPort -in $ports })
    if ($busy.Count -gt 0) { throw "UDP port block $($Profile.Port)-$([int]$Profile.Port+4) is already in use." }
}

function Add-InstanceJunction {
    param([string]$Path, [string]$Target, [string]$GameRoot)
    $null = Assert-ChildPath $Path $GameRoot
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            [string]$item.Target -ne $Target) { throw "Unexpected existing instance path: $Path" }
        return
    }
    New-Item -ItemType Junction -Path $Path -Target $Target -ErrorAction Stop | Out-Null
}

function Prepare-InstanceRuntime {
    param($Profile, $Config)
    if (-not $Profile.Isolated) {
        $source = Join-Path $Profile.ProfileDir 'userconfig'
        if (Test-Path -LiteralPath $source) {
            # Legacy roots remain compatible, but cannot replace common config
            # while another legacy server is running.
            if (@(Get-ServerProcesses).Count -gt 0) { throw 'Migrate this legacy profile to isolated mode before starting alongside another instance.' }
            Copy-Item -LiteralPath $source -Destination $Config.ServerInstallPath -Recurse -Force
        }
        return
    }
    if (-not (Test-Path -LiteralPath $Profile.ConfigDir)) { throw 'Instance data is missing. Run setup/New-Instance.ps1 first.' }
    Assert-NoReparsePoint $Profile.UploadDir
    foreach ($path in @($Profile.GameDir, $Profile.RuntimeProfileDir, $Profile.RuntimeConfigDir, $Profile.StateDir)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
    $drive = Get-Volume -FilePath $Profile.GameDir -ErrorAction Stop
    if ($drive.FileSystem -ne 'NTFS') { throw 'Isolated runtime views require an NTFS instance data volume. Large shared game/mod data is not copied.' }
    # Only immutable engine content is linked. Mutable game directories belong
    # to the instance, and SteamCMD never runs in this runtime view.
    $excluded = @('mpmissions','missions','userconfig','keys','battleye','profiles','logs','steamapps','steamcmd','!workshop')
    foreach ($dir in @(Get-ChildItem -LiteralPath $Config.ServerInstallPath -Directory)) {
        if ($dir.Name -in $excluded -or $dir.Name.StartsWith('@') -or $dir.Name.StartsWith('.')) { continue }
        Add-InstanceJunction (Join-Path $Profile.GameDir $dir.Name) $dir.FullName $Profile.GameDir
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $Config.ServerInstallPath -File)) {
        if ($file.Extension -in @('.exe','.dll','.manifest') -or $file.Name -in @('steam_appid.txt','appid','.arma3-server-branch')) {
            Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $Profile.GameDir $file.Name) -Force
        }
    }
    # Deploy completed PBO files to private runtime storage. SFTP writes cannot
    # change active mission files or introduce native libraries into the game root.
    $runtimeMissions = Join-Path $Profile.GameDir 'mpmissions'
    New-Item -ItemType Directory -Path $runtimeMissions -Force | Out-Null
    foreach ($old in @(Get-ChildItem -LiteralPath $runtimeMissions -File -Filter '*.pbo')) { Remove-Item -LiteralPath $old.FullName }
    foreach ($mission in @(Get-ChildItem -LiteralPath $Profile.MissionDir -File -Filter '*.pbo')) {
        Copy-LockedInstanceFile $mission.FullName (Join-Path $runtimeMissions $mission.Name)
    }
    foreach ($name in @('server.cfg','basic.cfg')) {
        $source = Join-Path $Profile.ConfigDir $name
        $snapshot = Join-Path $Profile.RuntimeConfigDir $name
        Copy-LockedInstanceFile $source $snapshot -MaxBytes 2MB
        $text = Get-Content -LiteralPath $snapshot -Raw
        if ($text -match '(?im)^\s*#\s*include') { throw 'Use self-contained server.cfg/basic.cfg files; external includes are not supported.' }
    }
    # Absolute mod paths share each mod once without exposing runtime links to SFTP.
    $userconfig = Join-Path $Profile.GameDir 'userconfig'
    $null = Assert-ChildPath $userconfig $Profile.GameDir
    if (Test-Path -LiteralPath $userconfig) {
        Assert-NoReparsePoint $userconfig
        Remove-Item -LiteralPath $userconfig -Recurse -Force
    }
    $sourceConfig = Join-Path $Profile.ConfigDir 'userconfig'
    if (Test-Path -LiteralPath $sourceConfig) {
        foreach ($file in @(Get-ChildItem -LiteralPath $sourceConfig -Recurse -File)) {
            if ($file.Extension -notin @('.sqf','.hpp','.h','.inc','.cfg','.txt')) { throw "Unsupported userconfig file type: $($file.Name)" }
            if ($file.Length -gt 2MB) { throw 'A userconfig file exceeds 2 MiB.' }
            $relative = $file.FullName.Substring($sourceConfig.TrimEnd('\').Length).TrimStart('\')
            $target = Assert-ChildPath (Join-Path $userconfig $relative) $userconfig
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
            Copy-LockedInstanceFile $file.FullName $target -MaxBytes 2MB
        }
    }
    $keys = Join-Path $Profile.GameDir 'keys'
    New-Item -ItemType Directory -Path $keys -Force | Out-Null
    Get-ChildItem -LiteralPath $keys -File -Filter '*.bikey' | Remove-Item -Force
    $baseKeys = Join-Path $Config.ServerInstallPath 'keys'
    if (Test-Path -LiteralPath $baseKeys) {
        Get-ChildItem -LiteralPath $baseKeys -File -Filter 'a3*.bikey' | Copy-Item -Destination $keys
    }
    foreach ($mod in @($Profile.Mods) + @($Profile.ServerMods)) {
        $modPath = Join-Path $Config.ServerInstallPath $mod
        if (-not (Test-Path -LiteralPath $modPath)) { throw "Required mod is missing: $mod" }
        Get-ChildItem -LiteralPath $modPath -Recurse -File -Filter '*.bikey' | Copy-Item -Destination $keys -Force
    }
    $battleye = Join-Path $Config.ServerInstallPath 'battleye'
    if (Test-Path -LiteralPath $battleye) {
        $target = Join-Path $Profile.GameDir 'battleye'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Get-ChildItem -LiteralPath $battleye -File -Filter '*.dll' | Copy-Item -Destination $target -Force
    }
    $difficulty = Join-Path $Profile.ConfigDir "$($Profile.ProfileId).Arma3Profile"
    if (Test-Path -LiteralPath $difficulty) {
        $userDir = Join-Path $Profile.RuntimeProfileDir "Users\$($Profile.ProfileId)"
        New-Item -ItemType Directory -Path $userDir -Force | Out-Null
        Copy-LockedInstanceFile $difficulty (Join-Path $userDir "$($Profile.ProfileId).Arma3Profile") -MaxBytes 2MB
    }
}

function Copy-LockedInstanceFile {
    param([string]$Source, [string]$Destination, [long]$MaxBytes = [long]::MaxValue)
    $inputFile = [IO.File]::Open($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ($inputFile.Length -gt $MaxBytes) { throw "Instance file exceeds the size limit: $Source" }
        $outputFile = [IO.File]::Open($Destination, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $inputFile.CopyTo($outputFile) } finally { $outputFile.Dispose() }
    } finally { $inputFile.Dispose() }
}

function Get-InstanceModString {
    param([string[]]$Mods, $Config)
    $paths = foreach ($mod in $Mods) {
        $path = Join-Path $Config.ServerInstallPath $mod
        if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw "Required mod is missing: $mod" }
        $path
    }
    return $paths -join ';'
}

function Get-ProfileWorkshopEntries {
    param($Profile)
    # Sync every approved preset, not just the currently selected one. Downloads
    # remain an owner action; operators can then select any prepared preset.
    $data = Get-Content -LiteralPath (Join-Path $Profile.ProfileDir 'profile.json') -Raw | ConvertFrom-Json
    Get-DefinitionWorkshopEntries $data
}

function Get-DefinitionWorkshopEntries {
    param($data)
    foreach ($entry in @((Get-OptionalValue $data 'WorkshopIds' @()))) { $entry }
    $presets = Get-OptionalValue $data 'Presets' ([PSCustomObject]@{})
    foreach ($property in $presets.PSObject.Properties) {
        foreach ($entry in @((Get-OptionalValue $property.Value 'WorkshopIds' @()))) { $entry }
    }
}

function Get-SharedWorkshopCatalog {
    param([object[]]$AdditionalEntries = @())
    $byId = @{}; $byFolder = @{}
    $root = Split-Path -Parent $PSScriptRoot
    $entries = @($AdditionalEntries)
    foreach ($name in @(Get-AvailableProfiles)) {
        $data = Get-Content -LiteralPath (Join-Path $root "profiles\$name\profile.json") -Raw | ConvertFrom-Json
        $entries += @(Get-DefinitionWorkshopEntries $data)
    }
    foreach ($entry in $entries) {
        $id = [string]$entry.Id; $folder = [string]$entry.FolderName
        if ($id -notmatch '^\d{1,20}$' -or $folder -notmatch '^@[\w.-]+$' -or $folder -match '\.\.') {
            throw 'Invalid Workshop ID or folder in a shared profile/preset.'
        }
        if (($byId.ContainsKey($id) -and $byId[$id] -ne $folder) -or
            ($byFolder.ContainsKey($folder) -and $byFolder[$folder] -ne $id)) {
            throw "Conflicting shared mod mapping: $id / $folder. Use one folder per Workshop ID across all profiles and presets."
        }
        $byId[$id] = $folder; $byFolder[$folder] = $id
    }
    Write-Output -NoEnumerate $byId
}

function Start-InstanceHeadless {
    param($Profile, $Config, [int]$Index)
    $binary = Join-Path $Profile.GameDir 'arma3server_x64.exe'
    if (-not (Test-Path -LiteralPath $binary)) { throw 'Headless client binary is missing.' }
    $arguments = @('-client', '-connect=127.0.0.1', "-port=$($Profile.Port)",
        "-profiles=`"$($Profile.RuntimeProfileDir)`"", "-name=HC$Index", '-nosound', '-world=empty')
    $mods = Get-InstanceModString @($Profile.Mods) $Config
    if ($mods) { $arguments += "-mod=`"$mods`"" }
    $cfg = Get-Content -LiteralPath $Profile.ServerCfg -Raw
    if ($cfg -match '(?m)^\s*password\s*=\s*"([^"\r\n]*)"\s*;') {
        $password = $Matches[1]
        if ($password.Contains('\')) { throw 'Join passwords containing backslashes are not supported for headless clients.' }
        if ($password) { $arguments += "-password=`"$password`"" }
    }
    return Start-DetachedProcess -FilePath $binary -ArgumentList $arguments -WorkingDirectory $Profile.GameDir
}
