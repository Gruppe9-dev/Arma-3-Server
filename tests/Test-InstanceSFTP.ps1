#Requires -Version 5.1
# Run the installer in a temporary fixture with all account/ACL/service/sshd
# operations mocked. No real Windows users, permissions, or services are changed.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = Split-Path -Parent $PSScriptRoot
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('arma-sftp-tests-' + [Guid]::NewGuid().ToString('N'))
$script:checks = 0
function Assert-True { param([bool]$Value,[string]$Message) if (-not $Value) { throw $Message }; $script:checks++ }
try {
    New-Item -ItemType Directory -Path "$fixture\scripts","$fixture\setup" -Force | Out-Null
    # Only the fixture copy omits elevation; every privileged command is mocked.
    $source = Get-Content (Join-Path $repo 'setup\Configure-InstanceSFTP.ps1') -Raw
    $source.Replace('#Requires -RunAsAdministrator', '# Elevation replaced by offline mocks') |
        Set-Content "$fixture\setup\Configure-InstanceSFTP.ps1" -Encoding UTF8
    @'
function Get-Profile {
    param($Name)
    [PSCustomObject]@{ Isolated=$true; InstanceDir=$global:SftpFixture.Root;
        UploadDir="$($global:SftpFixture.Root)\files";
        ConfigDir="$($global:SftpFixture.Root)\files\profile";
        MissionDir="$($global:SftpFixture.Root)\files\mpmissions" }
}
function Get-LocalUser {
    param($Name,$ErrorAction)
    if ($Name -eq 'arma_bot') { return [PSCustomObject]@{ SID=[Security.Principal.SecurityIdentifier]::new('S-1-5-21-1-2-3-1001') } }
    if ($Name -eq 'main_sftp') { return [PSCustomObject]@{ SID=[Security.Principal.SecurityIdentifier]::new('S-1-5-21-1-2-3-2001') } }
    if ($Name -eq 'friend_sftp' -and $global:SftpFixture.Failure -in @('resume','resume-enabled','resume-other','existing')) {
        return [PSCustomObject]@{ SID=[Security.Principal.SecurityIdentifier]::new('S-1-5-21-1-2-3-1002');
            Enabled=($global:SftpFixture.Failure -eq 'resume-enabled');
            Description=$(if ($global:SftpFixture.Failure -eq 'resume-other') { 'Unrelated account' } else { 'SFTP for Arma instance friend' }) }
    }
}
function Set-LocalUser { throw 'A resumed password must not be reset without an explicit password argument.' }
function New-LocalUser {
    param($Name,[securestring]$Password,[switch]$Disabled,[switch]$PasswordNeverExpires,[switch]$UserMayNotChangePassword,$Description)
    if (-not $Disabled -or $Password.Length -eq 0) { throw 'Account was not created disabled with a nonempty SecureString.' }
    $global:SftpFixture.Created++
    [PSCustomObject]@{ SID=[Security.Principal.SecurityIdentifier]::new('S-1-5-21-1-2-3-1002') }
}
function Disable-LocalUser { param($Name) $global:SftpFixture.Disabled++ }
function Enable-LocalUser { param($Name) $global:SftpFixture.Enabled++ }
function Set-Acl {
    param($LiteralPath,$AclObject)
    $global:SftpFixture.Acls++
    $global:SftpFixture.Grants[$LiteralPath]=$AclObject
}
function Assert-NoReparsePoint { param($Path) }
function Write-Log { param($Message,$Level) }
function Read-Host {
    param($Prompt,[switch]$AsSecureString)
    if (-not $AsSecureString) { throw 'Password prompt must be secure.' }
    $global:SftpFixture.Prompts++
    ConvertTo-SecureString 'Offline fixture password 123!' -AsPlainText -Force
}
function Get-Command { param($Name,$ErrorAction) if ($Name -ne 'sshd.exe') { throw 'Unexpected command lookup' }; [PSCustomObject]@{ Source='Invoke-FixtureSshd' } }
function icacls.exe { $global:SftpFixture.KeyAcls++; $global:LASTEXITCODE=0 }
function Restart-Service {
    param($Name)
    $global:SftpFixture.Restarts++
    if ($global:SftpFixture.Failure -eq 'restart' -and $global:SftpFixture.Restarts -eq 1) { throw 'Mock restart failure' }
}
function Invoke-FixtureSshd {
    $global:LASTEXITCODE=0
    if ($args[0] -ceq '-t') { return }
    if ($args[0] -cne '-T') { throw 'Unexpected sshd operation.' }
    $content = Get-Content -LiteralPath $args[2] -Raw
    if ($content -match '(?im)^Match Group') { throw 'ga_init, unable to resolve user friend_sftp (non-SYSTEM fixture)' }
    $settings=@{}
    foreach ($line in Get-Content -LiteralPath $args[2]) {
        if ($line -match '^\s+([a-zA-Z]+) (.+)$') { $settings[$Matches[1].ToLowerInvariant()]=$Matches[2] }
    }
    if ($global:SftpFixture.Failure -eq 'override') { $settings['passwordauthentication']='no' }
    foreach ($key in $settings.Keys) { "$key $($settings[$key])" }
}
'@ | Set-Content "$fixture\scripts\Common.ps1" -Encoding UTF8
    foreach ($mode in @('preview','password','supplied','key','override','restart','mixed','resume','resume-enabled','resume-other','existing','global-access','include','no-match')) {
        $caseRoot=Join-Path $fixture $mode
        New-Item -ItemType Directory -Path "$caseRoot\files\profile","$caseRoot\files\mpmissions" -Force | Out-Null
        $global:SftpFixture=@{ Root=$caseRoot; Created=0; Disabled=0; Enabled=0; Acls=0; KeyAcls=0; Restarts=0; Prompts=0; Failure=$mode; Grants=@{} }
        $configPath=Join-Path $caseRoot 'sshd_config'
        $header="PasswordAuthentication no`r`n# Existing bot policy must remain intact`r`n"
        $tail="Match Group administrators`r`n    AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys`r`n    PasswordAuthentication no`r`nMatch all`r`n"
        if ($mode -eq 'no-match') { $tail='' }
        $original=$header + $tail
        if ($mode -eq 'include') { $original="Include other.conf`r`n" + $original }
        [IO.File]::WriteAllText($configPath,$original)
        $keyPath=Join-Path $caseRoot 'fixture.pub'
        Set-Content $keyPath 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAA fixture'
        $parameters=@{ Profile='friend'; SftpUser='friend_sftp'; BotUser='arma_bot'; SshdConfig=$configPath }
        if ($mode -eq 'key') { $parameters.PublicKeyFile=$keyPath } else { $parameters.UsePassword=$true }
        if ($mode -eq 'mixed') { $parameters.PublicKeyFile=$keyPath }
        if ($mode -eq 'supplied') { $parameters.Password=ConvertTo-SecureString 'Supplied fixture password 456!' -AsPlainText -Force }
        if ($mode -eq 'preview') { $parameters.WhatIf=$true }
        if ($mode -like 'resume*') { $parameters.ResumeExisting=$true }
        if ($mode -eq 'global-access') { $parameters.GlobalSftpUsers=@('main_sftp') }
        $errorMessage=''
        try { & "$fixture\setup\Configure-InstanceSFTP.ps1" @parameters } catch { $errorMessage=$_.Exception.Message }
        $content=[IO.File]::ReadAllText($configPath)
        if ($mode -in @('override','restart','mixed','resume-enabled','resume-other','existing','include')) {
            Assert-True ($errorMessage.Length -gt 0) "$mode did not reject the failed setup."
            Assert-True ($global:SftpFixture.Enabled -eq 0 -and $content -eq $original) "$mode enabled an account or changed the original config."
            if ($mode -eq 'mixed') { Assert-True ($global:SftpFixture.Created -eq 0) 'Mixed authentication parameters created an account.' }
            if ($mode -in @('resume-enabled','resume-other','existing','include')) {
                Assert-True ($global:SftpFixture.Created -eq 0 -and $global:SftpFixture.Acls -eq 0 -and $global:SftpFixture.Prompts -eq 0) 'Rejected setup changed an account or its permissions.'
            }
            continue
        }
        Assert-True ($errorMessage -eq '') "$mode failed: $errorMessage"
        if ($mode -eq 'preview') {
            Assert-True ($global:SftpFixture.Prompts -eq 0 -and $global:SftpFixture.Created -eq 0 -and $global:SftpFixture.Acls -eq 0 -and $global:SftpFixture.Restarts -eq 0 -and $content -eq $original) 'WhatIf prompted or mutated host state.'
            continue
        }
        Assert-True ($global:SftpFixture.Created -eq $(if ($mode -eq 'resume') { 0 } else { 1 }) -and $global:SftpFixture.Enabled -eq 1 -and $global:SftpFixture.Restarts -eq 1) "$mode did not complete provisioning."
        Assert-True ($content.StartsWith($header) -and $content.EndsWith($tail) -and $content.Contains('ForceCommand internal-sftp') -and $content.Contains('AllowTcpForwarding no') -and $content.Contains('PermitTTY no')) 'Existing SSH policy or confinement was changed.'
        if ($tail) { Assert-True ($content.IndexOf('Match User friend_sftp') -lt $content.IndexOf('Match Group administrators')) 'The user restrictions must precede existing group rules.' }
        Assert-True (-not (Test-Path "$configPath.arma-validation") -and -not (Test-Path "$configPath.arma-candidate")) 'Temporary validation files remain.'
        if ($mode -eq 'key') {
            Assert-True ($content.Contains('AuthenticationMethods publickey') -and $content.Contains('PubkeyAuthentication yes') -and $content.Contains('PasswordAuthentication no') -and $global:SftpFixture.KeyAcls -eq 1) 'Key mode regressed.'
        } else {
            Assert-True ($content.Contains('AuthenticationMethods password') -and $content.Contains('PasswordAuthentication yes') -and $content.Contains('PubkeyAuthentication no')) 'Password-only authentication was not configured.'
            Assert-True (-not (Test-Path "$caseRoot\instance_keys") -and $global:SftpFixture.KeyAcls -eq 0) 'Password mode created authorized key data.'
            Assert-True ($global:SftpFixture.Prompts -eq $(if ($mode -in @('supplied','resume')) { 0 } else { 1 })) 'Unexpected password prompt count.'
        }
        Assert-True (-not $content.Contains('fixture password')) 'A password was written to sshd_config.'
        if ($mode -eq 'global-access') {
            foreach ($path in @($caseRoot,"$caseRoot\files","$caseRoot\files\profile","$caseRoot\files\mpmissions")) {
                $rules=@($global:SftpFixture.Grants[$path].GetAccessRules($true,$false,[Security.Principal.SecurityIdentifier]) |
                    Where-Object { $_.IdentityReference.Value -eq 'S-1-5-21-1-2-3-2001' })
                $expected=if ($path -eq "$caseRoot\files") { [Security.AccessControl.FileSystemRights]::ReadAndExecute } else { [Security.AccessControl.FileSystemRights]::Modify }
                Assert-True ($rules.Count -eq 1 -and ($rules[0].FileSystemRights -band $expected) -eq $expected) 'Global SFTP account lost its required access.'
                if ($path -eq "$caseRoot\files") { Assert-True (-not ($rules[0].FileSystemRights -band [Security.AccessControl.FileSystemRights]::WriteData)) 'Global SFTP grant made the chroot root writable.' }
            }
        }
    }
    Write-Host "Passed $script:checks SFTP setup checks. No real users, ACLs, sshd configuration, or services changed."
} finally {
    Remove-Variable SftpFixture -Scope Global -ErrorAction SilentlyContinue
    $resolved=[IO.Path]::GetFullPath($fixture)
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -notlike 'arma-sftp-tests-*') { throw 'Unsafe test cleanup path.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
