#Requires -Version 5.1
<#
.SYNOPSIS
    Imports an Arma 3 Launcher HTML preset file into a server profile.

.DESCRIPTION
    Parses an Arma 3 Launcher mod preset (.html) exported from the Arma 3 Launcher
    and writes the Workshop IDs and mod folder names into a profile's profile.json.

    After importing, run Sync-Mods.ps1 to download the mods.

.PARAMETER PresetFile
    Path to the Arma 3 Launcher HTML preset file.

.PARAMETER Profile
    Target profile name (folder under profiles\). The profile must already exist.
    Use _template to preview without writing (combine with -WhatIf).

.PARAMETER Merge
    If set, adds mods from the preset to the profile's existing WorkshopIds list
    (deduplicating by Workshop ID). By default, the existing list is replaced.

.PARAMETER SyncAfter
    Automatically run Sync-Mods.ps1 after a successful import.

.PARAMETER WhatIf
    Show what would be imported without writing any changes.

.EXAMPLE
    # Import into the main profile (replaces mod list)
    .\Import-Preset.ps1 -PresetFile "C:\Users\me\Downloads\MyPreset.html" -Profile main

    # Merge new mods into the tvt profile without removing existing ones
    .\Import-Preset.ps1 -PresetFile "C:\Users\me\Downloads\MyPreset.html" -Profile tvt -Merge

    # Preview what would be imported
    .\Import-Preset.ps1 -PresetFile "C:\Users\me\Downloads\MyPreset.html" -Profile main -WhatIf

    # Import and immediately download all mods
    .\Import-Preset.ps1 -PresetFile "C:\Users\me\Downloads\MyPreset.html" -Profile main -SyncAfter
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$PresetFile,

    [Parameter(Mandatory)]
    [string]$Profile,

    [switch]$Merge,

    [switch]$SyncAfter
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------
$ScriptRoot    = Split-Path -Parent $MyInvocation.MyCommand.Path
$FrameworkRoot = Split-Path -Parent $ScriptRoot
. (Join-Path $FrameworkRoot "scripts\Common.ps1")

$RequiredServerMods = @()

function Add-UniqueString {
    param(
        [string[]]$Items,
        [string[]]$Required
    )

    $result = @()
    $seen = @{}

    foreach ($item in @($Items + $Required)) {
        if ([string]::IsNullOrWhiteSpace($item)) { continue }
        $key = $item.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $result += $item
    }

    return [string[]]$result
}

# ---------------------------------------------------------------------------
# Validate input file
# ---------------------------------------------------------------------------
if (-not (Test-Path $PresetFile)) {
    Write-Log "Preset file not found: '$PresetFile'" "Error"
    exit 1
}

$extension = [System.IO.Path]::GetExtension($PresetFile).ToLower()
if ($extension -notin @(".html", ".htm")) {
    Write-Log "Expected an .html file, got: $extension" "Error"
    exit 1
}

# ---------------------------------------------------------------------------
# Parse the HTML (it is valid XML, exported by the Arma 3 Launcher)
# ---------------------------------------------------------------------------
Write-Log "Parsing preset: $(Split-Path -Leaf $PresetFile)" "Info"

if ((Get-Item -LiteralPath $PresetFile).Length -gt 2MB) { throw 'Preset exceeds 2 MiB.' }
$settings = [Xml.XmlReaderSettings]::new()
$settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
$settings.XmlResolver = $null
$settings.MaxCharactersInDocument = 2MB
$reader = [Xml.XmlReader]::Create([IO.Path]::GetFullPath($PresetFile), $settings)
try {
    $doc = [Xml.XmlDocument]::new()
    $doc.XmlResolver = $null
    $doc.Load($reader)
} finally { $reader.Dispose() }

# Find all <tr data-type="ModContainer"> elements
$modRows = $doc.SelectNodes("//tr[@data-type='ModContainer']")

if ($modRows.Count -eq 0) {
    Write-Log "No mods found in preset file. Make sure this is a valid Arma 3 Launcher preset." "Error"
    exit 1
}

