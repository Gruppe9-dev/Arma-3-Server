<#
.SYNOPSIS
    Sets up a restricted SFTP user for mission creators.

.DESCRIPTION
    Assumes Windows OpenSSH Server is already running (required by the framework's MCP setup).
    This script:
      1. Creates a dedicated local Windows user 'mission_sftp'
      2. Sets a password for the user (prompted interactively or via -Password parameter)
      3. Adds a ChrootDirectory Match block to sshd_config (SFTP-only, no shell access)
      4. Sets NTFS permissions: write access to mpmissions\, read access to profiles\
      5. Restarts the sshd service to apply changes

    Mission creators connect via SFTP (e.g. WinSCP / FileZilla):
      Host:     <server-ip>
      Port:     22
      Protocol: SFTP
      User:     mission_sftp
      Password: <as configured below>

.PARAMETER SftpUser
    Windows username for the SFTP account. Default: mission_sftp

.PARAMETER Password
    Password for the SFTP user. If omitted, you will be prompted interactively.

.PARAMETER ServerInstallPath
    Path to the Arma 3 server installation (must contain mpmissions\).
    Defaults to the SERVER_INSTALL_PATH from .env in the parent folder.

.PARAMETER FrameworkPath
    Path to this repository root. Defaults to the parent folder of this script.
#>
param(
    [string]$SftpUser          = "mission_sftp",
    [securestring]$Password    = $null,
    [string]$ServerInstallPath = "",
    [string]$FrameworkPath     = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step { param([string]$Msg) Write-Host "`n==> $Msg" -ForegroundColor Cyan }
function Write-OK   { param([string]$Msg) Write-Host "    [OK] $Msg"  -ForegroundColor Green }
function Write-Warn { param([string]$Msg) Write-Host "    [WARN] $Msg" -ForegroundColor Yellow }

# ── Load SERVER_INSTALL_PATH from .env if not provided ─────────────────────────
if (-not $ServerInstallPath) {
    $envFile = Join-Path $FrameworkPath ".env"
    if (Test-Path $envFile) {
        foreach ($line in Get-Content $envFile) {
            if ($line -match "^\s*SERVER_INSTALL_PATH\s*=\s*`"?([^`"]+)`"?\s*$") {
                $ServerInstallPath = $Matches[1].Trim()
                break
            }
        }
    }
    if (-not $ServerInstallPath) {
        throw "Could not determine SERVER_INSTALL_PATH. Pass it as -ServerInstallPath or set it in .env."
    }
}

$MissionPath  = Join-Path $ServerInstallPath "mpmissions"
$ProfilesPath = $FrameworkPath   # the repo root acts as the chroot base for profiles\

Write-Host "Framework : $FrameworkPath"
Write-Host "Server    : $ServerInstallPath"
Write-Host "Missions  : $MissionPath"

# ── 1. Create SFTP user ────────────────────────────────────────────────────────
Write-Step "Creating local user '$SftpUser'"

if (-not $Password) {
    $Password = Read-Host "Password for '$SftpUser'" -AsSecureString
}

if (Get-LocalUser -Name $SftpUser -ErrorAction SilentlyContinue) {
    Write-Warn "User '$SftpUser' already exists. Updating password."
    Set-LocalUser -Name $SftpUser -Password $Password
} else {
    New-LocalUser -Name $SftpUser -Password $Password -PasswordNeverExpires `
        -Description "Arma 3 Mission Creator SFTP access" | Out-Null
    Write-OK "User '$SftpUser' created."
}

# ── 2. Ensure mpmissions folder exists ────────────────────────────────────────
Write-Step "Ensuring mpmissions directory exists"
if (-not (Test-Path $MissionPath)) {
    New-Item -ItemType Directory -Path $MissionPath -Force | Out-Null
    Write-OK "Created: $MissionPath"
} else {
    Write-OK "Already exists: $MissionPath"
}

# ── 3. NTFS permissions ────────────────────────────────────────────────────────
Write-Step "Setting NTFS permissions"

# mpmissions: read + write (upload / download missions)
icacls $MissionPath /grant "${SftpUser}:(OI)(CI)M" | Out-Null
Write-OK "mpmissions\ → $SftpUser: Modify"

# profiles: read-only (view profile configs, no editing)
icacls $ProfilesPath /grant "${SftpUser}:(OI)(CI)RX" | Out-Null
Write-OK "profiles\   → $SftpUser: Read+Execute"

# ── 4. Update sshd_config ──────────────────────────────────────────────────────
Write-Step "Updating sshd_config"

$sshdConfig = "C:\ProgramData\ssh\sshd_config"
if (-not (Test-Path $sshdConfig)) {
    throw "sshd_config not found at '$sshdConfig'. Is OpenSSH Server installed and running?"
}

$matchBlock = @"

# ── Arma 3 Mission Creator SFTP (added by Configure-SFTP.ps1) ──────────────────
Match User $SftpUser
    ForceCommand internal-sftp
    ChrootDirectory "$ServerInstallPath"
    PermitTunnel no
    AllowAgentForwarding no
    AllowTcpForwarding no
    X11Forwarding no
"@

$existing = Get-Content $sshdConfig -Raw

if ($existing -match "Match User $([regex]::Escape($SftpUser))") {
    Write-Warn "Match block for '$SftpUser' already present in sshd_config. Skipping."
} else {
    Add-Content -Path $sshdConfig -Value $matchBlock
    Write-OK "Match block added to sshd_config."
}

# ── 5. Restart sshd ───────────────────────────────────────────────────────────
Write-Step "Restarting sshd service"
Restart-Service sshd -Force
Write-OK "sshd restarted."

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host " SFTP setup complete." -ForegroundColor Green
Write-Host ""
Write-Host " Mission creators can now connect via SFTP:" -ForegroundColor White
Write-Host "   Host     : <server-ip>" -ForegroundColor Yellow
Write-Host "   Port     : 22" -ForegroundColor Yellow
Write-Host "   Protocol : SFTP" -ForegroundColor Yellow
Write-Host "   User     : $SftpUser" -ForegroundColor Yellow
Write-Host "   Password : (as configured above)" -ForegroundColor Yellow
Write-Host ""
Write-Host " Accessible paths (relative to ChrootDirectory $ServerInstallPath):" -ForegroundColor White
Write-Host "   /mpmissions/   read+write (upload .pbo mission files here)" -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Green
