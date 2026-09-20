#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Grant the bot's existing local Windows account the namespace reads needed for
process identification and UDP port checks. Run on the dedicated Windows host.
.DESCRIPTION
Adds WBEM_ENABLE only on root/cimv2 and root/StandardCimv2, without inheritance.
Existing ACEs are preserved. Each changed descriptor is backed up under
.state/cim-permissions before writing. Supports -WhatIf and repeated execution.
This does not add the account to Administrators or enable remote WMI access.
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
