#Requires -Version 5.1
#Requires -RunAsAdministrator
<# .SYNOPSIS
Provision or resume an SFTP-only local account for one isolated instance. The chroot
root is read-only; profile configuration and missions are writable. No junction
to runtime/control data is exposed. Run -WhatIf to preview the scope.
.DESCRIPTION
Use -PublicKeyFile for key authentication or -UsePassword for password-only
authentication. Password mode prompts securely unless -Password (SecureString)
is supplied. -WhatIf does not prompt for a password or change the host.
Use -ResumeExisting only for a disabled account left by a failed setup for this
profile. Its existing password is retained unless -Password is explicitly given.
Use -GlobalSftpUsers to include existing global SFTP accounts in the instance ACLs.
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName='PublicKey')]
param(
    [Parameter(Mandatory)][string]$Profile,
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9_-]{0,19}$')][string]$SftpUser,
    [Parameter(Mandatory, ParameterSetName='PublicKey')][string]$PublicKeyFile,
    [Parameter(Mandatory, ParameterSetName='Password')][switch]$UsePassword,
    [Parameter(ParameterSetName='Password')][ValidateNotNull()][securestring]$Password,
    [Parameter(Mandatory)][string]$BotUser,
    [switch]$ResumeExisting,
    [string[]]$GlobalSftpUsers = @(),
    [string]$SshdConfig = 'C:\ProgramData\ssh\sshd_config'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\Common.ps1')
$prof = Get-Profile $Profile
if (-not $prof.Isolated -or -not (Test-Path -LiteralPath $prof.UploadDir)) { throw 'Provision an isolated instance first.' }
$account = Get-LocalUser -Name $SftpUser -ErrorAction SilentlyContinue
if ($account) {
    if (-not $ResumeExisting) { throw 'Account already exists. Use -ResumeExisting only for a disabled account left by a failed setup for this profile.' }
    if ($account.Enabled -or $account.Description -ne "SFTP for Arma instance $Profile") {
        throw 'Resume requires a disabled framework SFTP account for this exact profile. Other accounts are not repurposed.'
    }
} elseif ($ResumeExisting) { throw 'No existing account to resume. Omit -ResumeExisting to create a new account.' }
$botAccount = Get-LocalUser -Name $BotUser -ErrorAction Stop
$globalSids = @(foreach ($name in $GlobalSftpUsers) {
    $globalAccount = Get-LocalUser -Name $name -ErrorAction Stop
    if ($name -eq $SftpUser -or $globalAccount.SID -eq $botAccount.SID) { throw 'Global SFTP accounts must be distinct from the instance and bot accounts.' }
    $globalAccount.SID.Value
})
$passwordAuth = $PSCmdlet.ParameterSetName -eq 'Password'
if ($passwordAuth -and -not $UsePassword) { throw 'Password mode requires -UsePassword.' }
if (-not $passwordAuth) {
    $key = (Get-Content -LiteralPath $PublicKeyFile -Raw).Trim()
    if ($key -notmatch '^ssh-ed25519 [A-Za-z0-9+/]+={0,2}(?: [^\r\n]*)?$') { throw 'Supply one ed25519 public key.' }
    $key = ($key -split ' ')[0..1] -join ' '
}
$sshd = (Get-Command sshd.exe -ErrorAction Stop).Source
$existing = Get-Content -LiteralPath $SshdConfig -Raw
if ($existing -match "(?im)^\s*Match\s+User\s+.*\b$([regex]::Escape($SftpUser))\b") { throw 'An SSH match block for this account already exists.' }
# Put the exact user rule before all existing conditional rules. OpenSSH uses
# the first applicable Match value, so later groups cannot loosen its controls.
# Includes could introduce an earlier Match invisibly; reject rather than guess.
if ($existing -match '(?im)^[ \t]*Include(?:[ \t]+|=)') {
    throw 'Automatic SFTP setup requires a self-contained sshd_config without Include directives.'
}
$firstMatch = [regex]::Match($existing, '(?im)^[ \t]*Match(?:[ \t]+|=)')
$globalConfig = if ($firstMatch.Success) { $existing.Substring(0, $firstMatch.Index) } else { $existing }
$existingMatches = if ($firstMatch.Success) { $existing.Substring($firstMatch.Index) } else { '' }
Assert-NoReparsePoint $prof.UploadDir
$authMethod = if ($passwordAuth) { 'password' } else { 'publickey' }
if (-not $PSCmdlet.ShouldProcess($SftpUser, "Configure $authMethod SFTP-only account restricted to $($prof.UploadDir), include global accounts [$($GlobalSftpUsers -join ', ')], and restart sshd")) { return }

