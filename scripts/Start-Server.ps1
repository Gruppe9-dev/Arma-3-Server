#Requires -Version 5.1
<# .SYNOPSIS
Start one profile using shared game/mod files and profile-owned runtime data.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Profile,
    [switch]$NoHC,
    [switch]$NoWait,
    [ValidateRange(0,300)][int]$HCDelay = 10
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$config = Get-FrameworkConfig
$lock = Enter-FrameworkMaintenanceLock -Config $config -Purpose "start:$Profile"
if (-not $lock) { throw 'Another start, stop, or maintenance operation is running. Try again when it completes.' }
$started = $false
try {
    $prof = Get-Profile $Profile
    $marker = Join-Path $config.ServerInstallPath '.arma3-server-branch'
    if (Test-Path -LiteralPath $marker) {
        if ((Get-Content -LiteralPath $marker -Raw).Trim() -ne $prof.Branch) { throw 'The profile branch does not match the shared installation.' }
    } elseif ($prof.Isolated) {
        throw 'The shared installation has no branch marker. Verify the installation with Update-Server.ps1 first.'
    }
    $hcCount = if ($NoHC) { 0 } else { [int](Get-OptionalValue $prof 'HeadlessClientCount' 0) }
    Assert-StartCapacity $prof $config $hcCount
    Prepare-InstanceRuntime $prof $config
    foreach ($path in @($prof.ServerCfg, $prof.BasicCfg)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required configuration is missing: $path" }
    }
    Invoke-LogRotation -ProfileDir $prof.RuntimeProfileDir -LogDir $prof.LogDir -KeepSessions 20
    $binary = Get-Arma3ServerBinary -ServerInstallPath $prof.GameDir -Branch $prof.Branch
    $arguments = @("-port=$($prof.Port)", "-config=`"$($prof.ServerCfg)`"", "-cfg=`"$($prof.BasicCfg)`"",
        "-profiles=`"$($prof.RuntimeProfileDir)`"", "-name=$Profile", '-world=empty', '-enableHT')
    $mods = Get-InstanceModString @($prof.Mods) $config
    $serverMods = Get-InstanceModString @($prof.ServerMods) $config
    if ($mods) { $arguments += "-mod=`"$mods`"" }
    if ($serverMods) { $arguments += "-serverMod=`"$serverMods`"" }
    if (Get-OptionalValue $prof 'EnableAutoInit' $false) { $arguments += '-autoInit' }
    if ((Get-OptionalValue $prof 'FPSLimit' 0) -gt 0) { $arguments += "-limitFPS=$($prof.FPSLimit)" }
    if (-not $prof.Isolated) { $arguments += @((Get-OptionalValue $prof 'ExtraArgs' @())) }
    $serverPid = Start-DetachedProcess -FilePath $binary -ArgumentList $arguments -WorkingDirectory $prof.GameDir
    $started = $true
    New-Item -ItemType Directory -Path $prof.StateDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $prof.StateDir 'server.pid') -Value $serverPid -Encoding ASCII
    if ($hcCount -gt 0) {
        if (-not $NoWait) { $null = Wait-ServerReady -Port ([int]$prof.Port + 1) -TimeoutSeconds 20 }
        Start-Sleep -Seconds $HCDelay
        for ($index = 1; $index -le $hcCount; $index++) { $null = Start-InstanceHeadless $prof $config $index }
    }
    $mainProcesses = @(Get-InstanceProcesses $prof | Where-Object { '-client' -notin @(Get-ArmaCommandArguments $_.CommandLine) })
    if ($mainProcesses.Count -ne 1) { throw 'The main server process exited during startup. Inspect the instance RPT.' }
    Write-Log 'Server process launched; game readiness must be checked via A2S/RPT.' 'Success'
    Write-Log "Profile  : $Profile"
    Write-Log "Port     : $($prof.Port)"
    Write-Log "PID      : $serverPid"
    Write-Log "HCs      : $hcCount"
} catch {
    if ($started) { Stop-InstanceProcesses $prof }
    throw
} finally { Exit-FrameworkMaintenanceLock -Lock $lock -Config $config }
