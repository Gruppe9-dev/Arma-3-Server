#Requires -Version 5.1
# Offline tests: temporary fixtures, fake process records, no Arma/Steam/SSH jobs.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\Common.ps1')
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('arma-instance-tests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$script:checks = 0
function Assert-True { param([bool]$Value,[string]$Message) if (-not $Value) { throw $Message }; $script:checks++ }
function Assert-Throws { param([scriptblock]$Action,[string]$Message) $threw=$false; try { & $Action } catch { $threw=$true }; Assert-True $threw $Message }
try {
    $profile = [PSCustomObject]@{ ProfileId='friend'; GameDir='C:\Arma\friend\game'; RuntimeProfileDir='C:\Arma\friend\profiles'; Port=2402; Branch='public'; Isolated=$true; HeadlessClientCount=1; FPSLimit=50; Mods=@('@cba'); ServerMods=@(); ExtraArgs=@() }
    $own = [PSCustomObject]@{ ProcessId=99123; ExecutablePath='C:\Arma\friend\game\arma3server_x64.exe'; CommandLine='arma3server_x64.exe -port=2402 -profiles="C:\Arma\friend\profiles"'; CreationDate=[DateTime]::Now }
    Assert-True (Test-InstanceProcess $own $profile) 'Own instance was not recognized.'
    foreach ($bad in @('C:\Arma\friend\profiles_other','C:\Arma\main\profiles')) {
        $other = $own.PSObject.Copy(); $other.CommandLine = "arma3server_x64.exe -profiles=`"$bad`""
        Assert-True (-not (Test-InstanceProcess $other $profile)) 'A foreign or prefix-matching profile was accepted.'
    }
    $other = $own.PSObject.Copy(); $other.ExecutablePath='C:\Arma\main\game\arma3server_x64.exe'
    Assert-True (-not (Test-InstanceProcess $other $profile)) 'A foreign executable was accepted.'
    $other = $own.PSObject.Copy(); $other.CommandLine += ' -profiles="C:\Arma\friend\profiles"'
    Assert-True (-not (Test-InstanceProcess $other $profile)) 'Ambiguous profile flags were accepted.'
    Assert-ProfileSettings $profile
    # Older JSON writers can serialize an empty optional list as null. Loading
    # must normalize it before launch/runtime code consumes the properties.
    foreach ($field in @('Mods', 'ServerMods')) {
        foreach ($case in @(
            @{ Json='{}'; Expected=@() },
            @{ Json=('{"' + $field + '":null}'); Expected=@() },
            @{ Json=('{"' + $field + '":[]}'); Expected=@() },
            @{ Json=('{"' + $field + '":["@cba"]}'); Expected=@('@cba') },
            @{ Json=('{"' + $field + '":["@cba","@ace"]}'); Expected=@('@cba','@ace') }
        )) {
            $candidate = $profile.PSObject.Copy()
            $candidate.PSObject.Properties.Remove($field)
            $data = $case.Json | ConvertFrom-Json
            foreach ($property in $data.PSObject.Properties) { Set-ObjectValue $candidate $property.Name $property.Value }
            Assert-ProfileSettings $candidate
            Assert-True ($candidate.$field -is [array]) "$field was not normalized to an array for $($case.Json)."
            Assert-True (($candidate.$field.Count -eq $case.Expected.Count) -and (($candidate.$field -join ';') -eq ($case.Expected -join ';'))) "$field changed the configured mod list for $($case.Json)."
        }
        foreach ($badJson in @('""', '[""]', '[null]', '["@cba"," "]', '["@cba","@../main"]')) {
            $candidate = $profile.PSObject.Copy()
            $data = ('{"' + $field + '":' + $badJson + '}') | ConvertFrom-Json
            Set-ObjectValue $candidate $field $data.$field
            $validationError = ''
            try { Assert-ProfileSettings $candidate } catch { $validationError = $_.Exception.Message }
            Assert-True ($validationError -match "profile 'friend'.*$field\[\d+\]") "Invalid $field entry was accepted or its error did not identify the profile and field: $badJson"
        }
    }
    $candidate = $profile.PSObject.Copy(); $candidate.ExtraArgs=$null
    Assert-ProfileSettings $candidate
    Assert-True (@((Get-OptionalValue $candidate 'ExtraArgs' @())).Count -eq 0) 'Null ExtraArgs was treated as an argument.'
    Assert-True ((Get-OptionalValue ([PSCustomObject]@{ Enabled=$false }) 'Enabled' $true) -eq $false) 'An explicit false value was replaced by the default.'
    Assert-True ((Get-OptionalValue ([PSCustomObject]@{ Limit=0 }) 'Limit' 50) -eq 0) 'An explicit zero value was replaced by the default.'
    $invalid = $profile.PSObject.Copy(); $invalid.ExtraArgs=@('-profiles=C:\Arma\main')
    Assert-Throws { Assert-ProfileSettings $invalid } 'ExtraArgs escaped instance control.'
    $invalid = $profile.PSObject.Copy(); $invalid.Mods=@('..\main')
    Assert-Throws { Assert-ProfileSettings $invalid } 'A mod path traversal was accepted.'
    Assert-Throws { Assert-ChildPath 'C:\outside\data' 'C:\Arma' } 'Path confinement failed.'

    $config = [PSCustomObject]@{ WorkshopStagingPath=(Join-Path $fixture 'staging') }
    $first = Enter-FrameworkMaintenanceLock $config 'test-owner'
    Assert-True ($null -ne $first) 'First lock failed.'
    Assert-True ($first -is [IO.FileStream]) 'The lock handle was wrapped in a collection and cannot be released.'
    $second = Enter-FrameworkMaintenanceLock $config 'competing-owner'
    Assert-True ($null -eq $second) 'Concurrent lock was incorrectly granted.'
    Exit-FrameworkMaintenanceLock $first $config
    $second = Enter-FrameworkMaintenanceLock $config 'new-owner'
    Assert-True ($null -ne $second) 'A stale lock file prevented reacquisition.'
    Exit-FrameworkMaintenanceLock $second $config

    function Get-Process { param($Name,$ErrorAction) if ($Name -eq 'steamcmd') { [PSCustomObject]@{ Id=99125 } } }
    Assert-True ($null -eq (Enter-FrameworkMaintenanceLock $config 'orphaned-updater')) 'A surviving SteamCMD process did not block host operations.'
    Remove-Item Function:\Get-Process

    function Get-InstanceProcesses { param($Profile) return $script:ownedProcesses }
    function Get-CimInstance { param($ClassName,$Filter,$ErrorAction) return $script:allProcesses }
    function Get-NetUDPEndpoint { param($ErrorAction) return $script:endpoints }
    function Get-ServerProcesses { return $script:allProcesses }
    $script:ownedProcesses=@(); $script:allProcesses=@(); $script:endpoints=@()
    $capacity=[PSCustomObject]@{ MaxRunningInstances=2; MaxTotalHeadlessClients=2 }
    Assert-StartCapacity $profile $capacity 1
    $script:ownedProcesses=@($own)
    Assert-Throws { Assert-StartCapacity $profile $capacity 1 } 'Duplicate instance start was allowed.'
    $script:ownedProcesses=@(); $script:allProcesses=@($own,$own)
    Assert-Throws { Assert-StartCapacity $profile $capacity 1 } 'The host instance limit was ignored.'
    Assert-Throws { Assert-ServersIdle } 'Shared updates were allowed while game processes existed.'
    $hc=$own.PSObject.Copy(); $hc.CommandLine+=' -client'
    $script:allProcesses=@($hc,$hc)
    Assert-Throws { Assert-StartCapacity $profile $capacity 1 } 'The host HC limit was ignored.'
    $script:allProcesses=@(); $script:endpoints=@([PSCustomObject]@{ LocalPort=2406 })
    Assert-Throws { Assert-StartCapacity $profile $capacity 0 } 'A conflicting BattlEye port was ignored.'
    $script:endpoints=@()
    $overlap=[PSCustomObject]@{ ServerInstallPath='C:\Arma'; InstanceDataPath='C:\Arma\instances' }
    Assert-Throws { Get-InstanceDataRoot $overlap } 'Nested instance/shared data paths were accepted.'

    # A forged/stale PID file is irrelevant: selection uses the OS command line.
    $script:killed = $false
    function Get-InstanceProcesses { param($Profile) return $own }
    function Get-Process {
        param($Id,$ErrorAction)
        $fake = [PSCustomObject]@{ Handle=1 }
        $fake | Add-Member ScriptMethod Kill { $script:killed=$true }
        $fake | Add-Member ScriptMethod WaitForExit { param($Timeout) return $true }
        return $fake
    }
    function Get-CimInstance { param($ClassName,$Filter,$ErrorAction) return $script:currentProcess }
    $script:currentProcess = $own.PSObject.Copy(); $script:currentProcess.CreationDate = $own.CreationDate.AddMinutes(1)
    Stop-InstanceProcesses $profile
    Assert-True (-not $script:killed) 'PID reuse caused an unrelated process to be killed.'
    $script:currentProcess = $own
    Stop-InstanceProcesses $profile
    Assert-True $script:killed 'The verified owned process was not stopped.'

    $source=Join-Path $fixture 'upload.pbo'; $target=Join-Path $fixture 'deployed.pbo'
    Set-Content -LiteralPath $source -Value 'complete fixture'
    $writer=[IO.File]::Open($source,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
    try { Assert-Throws { Copy-LockedInstanceFile $source $target } 'An incomplete upload was copied.' } finally { $writer.Dispose() }
    Copy-LockedInstanceFile $source $target
    Assert-True ((Get-Content -LiteralPath $target -Raw) -eq (Get-Content -LiteralPath $source -Raw)) 'Completed upload was not copied.'
    Assert-Throws { Copy-LockedInstanceFile $source $target -MaxBytes 2 } 'The size limit was not checked on the locked upload.'
    Write-Host "Passed $script:checks PowerShell instance checks."
} finally {
    $resolved=[IO.Path]::GetFullPath($fixture)
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -notlike 'arma-instance-tests-*') { throw 'Unsafe test cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
