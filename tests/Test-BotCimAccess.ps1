#Requires -Version 5.1
# Offline ACL transformations and mocked WMI calls. No real namespace is changed.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\CimAccess.ps1')
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('arma-cim-tests-' + [Guid]::NewGuid().ToString('N'))
$script:checks = 0
function Assert-True { param([bool]$Value,[string]$Message) if (-not $Value) { throw $Message }; $script:checks++ }
function Assert-Throws { param([scriptblock]$Action,[string]$Message) $threw=$false; try { & $Action } catch { $threw=$true }; Assert-True $threw $Message }
function ConvertTo-DescriptorBytes {
    param([string]$Sddl)
    $raw = [Security.AccessControl.RawSecurityDescriptor]::new($Sddl)
    $bytes = New-Object byte[] $raw.BinaryLength
    $raw.GetBinaryForm($bytes, 0)
    return ,$bytes
}
try {
    $sid = [Security.Principal.SecurityIdentifier]::new('S-1-5-21-1-2-3-1001')
    $sddl = 'O:BAG:BAD:(D;;0x1;;;BG)(A;;0x6003f;;;BA)(A;ID;0x1;;;BU)S:(AU;SA;0x1;;;WD)'
    $original = ConvertTo-DescriptorBytes $sddl
    $originalEncoded = [Convert]::ToBase64String($original)
    $change = Add-CimNamespaceReadAce $original $sid
    Assert-True $change.Changed 'Missing read access was not added.'
    Assert-True ([Convert]::ToBase64String($original) -eq $originalEncoded) 'The original descriptor was modified in place.'
    $updated = [Security.AccessControl.RawSecurityDescriptor]::new($change.Bytes, 0)
    $added = $updated.DiscretionaryAcl[2]
    Assert-True ($updated.DiscretionaryAcl.Count -eq 4 -and $added.SecurityIdentifier -eq $sid) 'The new ACE did not precede inherited ACEs.'
    Assert-True ($added.AccessMask -eq 0x21 -and [int]$added.AceFlags -eq 0) 'The ACE must grant only Enable Account and Remote Enable without inheritance.'
    $updated.DiscretionaryAcl.RemoveAce(2)
    $originalSecurity = [Security.AccessControl.RawSecurityDescriptor]::new($original, 0)
    Assert-True ($updated.GetSddlForm([Security.AccessControl.AccessControlSections]::All) -eq $originalSecurity.GetSddlForm([Security.AccessControl.AccessControlSections]::All)) 'Existing ACEs, ownership, group, or audit settings were changed.'
    Assert-True (-not (Add-CimNamespaceReadAce $change.Bytes $sid).Changed) 'Repeated setup would duplicate the ACE.'

    # Production upgrade: the old installer already granted WBEM_ENABLE.
    $readOnly = ConvertTo-DescriptorBytes "O:BAG:BAD:(A;;0x1;;;$sid)"
    $upgrade = Add-CimNamespaceReadAce $readOnly $sid
    Assert-True $upgrade.Changed 'An earlier local-read grant prevented the SSH upgrade.'
    $upgraded = [Security.AccessControl.RawSecurityDescriptor]::new($upgrade.Bytes, 0)
    Assert-True ($upgraded.DiscretionaryAcl.Count -eq 2 -and $upgraded.DiscretionaryAcl[0].AccessMask -eq 1 -and $upgraded.DiscretionaryAcl[1].AccessMask -eq 0x20) 'Upgrade must preserve the read ACE and add only Remote Enable.'
    Assert-True (-not (Add-CimNamespaceReadAce $upgrade.Bytes $sid).Changed) 'Separate read and Remote Enable ACEs were not combined for idempotence.'
    $remoteOnly = ConvertTo-DescriptorBytes "O:BAG:BAD:(A;;0x20;;;$sid)"
    $readUpgrade = Add-CimNamespaceReadAce $remoteOnly $sid
    $readUpgraded = [Security.AccessControl.RawSecurityDescriptor]::new($readUpgrade.Bytes, 0)
    Assert-True ($readUpgrade.Changed -and $readUpgraded.DiscretionaryAcl[1].AccessMask -eq 1) 'Existing Remote Enable must require only the missing read right.'

    $denied = ConvertTo-DescriptorBytes "O:BAG:BAD:(D;;0x1;;;$sid)(A;;0x1;;;$sid)"
    Assert-Throws { Add-CimNamespaceReadAce $denied $sid } 'An existing deny ACE was overridden.'
    $remoteDenied = ConvertTo-DescriptorBytes "O:BAG:BAD:(D;;0x20;;;$sid)(A;;0x21;;;$sid)"
    Assert-Throws { Add-CimNamespaceReadAce $remoteDenied $sid } 'An existing Remote Enable deny ACE was overridden.'
    $inheritOnly = ConvertTo-DescriptorBytes "O:BAG:BAD:(A;CIIO;0x21;;;$sid)"
    Assert-True (Add-CimNamespaceReadAce $inheritOnly $sid).Changed 'An inherit-only ACE was mistaken for local permission.'
    $missing = ConvertTo-DescriptorBytes 'O:BAG:BA'
    Assert-Throws { Add-CimNamespaceReadAce $missing $sid } 'A missing DACL was replaced.'

    # Exercise the complete installer with existing production read-only grants.
    $original = $readOnly
    $originalEncoded = [Convert]::ToBase64String($original)
    $script:descriptors = @{ 'root/cimv2'=$original; 'root/StandardCimv2'=$original }
    $script:writes = 0
    $script:failRead = ''
    $script:failWrite = $false
    $script:expectedBackupDirectory = $fixture
    function Invoke-CimMethod {
        param($Namespace,$ClassName,$MethodName,$Arguments,$ErrorAction)
        if ($Namespace -notin @('root/cimv2','root/StandardCimv2') -or $ClassName -ne '__SystemSecurity') { throw 'Unexpected namespace or class.' }
        if ($MethodName -eq 'GetSD') {
            if ($Namespace -eq $script:failRead) { return [PSCustomObject]@{ ReturnValue=2; SD=$null } }
            return [PSCustomObject]@{ ReturnValue=0; SD=$script:descriptors[$Namespace] }
        }
        if ($MethodName -ne 'SetSD') { throw 'Unexpected WMI method.' }
        # Backups must exist before any write, including a rejected write.
        $backup = @(Get-ChildItem -LiteralPath $script:expectedBackupDirectory -Recurse -Filter ($Namespace.Replace('/','-') + '.bin'))
        if ($backup.Count -ne 1 -or [Convert]::ToBase64String([IO.File]::ReadAllBytes($backup[0].FullName)) -ne $originalEncoded) { throw 'Original ACL backup is missing or incorrect.' }
        $script:writes++
        if ($script:failWrite) { return [PSCustomObject]@{ ReturnValue=2 } }
        $script:descriptors[$Namespace] = $Arguments.SD
        return [PSCustomObject]@{ ReturnValue=0 }
    }
    Grant-BotCimReadAccess -AccountSid $sid -BackupDirectory $fixture -WhatIf
    Assert-True ($script:writes -eq 0 -and -not (Test-Path -LiteralPath $fixture)) 'WhatIf changed ACLs or created files.'
    $script:failRead='root/StandardCimv2'
    Assert-Throws { Grant-BotCimReadAccess $sid $fixture } 'A failed descriptor read was ignored.'
    Assert-True ($script:writes -eq 0) 'A namespace was changed before both descriptors were validated.'
    $script:failRead=''
    Grant-BotCimReadAccess $sid $fixture
    Assert-True ($script:writes -eq 2) 'Both required namespaces were not updated.'
    Grant-BotCimReadAccess $sid $fixture
    Assert-True ($script:writes -eq 2) 'Repeated setup rewrote unchanged ACLs.'

    # Use a separate backup directory for the write-failure case.
    $script:expectedBackupDirectory = Join-Path $fixture 'failed-write'
    $script:descriptors['root/cimv2']=$original
    $script:failWrite=$true
    Assert-Throws { Grant-BotCimReadAccess $sid $script:expectedBackupDirectory } 'A failed ACL write was reported as success.'
    Assert-True ($script:writes -eq 3) 'The rejected write did not reach the WMI method.'
    Write-Host "Passed $script:checks bot CIM access checks. No real namespace permissions were changed."
} finally {
    $resolved=[IO.Path]::GetFullPath($fixture)
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -notlike 'arma-cim-tests-*') { throw 'Unsafe test cleanup path.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
