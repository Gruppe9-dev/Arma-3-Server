# Helpers for the administrator-run bot setup. Never loaded by bot operations.

function Add-CimNamespaceReadAce {
    param([byte[]]$Descriptor, [Security.Principal.SecurityIdentifier]$AccountSid)
    $security = [Security.AccessControl.RawSecurityDescriptor]::new($Descriptor, 0)
    if ($null -eq $security.DiscretionaryAcl) { throw 'Refusing to replace a missing namespace DACL.' }
    $alreadyAllowed = $false
    foreach ($ace in $security.DiscretionaryAcl) {
        if ($ace -isnot [Security.AccessControl.CommonAce] -or $ace.SecurityIdentifier -ne $AccountSid -or
            ([int]$ace.AceFlags -band [int][Security.AccessControl.AceFlags]::InheritOnly) -or -not ($ace.AccessMask -band 1)) { continue }
        if ($ace.AceQualifier -eq [Security.AccessControl.AceQualifier]::AccessDenied) {
            throw 'An existing namespace ACE denies this account read access. Review the deny policy explicitly.'
        }
        if ($ace.AceQualifier -eq [Security.AccessControl.AceQualifier]::AccessAllowed) { $alreadyAllowed = $true }
    }
    if ($alreadyAllowed) { return [PSCustomObject]@{ Changed=$false; Bytes=$Descriptor } }

    # WBEM_ENABLE (Enable Account) only: local namespace reads. No method
    # execution, write, remote access, ACL editing, or child-namespace inheritance.
    $newAce = [Security.AccessControl.CommonAce]::new(
        [Security.AccessControl.AceFlags]::None, [Security.AccessControl.AceQualifier]::AccessAllowed,
        1, $AccountSid, $false, $null)
    $index = 0
    while ($index -lt $security.DiscretionaryAcl.Count -and -not $security.DiscretionaryAcl[$index].IsInherited) { $index++ }
    $security.DiscretionaryAcl.InsertAce($index, $newAce)
    $bytes = New-Object byte[] $security.BinaryLength
    $security.GetBinaryForm($bytes, 0)
    return [PSCustomObject]@{ Changed=$true; Bytes=$bytes }
}

function Grant-BotCimReadAccess {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][Security.Principal.SecurityIdentifier]$AccountSid,
        [Parameter(Mandatory)][string]$BackupDirectory
    )
    # Read/validate both descriptors before changing either namespace. GetSD /
    # SetSD keep the binary descriptor suitable for exact on-disk backups.
    $changes = foreach ($namespace in @('root/cimv2', 'root/StandardCimv2')) {
        $current = Invoke-CimMethod -Namespace $namespace -ClassName __SystemSecurity -MethodName GetSD -ErrorAction Stop
        if ($current.ReturnValue -ne 0) { throw "Cannot read namespace ACL for '$namespace' (result $($current.ReturnValue))." }
        $updated = Add-CimNamespaceReadAce -Descriptor $current.SD -AccountSid $AccountSid
        [PSCustomObject]@{ Namespace=$namespace; Original=$current.SD; Updated=$updated }
    }
    $backupRun = Join-Path $BackupDirectory ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N'))
    foreach ($change in $changes) {
        $namespace = $change.Namespace
        if (-not $change.Updated.Changed) { Write-Host "Read access already present for $AccountSid on $namespace."; continue }
        if (-not $PSCmdlet.ShouldProcess("$AccountSid on $namespace", 'Grant local WMI namespace read access (WBEM_ENABLE only)')) { continue }
        New-Item -ItemType Directory -Path $backupRun -Force | Out-Null
        $backup = Join-Path $backupRun ($namespace.Replace('/', '-') + '.bin')
        [IO.File]::WriteAllBytes($backup, [byte[]]$change.Original)
        Write-Host "Original namespace ACL saved to $backup"
        $result = Invoke-CimMethod -Namespace $namespace -ClassName __SystemSecurity -MethodName SetSD `
            -Arguments @{ SD=[byte[]]$change.Updated.Bytes } -ErrorAction Stop
        if ($result.ReturnValue -ne 0) { throw "Cannot update namespace ACL for '$namespace' (result $($result.ReturnValue)). Backup: $backup" }
        $verified = Invoke-CimMethod -Namespace $namespace -ClassName __SystemSecurity -MethodName GetSD -ErrorAction Stop
        if ($verified.ReturnValue -ne 0 -or (Add-CimNamespaceReadAce $verified.SD $AccountSid).Changed) {
            throw "Namespace ACL verification failed for '$namespace'. Backup: $backup"
        }
        Write-Host "Granted local namespace read access to $AccountSid on $namespace."
    }
}
