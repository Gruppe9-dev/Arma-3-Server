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
                foreach ($entry in @($prof.WorkshopIds)) {
                    if (-not $seen.ContainsKey($entry.Id)) {
                        $seen[$entry.Id] = $true
                        $modList += @{ WorkshopId = $entry.Id; FolderName = $entry.FolderName }
                    }
                }
            }
        }
    } else {
        $prof = Get-Profile -ProfileName $Profile
        $workshopIds = @($prof.WorkshopIds)
        if (-not ($prof.PSObject.Properties.Name -contains "WorkshopIds") -or
            $workshopIds.Count -eq 0) {
            Write-Log "Profile '$Profile' has no WorkshopIds defined in profile.json." "Warning"
            exit 0
        }
        foreach ($entry in $workshopIds) {
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
# Split modList into: needs download vs already deployed
# ---------------------------------------------------------------------------
$stagingRoot = Join-Path $Config.WorkshopStagingPath "steamapps\workshop\content\107410"
$keysDir     = Join-Path $Config.ServerInstallPath "keys"
New-Item -ItemType Directory -Path $keysDir -Force | Out-Null

$toDownload = @()
$success    = 0
$failed     = 0

foreach ($mod in $modList) {
    $targetDir = Join-Path $Config.ServerInstallPath $mod.FolderName
    # A folder that exists but is empty counts as not-deployed (e.g. left over from a failed copy)
    $hasFiles  = (Test-Path $targetDir) -and (@(Get-ChildItem -Path $targetDir -Recurse -File -ErrorAction SilentlyContinue).Count -gt 0)
    if ($hasFiles -and -not $Force) {
        Write-Log "Already deployed: $($mod.FolderName)  (ID: $($mod.WorkshopId))" "Info"
        $success++
    } else {
        $toDownload += $mod
    }
}

# ---------------------------------------------------------------------------
# Batch-download all missing mods in a single SteamCMD session
# ---------------------------------------------------------------------------
if ($toDownload.Count -gt 0) {
    Write-Log "" "Info"
    Write-Log "=== Downloading $($toDownload.Count) mod(s) in one SteamCMD session ===" "Header"

    $dlCommands = @("force_install_dir `"$($Config.WorkshopStagingPath)`"")
    foreach ($mod in $toDownload) {
        Write-Log "  Queued: $($mod.FolderName)  (ID: $($mod.WorkshopId))" "Info"
        $dlCommands += "workshop_download_item 107410 $($mod.WorkshopId) validate"
    }

    $exitCode = Invoke-SteamCMD -SteamCMDExe $SteamCmd `
                                 -Username $steamUser `
                                 -Password $steamPass `
                                 -Commands $dlCommands

    if ($exitCode -ne 0) {
        Write-Log "SteamCMD batch download exited with code $exitCode." "Error"
        Write-Log "Some mods may have failed. Check output above." "Warning"
    }

    Write-Log "" "Info"
    Write-Log "=== Deploying downloaded mods ===" "Header"

    # ---------------------------------------------------------------------------
    # Deploy each downloaded mod
    # ---------------------------------------------------------------------------
    foreach ($mod in $toDownload) {
        $wid            = $mod.WorkshopId
        $targetName     = $mod.FolderName
        $targetDir      = Join-Path $Config.ServerInstallPath $targetName
        $downloadedPath = Join-Path $stagingRoot $wid

        Write-Log "---" "Info"
        Write-Log "Mod : $targetName  (ID: $wid)" "Info"

        if (-not (Test-Path $downloadedPath)) {
            Write-Log "Downloaded folder not found at '$downloadedPath'. Skipping." "Error"
            $failed++
            continue
        }

        # Deploy: copy to server directory
        Write-Log "Deploying to '$targetDir'..." "Info"
        if (Test-Path $targetDir) {
            Remove-Item $targetDir -Recurse -Force
        }
        Copy-Item -Path $downloadedPath -Destination $targetDir -Recurse -Force
        Write-Log "Deployed: $targetName" "Success"

        # Copy .bikey files to keys\
        $bikeys = @(Get-ChildItem -Path $targetDir -Recurse -Filter "*.bikey")
        if ($bikeys.Count -gt 0) {
            foreach ($key in $bikeys) {
                Copy-Item -Path $key.FullName -Destination (Join-Path $keysDir $key.Name) -Force
                Write-Log "  Key copied: $($key.Name)" "Info"
            }
        } else {
            Write-Log "  No .bikey files found in $targetName." "Warning"
        }

        $success++
    }
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