Write-Log "Found $($modRows.Count) mod(s) in preset." "Info"

# ---------------------------------------------------------------------------
# Extract Workshop IDs and display names
# ---------------------------------------------------------------------------
function ConvertTo-FolderName {
    <#
    .SYNOPSIS
        Converts a mod display name to a safe @FolderName.
    #>
    param([string]$DisplayName)

    # Remove/replace characters that are unsafe in Windows folder names
    $safe = $DisplayName.Trim()
    $safe = $safe -replace '[:\\/*?"<>|]', ''   # forbidden Windows chars
    $safe = $safe -replace '[\s\-]+', '_'        # spaces and hyphens -> underscore
    $safe = $safe -replace '[^\w]', ''           # remove remaining non-word chars
    $safe = $safe -replace '_+', '_'             # collapse multiple underscores
    $safe = $safe.Trim('_')                      # strip leading/trailing underscores
    $safe = $safe.ToLower()

    return "@$safe"
}

$parsed = [System.Collections.Generic.List[hashtable]]::new()

foreach ($row in $modRows) {
    # DisplayName cell
    $nameNode  = $row.SelectSingleNode("td[@data-type='DisplayName']")
    $linkNode  = $row.SelectSingleNode(".//a[@data-type='Link']")

    if (-not $nameNode -or -not $linkNode) { continue }

    $displayName = $nameNode.InnerText.Trim()
    $url         = $linkNode.InnerText.Trim()

    # Extract Workshop ID from URL (?id=XXXXXXX)
    if ($url -match '[?&]id=(\d+)') {
        $workshopId = $Matches[1]
    } else {
        Write-Log "Could not extract Workshop ID from URL: $url  (skipping '$displayName')" "Warning"
        continue
    }

    $folderName = ConvertTo-FolderName -DisplayName $displayName

    $parsed.Add(@{
        Id          = $workshopId
        FolderName  = $folderName
        DisplayName = $displayName
    })
}

if ($parsed.Count -eq 0) {
    Write-Log "No valid mods could be parsed from the preset." "Error"
    exit 1
}

# ---------------------------------------------------------------------------
# Show what was parsed
# ---------------------------------------------------------------------------
Write-Log "" "Info"
Write-Log "=== Parsed Mods ===" "Header"
$parsed | ForEach-Object {
    Write-Log ("  [{0,-12}]  {1,-38}  {2}" -f $_.Id, $_.FolderName, $_.DisplayName) "Info"
}
Write-Log "" "Info"

# ---------------------------------------------------------------------------
# WhatIf / dry run
# ---------------------------------------------------------------------------
if ($WhatIfPreference) {
    Write-Log "WhatIf: no changes written." "Warning"
    exit 0
}

