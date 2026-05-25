# Arma 3 Server Framework

A PowerShell-based server management framework for Arma 3 on Windows Server 2022.

## Features

- **One-command installation** – SteamCMD download, server install, branch selection
- **Profiling Branch support** – switch between `public` and `profiling` per profile
- **Workshop Mod Management** – download mods by Workshop ID, auto-deploy to server, auto-copy keys
- **Profile System** – multiple independent server configurations (different ports, mod sets, difficulty)
- **Headless Client automation** – start N Headless Clients automatically per profile
- **Clean separation** – framework scripts vs. server binaries vs. downloaded mods

---

## Prerequisites

- Windows Server 2022 (or Windows 10/11)
- PowerShell 5.1+ (pre-installed on Windows Server 2022)
- A Steam ccount athat **owns Arma 3** (required for Workshop downloads)
- Firewall: UDP ports **2302–2306** open inbound (adjust per profile port)

---

## Quick Start

### 1. Configure global settings

Copy `.env.example` to `.env` and fill in your values:

```powershell
Copy-Item .env.example .env
notepad .env
```

`.env` contents:

```dotenv
SERVER_INSTALL_PATH=D:\Arma3Server
STEAMCMD_PATH=D:\SteamCMD
WORKSHOP_STAGING_PATH=D:\Arma3Workshop

STEAM_USERNAME=your_steam_username

# Optional: avoids interactive password prompts (e.g. for scheduled tasks)
# STEAM_PASSWORD=your_password
```

> `.env` is listed in `.gitignore` and will never be committed.
> `framework.json` stays as a documented reference — actual values come from `.env`.

### 2. Install SteamCMD and the Arma 3 Dedicated Server

```powershell
.\setup\Install-Framework.ps1
```

This script:
- Downloads and extracts SteamCMD to `SteamCMDPath`
- Installs Arma 3 Dedicated Server (App ID 233780) to `ServerInstallPath`
- Uses the `public` branch by default (pass `-Branch profiling` to use the profiling branch)

### 3. Update the server (or switch branches)

```powershell
.\setup\Update-Server.ps1                     # update on current branch
.\setup\Update-Server.ps1 -Branch profiling   # switch to profiling branch
.\setup\Update-Server.ps1 -Branch public      # switch back to stable
```

### 4. Download and deploy Workshop mods

```powershell
.\mods\Sync-Mods.ps1 -Profile main
```

This script reads the `WorkshopIds` list from `profiles\main\profile.json`, downloads each mod via
SteamCMD, renames the folder to the configured `@name`, and copies `.bikey` files to the server's
`keys\` directory.

### 5. Start the server

```powershell
.\scripts\Start-Server.ps1 -Profile main
.\scripts\Start-Server.ps1 -Profile tvt
```

Headless Clients are started automatically if `HeadlessClientCount` is greater than 0 in the
profile.

### 6. Stop the server

```powershell
.\scripts\Stop-Server.ps1 -Profile main
```

---

## Directory Structure

```
Arma 3 Server\                    ← This repository
├── .env                           ← Your local config (git-ignored, copy from .env.example)
├── .env.example                   ← Config template (committed to version control)
├── .gitignore
├── README.md
├── setup\
│   ├── Install-Framework.ps1      ← First-time SteamCMD + server install
│   └── Update-Server.ps1          ← Server update / branch switch
├── mods\
│   ├── Sync-Mods.ps1              ← Workshop mod download + deploy
│   └── Import-Preset.ps1          ← Import Arma 3 Launcher HTML preset into a profile
├── presets\                       ← Store exported Arma 3 Launcher .html preset files here
│   └── WoDI_Star_Wars_2026_Walzmine.html
├── profiles\
│   ├── _template\                 ← Copy this to create a new profile
│   │   ├── profile.json           ← Port, branch, mods, HC count, ...
│   │   ├── server.cfg             ← Arma 3 server configuration
│   │   └── basic.cfg              ← Network tuning
│   ├── main\                      ← Example: Co-op server on port 2302
│   ├── tvt\                       ← Example: TvT server on port 2402
│   └── star_wars\                 ← Star Wars 2026 Walzmine (from preset)
└── scripts\
    ├── Common.ps1                 ← Shared helper functions
    ├── Start-Server.ps1           ← Profile-aware launcher (+ auto HC)
    ├── Stop-Server.ps1            ← Stop server and HC processes
    └── Start-Headless.ps1         ← Start a single Headless Client
