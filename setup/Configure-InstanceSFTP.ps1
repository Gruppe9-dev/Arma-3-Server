#Requires -Version 5.1
#Requires -RunAsAdministrator
<# .SYNOPSIS
Provision, resume or update an SFTP-only local account for one isolated instance.
The instance root is read-only; files/profile and files/mpmissions are writable.
runtime/profiles is readable for logs and saves. Run -WhatIf to preview the scope.
.DESCRIPTION
Use -PublicKeyFile for key authentication or -UsePassword for password-only
authentication. Password mode prompts securely unless -Password (SecureString)
is supplied. -WhatIf does not prompt for a password or change the host.
Use -ResumeExisting only for a disabled account left by a failed setup for this
profile. Its existing password is retained unless -Password is explicitly given.
Use -GlobalSftpUsers to include existing global SFTP accounts in the instance ACLs.
Use -UpdateExisting to upgrade a managed account's paths/ACLs while retaining its
password or key authentication. No password prompt occurs in update mode.
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName='PublicKey')]
param(
    [Parameter(Mandatory)][string]$Profile,
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9_-]{0,19}$')][string]$SftpUser,
    [Parameter(Mandatory, ParameterSetName='PublicKey')][string]$PublicKeyFile,
    [Parameter(Mandatory, ParameterSetName='Password')][switch]$UsePassword,
    [Parameter(ParameterSetName='Password')][ValidateNotNull()][securestring]$Password,
    [Parameter(Mandatory, ParameterSetName='Update')][switch]$UpdateExisting,
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
    if (-not $ResumeExisting -and -not $UpdateExisting) { throw 'Account already exists. Use -UpdateExisting for a managed account or -ResumeExisting for an incomplete setup.' }
    if (($account.Enabled -and -not $UpdateExisting) -or $account.Description -ne "SFTP for Arma instance $Profile") {
        throw 'Only framework SFTP accounts for this exact profile are supported. Resume additionally requires a disabled account.'
    }
} elseif ($ResumeExisting -or $UpdateExisting) { throw 'No existing account to resume/update. Omit the existing-account switch to create a new account.' }
if ($ResumeExisting -and $UpdateExisting) { throw 'Choose either -ResumeExisting or -UpdateExisting.' }
$botAccount = Get-LocalUser -Name $BotUser -ErrorAction Stop
$globalSids = @(foreach ($name in $GlobalSftpUsers) {
    $globalAccount = Get-LocalUser -Name $name -ErrorAction Stop
    if ($name -eq $SftpUser -or $globalAccount.SID -eq $botAccount.SID) { throw 'Global SFTP accounts must be distinct from the instance and bot accounts.' }
    $globalAccount.SID.Value
})
$passwordAuth = $PSCmdlet.ParameterSetName -eq 'Password'
if ($passwordAuth -and -not $UsePassword) { throw 'Password mode requires -UsePassword.' }
if (-not $passwordAuth -and -not $UpdateExisting) {
    $key = (Get-Content -LiteralPath $PublicKeyFile -Raw).Trim()
    if ($key -notmatch '^ssh-ed25519 [A-Za-z0-9+/]+={0,2}(?: [^\r\n]*)?$') { throw 'Supply one ed25519 public key.' }
    $key = ($key -split ' ')[0..1] -join ' '
}
$sshd = (Get-Command sshd.exe -ErrorAction Stop).Source
$existing = Get-Content -LiteralPath $SshdConfig -Raw
if ($UpdateExisting) {
    # Only replace our own exact user block. Keep credentials and all unrelated
    # SSH rules; reject hand-edited or ambiguous blocks instead of guessing.
    $pattern = '(?im)^[ \t]*# Arma instance: ' + [regex]::Escape($Profile) + '[ \t]*\r?\nMatch User ' + [regex]::Escape($SftpUser) + '[ \t]*\r?\n(?<settings>[\s\S]*?)^Match all[ \t]*(?:\r?\n|$)'
    $managed = [regex]::Matches($existing, $pattern)
    if ($managed.Count -ne 1) { throw 'Update requires exactly one framework-managed SSH block for this account and profile.' }
    $oldSettings = @{}
    $allowed = @('authorizedkeysfile','authenticationmethods','passwordauthentication','pubkeyauthentication','forcecommand','chrootdirectory','allowtcpforwarding','allowagentforwarding','permittty')
    foreach ($line in ($managed[0].Groups['settings'].Value -split '\r?\n')) {
        if (-not $line.Trim()) { continue }
        if ($line -notmatch '^\s*([a-zA-Z]+)\s+(.+?)\s*$') { throw 'Unrecognized managed SSH setting. Review the block manually.' }
        $name = $Matches[1].ToLowerInvariant()
        if ($name -notin $allowed -or $oldSettings.ContainsKey($name)) { throw 'Unexpected or duplicate managed SSH setting.' }
        $oldSettings[$name] = $Matches[2].Trim('"')
    }
    foreach ($name in $allowed) { if (-not $oldSettings.ContainsKey($name)) { throw "Managed SSH block is missing $name." } }
    $oldJail = $oldSettings.chrootdirectory.Replace('\','/').TrimEnd('/')
    if ($oldJail -notin @($prof.UploadDir.Replace('\','/').TrimEnd('/'), $prof.InstanceDir.Replace('\','/').TrimEnd('/'))) { throw 'Managed SSH block belongs to a different instance path.' }
    $passwordAuth = $oldSettings.authenticationmethods -eq 'password'
    if (-not $passwordAuth -and $oldSettings.authenticationmethods -ne 'publickey') { throw 'Unsupported existing authentication method.' }
    $expectedPassword = if ($passwordAuth) { 'yes' } else { 'no' }
    $expectedPubkey = if ($passwordAuth) { 'no' } else { 'yes' }
    if ($oldSettings.passwordauthentication -ne $expectedPassword -or $oldSettings.pubkeyauthentication -ne $expectedPubkey -or
        $oldSettings.forcecommand -ne 'internal-sftp' -or $oldSettings.allowtcpforwarding -ne 'no' -or
        $oldSettings.allowagentforwarding -ne 'no' -or $oldSettings.permittty -ne 'no') { throw 'Existing managed SSH restrictions do not match the expected policy.' }
    $existing = $existing.Remove($managed[0].Index, $managed[0].Length)
}
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
Assert-NoReparsePoint $prof.RuntimeProfileDir
$runtimeDir = Split-Path -Parent $prof.RuntimeProfileDir
foreach ($path in @($prof.InstanceDir, $runtimeDir)) {
    if ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Instance root cannot be a reparse point: $path" }
}
$authMethod = if ($passwordAuth) { 'password' } else { 'publickey' }
if (-not $PSCmdlet.ShouldProcess($SftpUser, "Configure $authMethod SFTP at $($prof.InstanceDir), grant read-only runtime/profiles access, include global accounts [$($GlobalSftpUsers -join ', ')], and restart sshd")) { return }

function Set-ExactDirectoryAcl {
    param([string]$Path, [hashtable]$Grants, [string[]]$ThisDirectoryOnly = @())
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true,$false)
    $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    foreach ($sid in $Grants.Keys) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($sid),
            [Security.AccessControl.FileSystemRights]$Grants[$sid],
            $(if ($sid -in $ThisDirectoryOnly) { [Security.AccessControl.InheritanceFlags]::None } else { [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit' }),
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Reset-ProfileChildAcl {
    param([string]$Path)
    # Existing saves/logs may have protected or explicit ACLs from a migration.
    # Reset only this real profile tree so every current and future log inherits
    # read-only user access. Never walk engine junctions or writable uploads.
    foreach ($item in @(Get-ChildItem -LiteralPath $Path -Force)) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Runtime profiles contain a reparse point: $($item.FullName)" }
        $acl = if ($item.PSIsContainer) { [Security.AccessControl.DirectorySecurity]::new() } else { [Security.AccessControl.FileSecurity]::new() }
        $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
        $acl.SetAccessRuleProtection($false,$false)
        Set-Acl -LiteralPath $item.FullName -AclObject $acl
        if ($item.PSIsContainer) { Reset-ProfileChildAcl $item.FullName }
    }
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
$candidate = "$SshdConfig.arma-candidate"
$validation = "$SshdConfig.arma-validation"
$backup = "$SshdConfig.backup-$(Get-Date -Format 'yyyyMMddHHmmss')"
$installed = $false
try {
    if ($UpdateExisting) { Disable-LocalUser -Name $SftpUser }
    New-Item -ItemType Directory -Path $prof.RuntimeProfileDir -Force | Out-Null
    $base = @{ 'S-1-5-18' = 'FullControl'; 'S-1-5-32-544' = 'FullControl'; $botSid = 'Modify' }
    foreach ($globalSid in $globalSids) { $base[$globalSid] = 'Modify' }
    $base[$sid] = 'ReadAndExecute'
    # Listing the instance/runtime roots must not grant access to runtime/game,
    # runtime/config, their binaries/junctions, or other sibling data.
    Set-ExactDirectoryAcl $prof.InstanceDir $base -ThisDirectoryOnly @($sid)
    Set-ExactDirectoryAcl $runtimeDir $base -ThisDirectoryOnly @($sid)
    Set-ExactDirectoryAcl $prof.RuntimeProfileDir $base
    Reset-ProfileChildAcl $prof.RuntimeProfileDir
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
    } elseif ($UpdateExisting) {
        $authorizedKeys = $oldSettings.authorizedkeysfile
        $passwordSetting = 'no'
        $pubkeySetting = 'yes'
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
    $jail = $prof.InstanceDir.Replace('\','/')
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
    $retry = if ($UpdateExisting) { '-UpdateExisting' } else { '-ResumeExisting and the same authentication options' }
    Write-Warning "Account '$SftpUser' remains disabled. After fixing the error, retry with $retry and the same profile/global account options."
    throw $failure
} finally {
    if (Test-Path -LiteralPath $candidate) { Remove-Item -LiteralPath $candidate -Force }
    if (Test-Path -LiteralPath $validation) { Remove-Item -LiteralPath $validation -Force }
}
Write-Log "SFTP account '$SftpUser' configured and enabled. Writable: /files/mpmissions and /files/profile. Read-only: /runtime/profiles." 'Success'
