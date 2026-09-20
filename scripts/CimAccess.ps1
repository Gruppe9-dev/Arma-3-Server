# Helpers for the administrator-run bot setup. Never loaded by bot operations.

function Add-CimNamespaceReadAce {
    param([byte[]]$Descriptor, [Security.Principal.SecurityIdentifier]$AccountSid)
    $security = [Security.AccessControl.RawSecurityDescriptor]::new($Descriptor, 0)
    if ($null -eq $security.DiscretionaryAcl) { throw 'Refusing to replace a missing namespace DACL.' }
    # SSH creates a network logon; WMI requires Remote Enable even for a
    # query against the same host. WBEM_ENABLE | WBEM_REMOTE_ACCESS = 0x21.
    $requiredMask = 0x21
    $allowedMask = 0
    foreach ($ace in $security.DiscretionaryAcl) {
        if ($ace -isnot [Security.AccessControl.CommonAce] -or $ace.SecurityIdentifier -ne $AccountSid -or
            ([int]$ace.AceFlags -band [int][Security.AccessControl.AceFlags]::InheritOnly) -or -not ($ace.AccessMask -band $requiredMask)) { continue }
        if ($ace.AceQualifier -eq [Security.AccessControl.AceQualifier]::AccessDenied) {
            throw 'An existing namespace ACE denies this account read or Remote Enable access. Review the deny policy explicitly.'
        }
        if ($ace.AceQualifier -eq [Security.AccessControl.AceQualifier]::AccessAllowed -and -not $ace.IsCallback) {
            $allowedMask = $allowedMask -bor $ace.AccessMask
        }
    }
    $missingMask = $requiredMask -band (-bnot $allowedMask)
    if ($missingMask -eq 0) { return [PSCustomObject]@{ Changed=$false; Bytes=$Descriptor } }

    # Add only missing rights, including upgrades from the earlier read-only
    # grant. No new method/write/ACL-edit rights or child-namespace inheritance.
    $newAce = [Security.AccessControl.CommonAce]::new(
        [Security.AccessControl.AceFlags]::None, [Security.AccessControl.AceQualifier]::AccessAllowed,
        $missingMask, $AccountSid, $false, $null)
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
        if (-not $change.Updated.Changed) { Write-Host "Read and Remote Enable access already present for $AccountSid on $namespace."; continue }
        if (-not $PSCmdlet.ShouldProcess("$AccountSid on $namespace", 'Grant WMI namespace Enable Account and Remote Enable for SSH queries (0x21)')) { continue }
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
        Write-Host "Granted namespace read and Remote Enable access to $AccountSid on $namespace (required mask 0x21)."
    }
}
