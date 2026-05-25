#Requires -Version 5.1
<#
.SYNOPSIS
    Downloads Steam Workshop mods and deploys them to the Arma 3 server.

.DESCRIPTION
    For each Workshop ID defined in a profile's profile.json:
      1. Downloads the mod via SteamCMD (App ID 107410, requires Arma 3 ownership)
      2. Moves/copies the mod folder to the server install directory as @<FolderName>
      3. Copies all .bikey files to <ServerInstallPath>\keys\

.PARAMETER Profile
    Profile name to load mod list from (e.g. "main", "tvt").
    Use -Profile _all to sync every profile's mods combined.

.PARAMETER WorkshopId
    Download a single mod by Workshop ID without reading a profile.
    Requires -FolderName.

.PARAMETER FolderName
    Target folder name for a single mod (used with -WorkshopId).

.PARAMETER Force
    Re-download mods even if the folder already exists.

.EXAMPLE
    .\Sync-Mods.ps1 -Profile main
    .\Sync-Mods.ps1 -Profile tvt -Force
    .\Sync-Mods.ps1 -WorkshopId 450814997 -FolderName @cba_a3
#>

[CmdletBinding(DefaultParameterSetName = "Profile")]
param(
    [Parameter(ParameterSetName = "Profile", Mandatory)]
    [string]$Profile,

    [Parameter(ParameterSetName = "Single", Mandatory)]
    [string]$WorkshopId,

    [Parameter(ParameterSetName = "Single", Mandatory)]
    [string]$FolderName,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------
$ScriptRoot    = Split-Path -Parent $MyInvocation.MyCommand.Path
$FrameworkRoot = Split-Path -Parent $ScriptRoot
. (Join-Path $FrameworkRoot "scripts\Common.ps1")

$Config    = Get-FrameworkConfig
$SteamCmd  = Join-Path $Config.SteamCMDPath "steamcmd.exe"

if (-not (Test-Path $SteamCmd)) {
    Write-Log "steamcmd.exe not found at '$SteamCmd'. Run .\setup\Install-Framework.ps1 first." "Error"
    exit 1
}

# ---------------------------------------------------------------------------
# Build the list of mods to download
# ---------------------------------------------------------------------------

# Each entry: hashtable with keys WorkshopId (string) and FolderName (string)
$modList = @()

if ($PSCmdlet.ParameterSetName -eq "Single") {
    $modList += @{ WorkshopId = $WorkshopId; FolderName = $FolderName }
} else {
    if ($Profile -eq "_all") {
        # Collect mods from every profile (deduplicated by WorkshopId)
        $profiles = Get-AvailableProfiles
        $seen     = @{}
        foreach ($p in $profiles) {
            $prof = Get-Profile -ProfileName $p
            if ($prof.PSObject.Properties.Name -contains "WorkshopIds") {
                foreach ($entry in $prof.WorkshopIds) {
                    if (-not $seen.ContainsKey($entry.Id)) {
                        $seen[$entry.Id] = $true
                        $modList += @{ WorkshopId = $entry.Id; FolderName = $entry.FolderName }
                    }
                }
            }
        }
    } else {
        $prof = Get-Profile -ProfileName $Profile
        if (-not ($prof.PSObject.Properties.Name -contains "WorkshopIds") -or
            $prof.WorkshopIds.Count -eq 0) {
            Write-Log "Profile '$Profile' has no WorkshopIds defined in profile.json." "Warning"
            exit 0
        }
        foreach ($entry in $prof.WorkshopIds) {
            $modList += @{ WorkshopId = $entry.Id; FolderName = $entry.FolderName }
        }
    }
}

if ($modList.Count -eq 0) {
    Write-Log "No mods to download." "Info"
    exit 0
}

Write-Log "=== Mod Sync: $($modList.Count) mod(s) ===" "Header"

# ---------------------------------------------------------------------------
# Steam credentials
# ---------------------------------------------------------------------------
$steamUser = $Config.SteamUsername
$steamPass = Read-SteamPassword -Username $steamUser -Config $Config

# ---------------------------------------------------------------------------
# Download each mod
# ---------------------------------------------------------------------------
$stagingRoot = Join-Path $Config.WorkshopStagingPath "steamapps\workshop\content\107410"
$keysDir     = Join-Path $Config.ServerInstallPath "keys"
New-Item -ItemType Directory -Path $keysDir -Force | Out-Null

$success = 0
$failed  = 0

foreach ($mod in $modList) {
    $wid        = $mod.WorkshopId
    $targetName = $mod.FolderName
    $targetDir  = Join-Path $Config.ServerInstallPath $targetName

    Write-Log "---" "Info"
    Write-Log "Mod       : $targetName  (ID: $wid)" "Info"

    # Skip if already deployed and not forced
    if ((Test-Path $targetDir) -and -not $Force) {
        Write-Log "Already deployed at '$targetDir'. Use -Force to re-download." "Info"
        $success++
        continue
    }

    # --- SteamCMD download (via script file to handle special chars in password) ---
    Write-Log "Downloading from Workshop..." "Info"

    $exitCode = Invoke-SteamCMD -SteamCMDExe $SteamCmd `
                                 -Username $steamUser `
                                 -Password $steamPass `
                                 -Commands @(
                                     "force_install_dir `"$($Config.WorkshopStagingPath)`""
                                     "workshop_download_item 107410 $wid validate"
                                 )

    if ($exitCode -ne 0) {
        Write-Log "SteamCMD failed for mod $wid (exit code $exitCode)." "Error"
        $failed++
        continue
    }

    $downloadedPath = Join-Path $stagingRoot $wid

    if (-not (Test-Path $downloadedPath)) {
        Write-Log "Downloaded folder not found at '$downloadedPath'. Download may have failed." "Error"
        $failed++
        continue
    }

    # --- Deploy: copy to server directory ---
    Write-Log "Deploying to '$targetDir'..." "Info"

    if (Test-Path $targetDir) {
        Remove-Item $targetDir -Recurse -Force
    }

    Copy-Item -Path $downloadedPath -Destination $targetDir -Recurse -Force
    Write-Log "Deployed: $targetName" "Success"

    # Normalize all file and folder names to lowercase (Arma 3 is case-sensitive on Linux
    # and some tools expect lowercase; on Windows this is a no-op but keeps things clean)
    Get-ChildItem -Path $targetDir -Recurse | ForEach-Object {
        $lower = $_.FullName.Replace($_.Name, $_.Name.ToLower())
        if ($_.FullName -cne $lower) {
            Rename-Item -Path $_.FullName -NewName $_.Name.ToLower() -ErrorAction SilentlyContinue
        }
    }

    # --- Copy .bikey files to keys\ ---
    $bikeys = Get-ChildItem -Path $targetDir -Recurse -Filter "*.bikey"
    if ($bikeys.Count -gt 0) {
        foreach ($key in $bikeys) {
            $dest = Join-Path $keysDir $key.Name
            Copy-Item -Path $key.FullName -Destination $dest -Force
            Write-Log "  Key copied: $($key.Name)" "Info"
        }
    } else {
        Write-Log "  No .bikey files found in $targetName." "Warning"
    }

    $success++
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Log "" "Info"
Write-Log "=== Sync Complete ===" "Header"
Write-Log "  Success : $success" "Success"
if ($failed -gt 0) {
    Write-Log "  Failed  : $failed" "Error"
}
Write-Log "  Keys dir: $keysDir" "Info"

if ($failed -gt 0) {
    exit 1
}
