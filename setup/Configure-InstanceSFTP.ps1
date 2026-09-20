#Requires -Version 5.1
#Requires -RunAsAdministrator
<# .SYNOPSIS
Provision a NEW SFTP-only local account for one isolated instance. The chroot
root is read-only; profile configuration and missions are writable. No junction
to runtime/control data is exposed. Run -WhatIf to preview the scope.
.DESCRIPTION
Use -PublicKeyFile for key authentication or -UsePassword for password-only
authentication. Password mode prompts securely unless -Password (SecureString)
is supplied. -WhatIf does not prompt for a password or change the host.
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName='PublicKey')]
param(
    [Parameter(Mandatory)][string]$Profile,
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9_-]{0,19}$')][string]$SftpUser,
    [Parameter(Mandatory, ParameterSetName='PublicKey')][string]$PublicKeyFile,
    [Parameter(Mandatory, ParameterSetName='Password')][switch]$UsePassword,
    [Parameter(ParameterSetName='Password')][ValidateNotNull()][securestring]$Password,
    [Parameter(Mandatory)][string]$BotUser,
    [string]$SshdConfig = 'C:\ProgramData\ssh\sshd_config'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\Common.ps1')
$prof = Get-Profile $Profile
if (-not $prof.Isolated -or -not (Test-Path -LiteralPath $prof.UploadDir)) { throw 'Provision an isolated instance first.' }
if (Get-LocalUser -Name $SftpUser -ErrorAction SilentlyContinue) { throw 'Use a new dedicated SFTP account. Existing accounts are not repurposed.' }
$botAccount = Get-LocalUser -Name $BotUser -ErrorAction Stop
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
Assert-NoReparsePoint $prof.UploadDir
$authMethod = if ($passwordAuth) { 'password' } else { 'publickey' }
if (-not $PSCmdlet.ShouldProcess($SftpUser, "Create $authMethod SFTP-only account restricted to $($prof.UploadDir) and restart sshd")) { return }

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

if ($passwordAuth) {
    $accountPassword = if ($null -ne $Password) { $Password } else { Read-Host "Password for '$SftpUser'" -AsSecureString }
    if ($accountPassword.Length -eq 0) { throw 'An empty SFTP password is not allowed.' }
} else {
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $accountPassword = ConvertTo-SecureString (([Convert]::ToBase64String($bytes)) + 'aA1!') -AsPlainText -Force
}
try {
    $account = New-LocalUser -Name $SftpUser -Password $accountPassword -Disabled -PasswordNeverExpires -UserMayNotChangePassword -Description "SFTP for Arma instance $Profile"
} finally { $accountPassword = $null }
$sid = $account.SID.Value
$botSid = $botAccount.SID.Value
$base = @{ 'S-1-5-18' = 'FullControl'; 'S-1-5-32-544' = 'FullControl'; $botSid = 'Modify' }
Set-ExactDirectoryAcl $prof.InstanceDir $base
$rootAcl = @{ 'S-1-5-18' = 'FullControl'; 'S-1-5-32-544' = 'FullControl'; $botSid = 'ReadAndExecute'; $sid = 'ReadAndExecute' }
Set-ExactDirectoryAcl $prof.UploadDir $rootAcl
$writeAcl = @{ 'S-1-5-18' = 'FullControl'; 'S-1-5-32-544' = 'FullControl'; $botSid = 'Modify'; $sid = 'Modify' }
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
$backup = "$SshdConfig.backup-$(Get-Date -Format 'yyyyMMddHHmmss')"
$installed = $false
try {
    [IO.File]::WriteAllText($candidate, ($existing + $block), [Text.UTF8Encoding]::new($false))
    & $sshd -t -f $candidate
    if ($LASTEXITCODE -ne 0) { throw 'OpenSSH rejected the candidate configuration. Existing sshd_config was preserved.' }
    # Earlier Match blocks can take precedence. Inspect the effective result
    # before enabling this account, rather than relying on syntax alone.
    $effective = @(& $sshd -T -f $candidate -C "user=$SftpUser,host=localhost,addr=127.0.0.1")
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
    throw $failure
} finally {
    if (Test-Path -LiteralPath $candidate) { Remove-Item -LiteralPath $candidate -Force }
}
Write-Log "SFTP account '$SftpUser' created. Writable paths: /mpmissions and /profile." 'Success'
