#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Grant the bot's existing local Windows account the namespace reads needed for
process identification and UDP port checks. Run on the dedicated Windows host.
.DESCRIPTION
Adds WBEM_ENABLE and WBEM_REMOTE_ACCESS (0x21) on root/cimv2 and
root/StandardCimv2, without inheritance. SSH network logons require Remote Enable
even for queries on the same host. Upgrades earlier WBEM_ENABLE-only grants.
Existing ACEs are preserved. Each changed descriptor is backed up under
.state/cim-permissions before writing. Supports -WhatIf and repeated execution.
Remote Enable permits existing namespace rights through remote logons too.
This adds no administrator membership, method/write rights, or firewall rules.
#>
[CmdletBinding(SupportsShouldProcess)]
param([ValidateNotNullOrEmpty()][string]$BotUser = 'arma_bot')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts\CimAccess.ps1')
$account = Get-LocalUser -Name $BotUser -ErrorAction Stop
$options = @{ AccountSid=$account.SID; BackupDirectory=(Join-Path $root '.state\cim-permissions') }
foreach ($option in @('WhatIf','Confirm')) {
    if ($PSBoundParameters.ContainsKey($option)) { $options[$option] = $PSBoundParameters[$option] }
}
Grant-BotCimReadAccess @options
