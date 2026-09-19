#Requires -Version 5.1
<# .SYNOPSIS
Export the locally trusted Windows OpenSSH host public key for the bot.
Run ON THE DEDICATED HOST; never populate trust from an unverified network scan.
#>
[CmdletBinding()]
param(
    [string]$HostName = 'host.docker.internal',
    [ValidateRange(1,65535)][int]$Port = 22,
    [string]$HostPublicKey = 'C:\ProgramData\ssh\ssh_host_ed25519_key.pub'
)
$ErrorActionPreference = 'Stop'
if ($HostName -notmatch '^[A-Za-z0-9_.:-]+$') { throw 'Invalid SSH hostname.' }
$key = (Get-Content -LiteralPath $HostPublicKey -Raw).Trim() -split '\s+'
if ($key.Count -lt 2 -or $key[0] -ne 'ssh-ed25519') { throw 'Expected the local ed25519 SSH host public key.' }
$destination = Join-Path (Split-Path -Parent $PSScriptRoot) 'bot\ssh'
New-Item -ItemType Directory -Path $destination -Force | Out-Null
$hostToken = if ($Port -eq 22) { $HostName } else { "[${HostName}]:$Port" }
Set-Content -LiteralPath (Join-Path $destination 'known_hosts') -Value "$hostToken $($key[0]) $($key[1])" -Encoding ASCII
Write-Host "Host key exported to $destination\known_hosts"