function Set-ExactDirectoryAcl {
    param([string]$Path, [hashtable]$Grants)
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true,$false)
    $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    foreach ($sid in $Grants.Keys) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($sid),
            [Security.AccessControl.FileSystemRights]$Grants[$sid],
            [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

if (-not $account -and $passwordAuth) {
    $accountPassword = if ($null -ne $Password) { $Password } else { Read-Host "Password for '$SftpUser'" -AsSecureString }
    if ($accountPassword.Length -eq 0) { throw 'An empty SFTP password is not allowed.' }
} elseif (-not $account) {
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $accountPassword = ConvertTo-SecureString (([Convert]::ToBase64String($bytes)) + 'aA1!') -AsPlainText -Force
}
try {
    if (-not $account) {
        $account = New-LocalUser -Name $SftpUser -Password $accountPassword -Disabled -PasswordNeverExpires -UserMayNotChangePassword -Description "SFTP for Arma instance $Profile"
    } elseif ($passwordAuth -and $PSBoundParameters.ContainsKey('Password')) {
        if ($Password.Length -eq 0) { throw 'An empty SFTP password is not allowed.' }
        Set-LocalUser -Name $SftpUser -Password $Password
    }
} finally { $accountPassword = $null }
$sid = $account.SID.Value
$botSid = $botAccount.SID.Value
$base = @{ 'S-1-5-18' = 'FullControl'; 'S-1-5-32-544' = 'FullControl'; $botSid = 'Modify' }
foreach ($globalSid in $globalSids) { $base[$globalSid] = 'Modify' }
Set-ExactDirectoryAcl $prof.InstanceDir $base
$rootAcl = @{ 'S-1-5-18' = 'FullControl'; 'S-1-5-32-544' = 'FullControl'; $botSid = 'ReadAndExecute'; $sid = 'ReadAndExecute' }
foreach ($globalSid in $globalSids) { $rootAcl[$globalSid] = 'ReadAndExecute' }
Set-ExactDirectoryAcl $prof.UploadDir $rootAcl
$writeAcl = @{ 'S-1-5-18' = 'FullControl'; 'S-1-5-32-544' = 'FullControl'; $botSid = 'Modify'; $sid = 'Modify' }
foreach ($globalSid in $globalSids) { $writeAcl[$globalSid] = 'Modify' }
Set-ExactDirectoryAcl $prof.ConfigDir $writeAcl
Set-ExactDirectoryAcl $prof.MissionDir $writeAcl
if ($passwordAuth) {
    $authorizedKeys = 'none'
    $passwordSetting = 'yes'
    $pubkeySetting = 'no'
} else {
    $keyDir = Join-Path (Split-Path -Parent $SshdConfig) 'instance_keys'
    New-Item -ItemType Directory -Path $keyDir -Force | Out-Null
    $keyPath = Join-Path $keyDir $SftpUser
    Set-Content -LiteralPath $keyPath -Value $key -Encoding ASCII
    & icacls.exe $keyPath /inheritance:r /grant:r '*S-1-5-18:(F)' '*S-1-5-32-544:(F)' "*${sid}:(R)" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not secure the authorized key file.' }
    $authorizedKeys = $keyPath.Replace('\','/')
    $passwordSetting = 'no'
    $pubkeySetting = 'yes'
}
$jail = $prof.UploadDir.Replace('\','/')
$block = @"

# Arma instance: $Profile
Match User $SftpUser
    AuthorizedKeysFile "$authorizedKeys"
    AuthenticationMethods $authMethod
    PasswordAuthentication $passwordSetting
    PubkeyAuthentication $pubkeySetting
    ForceCommand internal-sftp
    ChrootDirectory "$jail"
    AllowTcpForwarding no
    AllowAgentForwarding no
    PermitTTY no
Match all
"@
$candidate = "$SshdConfig.arma-candidate"
$validation = "$SshdConfig.arma-validation"
$backup = "$SshdConfig.backup-$(Get-Date -Format 'yyyyMMddHHmmss')"
$installed = $false
try {
    $prefix = $globalConfig.TrimEnd() + "`r`n" + $block + "`r`n"
    [IO.File]::WriteAllText($candidate, ($prefix + $existingMatches), [Text.UTF8Encoding]::new($false))
    & $sshd -t -f $candidate
    if ($LASTEXITCODE -ne 0) { throw 'OpenSSH rejected the candidate configuration. Existing sshd_config was preserved.' }
    # -T against Match Group needs another user's Windows logon token, which
    # an administrator process cannot obtain like the SYSTEM sshd service can.
    # Validate the exact first-match prefix; the complete candidate was syntax
    # checked above. Later Match blocks cannot override these explicit settings.
    # This checks confinement/auth settings, not all group/IP login eligibility.
    [IO.File]::WriteAllText($validation, $prefix, [Text.UTF8Encoding]::new($false))
    $effective = @(& $sshd -T -f $validation -C "user=$SftpUser,host=localhost,addr=127.0.0.1")
    if ($LASTEXITCODE -ne 0) { throw 'Could not validate the effective SFTP account configuration.' }
    $settings = @{}
    foreach ($line in $effective) {
        $parts = ([string]$line) -split ' ', 2
        if ($parts.Count -eq 2) { $settings[$parts[0]] = $parts[1].Trim().Trim('"') }
    }
    $required = @{ forcecommand='internal-sftp'; authenticationmethods=$authMethod; passwordauthentication=$passwordSetting; pubkeyauthentication=$pubkeySetting;
        allowtcpforwarding='no'; allowagentforwarding='no'; permittty='no' }
    foreach ($name in $required.Keys) {
        if ($settings[$name] -ne $required[$name]) { throw "An existing SSH rule overrides the required $name restriction." }
    }
    foreach ($entry in @(@('chrootdirectory',$jail), @('authorizedkeysfile',$authorizedKeys))) {
        if (-not $settings.ContainsKey($entry[0]) -or $settings[$entry[0]].Replace('\','/').TrimEnd('/') -ne $entry[1]) {
            throw "An existing SSH rule overrides the required $($entry[0]) path."
        }
    }
    Copy-Item -LiteralPath $SshdConfig -Destination $backup
    Move-Item -LiteralPath $candidate -Destination $SshdConfig -Force
    $installed = $true
    Restart-Service sshd
    Enable-LocalUser -Name $SftpUser
} catch {
    $failure = $_
    Disable-LocalUser -Name $SftpUser
    if ($installed) {
        try {
            Copy-Item -LiteralPath $backup -Destination $SshdConfig -Force
            Restart-Service sshd
        } catch { Write-Warning "Automatic SSH configuration restore failed. Restore $backup from the administrative console." }
    }
    Write-Warning "Account '$SftpUser' remains disabled. After fixing the error, retry with -ResumeExisting and the same profile/authentication options."
    throw $failure
} finally {
    if (Test-Path -LiteralPath $candidate) { Remove-Item -LiteralPath $candidate -Force }
    if (Test-Path -LiteralPath $validation) { Remove-Item -LiteralPath $validation -Force }
}
Write-Log "SFTP account '$SftpUser' configured and enabled. Writable paths: /mpmissions and /profile." 'Success'
