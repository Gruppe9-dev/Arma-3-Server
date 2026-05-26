<#
.SYNOPSIS
    One-time setup: generates an SSH key pair for the Discord bot container
    and registers it on the Windows host for a dedicated bot user.

.DESCRIPTION
    Run this script ONCE on the Windows host before starting the Docker container.
    It will:
      1. Create a dedicated local Windows user 'arma_bot' (no password, key-only SSH)
      2. Generate an ed25519 SSH key pair in ./bot/ (ssh_key + ssh_key.pub)
      3. Register the public key in the user's authorized_keys
      4. Grant the user read+execute rights on the framework scripts folder

    After running this script:
      - Set BOT_SSH_USER=arma_bot in your .env
      - Start the container: docker compose up -d

.PARAMETER ScriptsPath
    Absolute path to this repository on the host.
    Defaults to the parent folder of this script.

.PARAMETER BotUser
    Windows username to create for the Discord bot. Default: arma_bot
#>
param(
    [string]$ScriptsPath = (Split-Path -Parent $PSScriptRoot),
    [string]$BotUser     = "arma_bot"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step { param([string]$Msg) Write-Host "`n==> $Msg" -ForegroundColor Cyan }
function Write-OK   { param([string]$Msg) Write-Host "    [OK] $Msg"  -ForegroundColor Green }
function Write-Warn { param([string]$Msg) Write-Host "    [WARN] $Msg" -ForegroundColor Yellow }

# ── 1. Create bot Windows user ─────────────────────────────────────────────────
Write-Step "Creating local user '$BotUser'"

if (Get-LocalUser -Name $BotUser -ErrorAction SilentlyContinue) {
    Write-Warn "User '$BotUser' already exists. Skipping creation."
} else {
    # No password – SSH key-only authentication
    $secure = New-Object System.Security.SecureString
    New-LocalUser -Name $BotUser -Password $secure -PasswordNeverExpires -UserMayNotChangePassword `
        -Description "Arma 3 Discord Bot (key-only)" | Out-Null
    Write-OK "User '$BotUser' created."
}

# ── 2. Generate SSH key pair ───────────────────────────────────────────────────
Write-Step "Generating SSH key pair"

$keyDir    = Join-Path $PSScriptRoot ""
$keyFile   = Join-Path $keyDir "ssh_key"
$pubFile   = "$keyFile.pub"

if (Test-Path $keyFile) {
    Write-Warn "Key file '$keyFile' already exists. Skipping key generation."
} else {
    # Requires OpenSSH client tools (ssh-keygen)
    & ssh-keygen -t ed25519 -f $keyFile -N "" -q
    if ($LASTEXITCODE -ne 0) { throw "ssh-keygen failed (exit $LASTEXITCODE)" }
    Write-OK "Key pair generated: $keyFile"
}

# ── 3. Register public key in authorized_keys ──────────────────────────────────
Write-Step "Registering public key for '$BotUser'"

$pubKeyContent = Get-Content $pubFile -Raw

# For admin users, OpenSSH uses C:\ProgramData\ssh\administrators_authorized_keys
# For non-admin users, it's %USERPROFILE%\.ssh\authorized_keys
$userProfile      = "C:\Users\$BotUser"
$sshDir           = Join-Path $userProfile ".ssh"
$authorizedKeys   = Join-Path $sshDir "authorized_keys"

if (-not (Test-Path $sshDir)) {
    New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
}

$existing = if (Test-Path $authorizedKeys) { Get-Content $authorizedKeys -Raw } else { "" }
$trimmedKey = $pubKeyContent.Trim()

if ($existing -match [regex]::Escape($trimmedKey)) {
    Write-Warn "Public key already registered."
} else {
    Add-Content -Path $authorizedKeys -Value $trimmedKey
    Write-OK "Public key added to '$authorizedKeys'."
}

# Fix permissions: only SYSTEM + BotUser should have access (OpenSSH requirement)
icacls $authorizedKeys /inheritance:r /grant "${BotUser}:(F)" /grant "SYSTEM:(F)" | Out-Null
Write-OK "Permissions set on authorized_keys."

# ── 4. NTFS permissions on the scripts directory ───────────────────────────────
Write-Step "Granting '$BotUser' read+execute on '$ScriptsPath'"

icacls $ScriptsPath /grant "${BotUser}:(OI)(CI)RX" | Out-Null
Write-OK "NTFS permissions granted."

# ── Summary ────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host " Setup complete. Next steps:" -ForegroundColor Green
Write-Host ""
Write-Host " 1. Add to your .env:" -ForegroundColor White
Write-Host "      BOT_SSH_USER=$BotUser" -ForegroundColor Yellow
Write-Host "      BOT_SSH_HOST=host.docker.internal" -ForegroundColor Yellow
Write-Host "      BOT_SSH_KEY_PATH=/app/ssh_key" -ForegroundColor Yellow
Write-Host "      BOT_SCRIPTS_PATH=$ScriptsPath" -ForegroundColor Yellow
Write-Host ""
Write-Host " 2. Start the container:" -ForegroundColor White
Write-Host "      docker compose up -d" -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Green
