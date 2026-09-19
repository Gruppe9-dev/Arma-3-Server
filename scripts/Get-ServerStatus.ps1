#Requires -Version 5.1
[CmdletBinding()]
param([string]$Profile)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$names = if ($Profile) { @($Profile) } else { @(Get-AvailableProfiles) }
$result = @()
foreach ($name in $names) {
    $prof = Get-Profile $name
    $owned = @(Get-InstanceProcesses $prof)
    $main = @($owned | Where-Object { '-client' -notin @(Get-ArmaCommandArguments $_.CommandLine) })
    $ram = 0L; $cpu = 0.0; $uptime = 0
    $samples = @{}
    foreach ($item in $owned) {
        $process = Get-Process -Id $item.ProcessId -ErrorAction SilentlyContinue
        if ($process) { $samples[[int]$process.Id] = @{ CPU = $process.CPU; Start = $process.StartTime } }
    }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    if ($samples.Count -gt 0) { Start-Sleep -Milliseconds 200 }
    foreach ($item in $owned) {
        $process = Get-Process -Id $item.ProcessId -ErrorAction SilentlyContinue
        if ($process -and $samples.ContainsKey([int]$process.Id) -and $process.StartTime -eq $samples[[int]$process.Id].Start) {
            $ram += $process.WorkingSet64
            $cpu += [Math]::Max(0, $process.CPU - $samples[[int]$process.Id].CPU)
        }
    }
    if ($main.Count -gt 0) { $uptime = [int]([DateTime]::Now - $main[0].CreationDate).TotalSeconds }
    $presets = Get-OptionalValue $prof 'Presets' ([PSCustomObject]@{})
    $presetNames = @('default') + @($presets.PSObject.Properties | ForEach-Object { $_.Name })
    $mission = ''
    $rpt = @(Get-ChildItem -LiteralPath $prof.RuntimeProfileDir -File -Filter 'arma3server*.rpt' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    if ($rpt.Count -gt 0 -and $main.Count -gt 0) {
        $match = @(Get-Content -LiteralPath $rpt[0].FullName -Tail 10000 -ErrorAction SilentlyContinue |
            Select-String -Pattern '^\d{1,2}:\d{2}:\d{2} Mission (.+?): Number of roles' | Select-Object -Last 1)
        if ($match.Count -gt 0) { $mission = $match[0].Matches[0].Groups[1].Value.Trim() }
    }
    $result += [ordered]@{
        Profile = $name; Port = [int]$prof.Port; Running = $main.Count -gt 0
        PID = if ($main.Count -gt 0) { [int]$main[0].ProcessId } else { 0 }
        Processes = $owned.Count; HeadlessClients = $owned.Count - $main.Count
        UptimeSeconds = $uptime; RamMB = [Math]::Round($ram / 1MB)
        CpuPercent = [Math]::Round($cpu / [Math]::Max(0.001,$timer.Elapsed.TotalSeconds) / [Environment]::ProcessorCount * 100, 1)
        Preset = if ($prof.SelectedPreset) { $prof.SelectedPreset } else { 'default' }
        Presets = $presetNames; Isolated = $prof.Isolated; Mission = $mission
    }
}
Write-Output ('INSTANCE_JSON=' + (ConvertTo-Json -InputObject @($result) -Depth 5 -Compress))