```

The **server binaries**, **SteamCMD**, and **downloaded mods** live outside this repository
(configured via `framework.json`) to keep the repo small and version-control friendly.

---

## Importing an Arma 3 Launcher Preset

You can export a mod list from the Arma 3 Launcher as an `.html` file and import it directly into
any server profile. The importer reads the Workshop IDs and display names automatically.

### Export from the Arma 3 Launcher

1. Open the Arma 3 Launcher → MODS tab
2. Click **PRESET** (top right) → **EXPORT** → save the `.html` file
3. Place the file in the `presets\` folder of this repository (optional, for version control)

### Import into a profile

```powershell
# Replace mod list of the 'main' profile with the preset
.\mods\Import-Preset.ps1 -PresetFile "presets\MyPreset.html" -Profile main

# Merge preset mods INTO an existing profile (keeps existing mods, adds new ones)
.\mods\Import-Preset.ps1 -PresetFile "presets\MyPreset.html" -Profile main -Merge

# Preview without changing anything
.\mods\Import-Preset.ps1 -PresetFile "presets\MyPreset.html" -Profile main -WhatIf

# Import and download all mods in one step
.\mods\Import-Preset.ps1 -PresetFile "presets\MyPreset.html" -Profile main -SyncAfter
```

The script:
- Parses the HTML (Workshop IDs + display names)
- Generates a safe `@folder_name` for each mod
- Writes `WorkshopIds[]` and `Mods[]` into `profiles\<name>\profile.json`
- Optionally calls `Sync-Mods.ps1` to download everything immediately

Preset files are stored in `presets\` for reference. The `star_wars` profile is a ready-to-use
example populated from `presets\WoDI_Star_Wars_2026_Walzmine.html`.

---

## Creating a New Profile

1. Copy `profiles\_template` to `profiles\<yourname>`
2. Edit `profile.json` – set port, branch, mod list, HC count
3. Edit `server.cfg` – hostname, passwords, missions, ...
4. Edit `basic.cfg` – bandwidth settings
5. Run `.\mods\Sync-Mods.ps1 -Profile <yourname>` to download mods
6. Run `.\scripts\Start-Server.ps1 -Profile <yourname>` to launch

---

## Profile Configuration Reference (`profile.json`)

| Key | Type | Description |
|-----|------|-------------|
| `ProfileName` | string | Display name (should match folder name) |
| `Port` | int | Game port (Steam Query = Port+1, BattlEye = Port+4) |
| `Branch` | string | `"public"` or `"profiling"` |
| `Mods` | string[] | Mod folder names to pass as `-mod=` |
| `ServerMods` | string[] | Server-only mods (`-serverMod=`, not visible to clients) |
| `HeadlessClientCount` | int | Number of HC instances to start (0 = disabled) |
| `MaxPlayers` | int | Maximum player slots |
| `FPSLimit` | int | Server FPS cap (`-limitFPS=`) |
| `EnableAutoInit` | bool | Auto-start first mission (`-autoInit`) |
| `WorkshopIds` | object[] | Workshop IDs + target folder names for `Sync-Mods.ps1` |

---

## Headless Clients

Headless Clients offload AI computation from the main server process. They are standard Arma 3
instances running with `-client` instead of rendering anything.

**What the framework does:**
- Starts N HC processes automatically after the server is up
- Each HC connects to `127.0.0.1:<Port>` with the same mods as the server
- Each HC gets its own profile name (`HC1`, `HC2`, ...)

**What you need in your mission:**
- A *Headless Client* unit (Virtual Entities → Headless Client, `playable = 1`)
- A script to transfer AI groups to the HC (ALiVE, Antistasi, and many frameworks include this)

---

## Ports (Default, UDP)

| Port | Purpose |
|------|---------|
| 2302 | Game + VON |
| 2303 | Steam Query |
| 2304 | Steam Master |
| 2306 | BattlEye |

A second server instance should use a port offset of +100 (e.g. 2402–2406).

---

## Security Notes

- **Never commit passwords** – Steam password is prompted interactively at runtime
- Set `verifySignatures = 2` in `server.cfg` to enforce mod signature checks
- Copy the `.bikey` of every mod to `<ServerInstallPath>\keys\` (done automatically by `Sync-Mods.ps1`)
- Use a **dedicated Steam account** for the server (separate from your personal account)
