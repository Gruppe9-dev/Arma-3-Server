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
}
function New-LocalUser {
    param($Name,[securestring]$Password,[switch]$Disabled,[switch]$PasswordNeverExpires,[switch]$UserMayNotChangePassword,$Description)
    if (-not $Disabled -or $Password.Length -eq 0) { throw 'Account was not created disabled with a nonempty SecureString.' }
    $global:SftpFixture.Created++
    [PSCustomObject]@{ SID=[Security.Principal.SecurityIdentifier]::new('S-1-5-21-1-2-3-1002') }
}
function Disable-LocalUser { param($Name) $global:SftpFixture.Disabled++ }
function Enable-LocalUser { param($Name) $global:SftpFixture.Enabled++ }
function Set-Acl { param($LiteralPath,$AclObject) $global:SftpFixture.Acls++ }
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
    $settings=@{}
    foreach ($line in Get-Content -LiteralPath $args[2]) {
        if ($line -match '^\s+([a-zA-Z]+) (.+)$') { $settings[$Matches[1].ToLowerInvariant()]=$Matches[2] }
    }
    if ($global:SftpFixture.Failure -eq 'override') { $settings['passwordauthentication']='no' }
    foreach ($key in $settings.Keys) { "$key $($settings[$key])" }
}
'@ | Set-Content "$fixture\scripts\Common.ps1" -Encoding UTF8
    foreach ($mode in @('preview','password','supplied','key','override','restart','mixed')) {
        $caseRoot=Join-Path $fixture $mode
        New-Item -ItemType Directory -Path "$caseRoot\files\profile","$caseRoot\files\mpmissions" -Force | Out-Null
        $global:SftpFixture=@{ Root=$caseRoot; Created=0; Disabled=0; Enabled=0; Acls=0; KeyAcls=0; Restarts=0; Prompts=0; Failure=$mode }
        $configPath=Join-Path $caseRoot 'sshd_config'
        $original="PasswordAuthentication no`r`n# Existing bot policy must remain intact`r`n"
        [IO.File]::WriteAllText($configPath,$original)
        $keyPath=Join-Path $caseRoot 'fixture.pub'
        Set-Content $keyPath 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAA fixture'
        $parameters=@{ Profile='friend'; SftpUser='friend_sftp'; BotUser='arma_bot'; SshdConfig=$configPath }
        if ($mode -eq 'key') { $parameters.PublicKeyFile=$keyPath } else { $parameters.UsePassword=$true }
        if ($mode -eq 'mixed') { $parameters.PublicKeyFile=$keyPath }
        if ($mode -eq 'supplied') { $parameters.Password=ConvertTo-SecureString 'Supplied fixture password 456!' -AsPlainText -Force }
        if ($mode -eq 'preview') { $parameters.WhatIf=$true }
        $errorMessage=''
        try { & "$fixture\setup\Configure-InstanceSFTP.ps1" @parameters } catch { $errorMessage=$_.Exception.Message }
        $content=[IO.File]::ReadAllText($configPath)
        if ($mode -in @('override','restart','mixed')) {
            Assert-True ($errorMessage.Length -gt 0) "$mode did not reject the failed setup."
            Assert-True ($global:SftpFixture.Enabled -eq 0 -and $content -eq $original) "$mode enabled an account or changed the original config."
            if ($mode -eq 'mixed') { Assert-True ($global:SftpFixture.Created -eq 0) 'Mixed authentication parameters created an account.' }
            continue
        }
        Assert-True ($errorMessage -eq '') "$mode failed: $errorMessage"
        if ($mode -eq 'preview') {
            Assert-True ($global:SftpFixture.Prompts -eq 0 -and $global:SftpFixture.Created -eq 0 -and $global:SftpFixture.Acls -eq 0 -and $global:SftpFixture.Restarts -eq 0 -and $content -eq $original) 'WhatIf prompted or mutated host state.'
            continue
        }
        Assert-True ($global:SftpFixture.Created -eq 1 -and $global:SftpFixture.Enabled -eq 1 -and $global:SftpFixture.Restarts -eq 1) "$mode did not complete provisioning."
        Assert-True ($content.StartsWith($original) -and $content.Contains('ForceCommand internal-sftp') -and $content.Contains('AllowTcpForwarding no') -and $content.Contains('PermitTTY no')) 'Existing SSH policy or confinement was changed.'
        if ($mode -eq 'key') {
            Assert-True ($content.Contains('AuthenticationMethods publickey') -and $content.Contains('PubkeyAuthentication yes') -and $content.Contains('PasswordAuthentication no') -and $global:SftpFixture.KeyAcls -eq 1) 'Key mode regressed.'
        } else {
            Assert-True ($content.Contains('AuthenticationMethods password') -and $content.Contains('PasswordAuthentication yes') -and $content.Contains('PubkeyAuthentication no')) 'Password-only authentication was not configured.'
            Assert-True (-not (Test-Path "$caseRoot\instance_keys") -and $global:SftpFixture.KeyAcls -eq 0) 'Password mode created authorized key data.'
            Assert-True ($global:SftpFixture.Prompts -eq $(if ($mode -eq 'supplied') { 0 } else { 1 })) 'Unexpected password prompt count.'
        }
        Assert-True (-not $content.Contains('fixture password')) 'A password was written to sshd_config.'
    }
    Write-Host "Passed $script:checks SFTP setup checks. No real users, ACLs, sshd configuration, or services changed."
} finally {
    Remove-Variable SftpFixture -Scope Global -ErrorAction SilentlyContinue
    $resolved=[IO.Path]::GetFullPath($fixture)
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -notlike 'arma-sftp-tests-*') { throw 'Unsafe test cleanup path.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
