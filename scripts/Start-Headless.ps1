#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Profile,
    [ValidateRange(1,16)][int]$HCIndex = 1,
    [ValidateSet('127.0.0.1','localhost')][string]$ServerHost = '127.0.0.1',
    [switch]$PassThru
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$config = Get-FrameworkConfig
$lock = Enter-FrameworkMaintenanceLock -Config $config -Purpose "headless:$Profile"
if (-not $lock) { throw 'Another start, stop, or maintenance operation is running.' }
try {
    $prof = Get-Profile $Profile
    $processes = @(Get-InstanceProcesses $prof)
    $main = @($processes | Where-Object { '-client' -notin @(Get-ArmaCommandArguments $_.CommandLine) })
    if ($main.Count -ne 1) { throw 'Exactly one server process must be running for this instance.' }
    $headless = @($processes | Where-Object { '-client' -in @(Get-ArmaCommandArguments $_.CommandLine) })
    if ($headless.Count -ge $prof.HeadlessClientCount -or $HCIndex -gt $prof.HeadlessClientCount) { throw 'The approved headless client count would be exceeded.' }
    foreach ($process in $headless) {
        if ("-name=HC$HCIndex" -in @(Get-ArmaCommandArguments $process.CommandLine)) { throw 'This headless client is already running.' }
    }
    $total = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'arma3server%'" | Where-Object {
        '-client' -in @(Get-ArmaCommandArguments $_.CommandLine)
    }).Count
    if ($total -ge (Get-ConfiguredLimit $config 'MaxTotalHeadlessClients' 4)) { throw 'Headless client capacity exceeded.' }
    $processId = Start-InstanceHeadless $prof $config $HCIndex
    Write-Log "HC $HCIndex started for '$Profile' (PID: $processId)." 'Success'
    if ($PassThru) { $processId }
} finally { Exit-FrameworkMaintenanceLock -Lock $lock -Config $config }