# ---------------------------------------------------------------------------
# Load target profile
# ---------------------------------------------------------------------------
$lock = Enter-FrameworkMaintenanceLock -Config (Get-FrameworkConfig) -Purpose "preset-import:$Profile"
if (-not $lock) { throw 'Another framework operation is running.' }
try {
$prof        = Get-Profile -ProfileName $Profile
if ($prof.SelectedPreset) { throw 'Select the default preset before importing a new base mod list.' }
$RequiredServerMods = @((Get-OptionalValue $prof 'RequiredServerMods' @()))
$profileFile = Join-Path $prof.ProfileDir "profile.json"

$profileData = Get-Content $profileFile -Raw | ConvertFrom-Json
$catalog = Get-SharedWorkshopCatalog
foreach ($mod in $parsed) {
    if ($catalog.ContainsKey([string]$mod.Id)) { $mod.FolderName = $catalog[[string]$mod.Id] }
}

# ---------------------------------------------------------------------------
# Build updated WorkshopIds and Mods arrays
# ---------------------------------------------------------------------------
if ($Merge) {
    # Keep existing entries, add new ones (deduplicated by Id)
    $existingIds = @{}
    if ($profileData.PSObject.Properties.Name -contains "WorkshopIds") {
        foreach ($existing in $profileData.WorkshopIds) {
            $existingIds[$existing.Id] = $true
        }
    }

    $toAdd = @($parsed | Where-Object { -not $existingIds.ContainsKey($_.Id) })
    Write-Log "Merge mode: adding $($toAdd.Count) new mod(s), keeping $($existingIds.Count) existing." "Info"

    $newWorkshopIds = @()
    if ($profileData.PSObject.Properties.Name -contains "WorkshopIds") {
        $newWorkshopIds += @($profileData.WorkshopIds)
    }
    foreach ($mod in $toAdd) {
        $newWorkshopIds += [PSCustomObject]@{
            Id         = $mod.Id
            FolderName = $mod.FolderName
            _name      = $mod.DisplayName
        }
    }
} else {
    # Replace the entire list
    Write-Log "Replace mode: replacing mod list with $($parsed.Count) mod(s) from preset." "Info"

    $newWorkshopIds = @($parsed | ForEach-Object {
        [PSCustomObject]@{
            Id         = $_.Id
            FolderName = $_.FolderName
            _name      = $_.DisplayName
        }
    })
}

# Build Mods array (just the folder names, for -mod= parameter).
# Client-side GRP9 mods are published through Steam Workshop and should come
# from the imported preset instead of being forced into every profile.
$newMods = @(Add-UniqueString `
    -Items ([string[]]($newWorkshopIds | Select-Object -ExpandProperty FolderName)) `
    -Required @())

# ---------------------------------------------------------------------------
# Write updated profile.json
# ---------------------------------------------------------------------------
$profileData | Add-Member -NotePropertyName "WorkshopIds" -NotePropertyValue $newWorkshopIds -Force
$profileData | Add-Member -NotePropertyName "Mods"        -NotePropertyValue $newMods        -Force
$null = Get-SharedWorkshopCatalog -AdditionalEntries $newWorkshopIds

$existingServerMods = @()
if ($profileData.PSObject.Properties.Name -contains "ServerMods") {
    $existingServerMods = @($profileData.ServerMods | Where-Object { $_ })
}
$existingServerMods = @(Add-UniqueString `
    -Items ([string[]]$existingServerMods) `
    -Required $RequiredServerMods)

# Preserve all operator-owned metadata, including Isolated, Presets and limits.
$profileData | Add-Member -NotePropertyName 'ServerMods' -NotePropertyValue $existingServerMods -Force
    if (@(Get-InstanceProcesses $prof).Count -gt 0) { throw 'Stop this instance before changing its base preset.' }
    $profileData | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath "$profileFile.tmp" -Encoding UTF8
    Move-Item -LiteralPath "$profileFile.tmp" -Destination $profileFile -Force
} finally { Exit-FrameworkMaintenanceLock -Lock $lock -Config (Get-FrameworkConfig) }

Write-Log "profile.json updated: $profileFile" "Success"
Write-Log "  WorkshopIds : $($newWorkshopIds.Count) mods" "Info"
Write-Log "  Mods[]      : $($newMods.Count) folder names" "Info"
Write-Log "  ServerMods  : $($existingServerMods.Count) folder names" "Info"
Write-Log "  Required server mods: $($RequiredServerMods -join ', ')" "Info"

# ---------------------------------------------------------------------------
# Optional: run Sync-Mods.ps1 immediately
# ---------------------------------------------------------------------------
if ($SyncAfter) {
    Write-Log "" "Info"
    Write-Log "=== Starting Sync-Mods.ps1 -Profile $Profile ===" "Header"
    $syncScript = Join-Path $ScriptRoot "Sync-Mods.ps1"
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $syncScript -Profile $Profile
    if ($LASTEXITCODE -ne 0) { throw 'The preset was imported, but Workshop synchronization failed.' }
}

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Write-Log "" "Info"
Write-Log "=== Import Complete ===" "Header"
Write-Log "Next step: .\mods\Sync-Mods.ps1 -Profile $Profile" "Info"
