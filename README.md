# Arma 3 Server Framework

PowerShell server management for Arma 3 on Windows, with a Discord bot that
executes host operations over SSH.

Multiple communities can share **one Arma installation and one mod inventory**.
Each assigned instance has separate missions, configuration, saves, logs, ports
and Discord permissions. One bot application can serve both Discord guilds.

For provisioning, migration, restricted SFTP and the Discord access template,
start with [Shared-installation community hosting](docs/multi-community-hosting.md).
Existing profiles remain in legacy mode until explicitly migrated. The new
runtime layout requires acceptance testing with your installed Arma build before
production access is granted.

## Requirements

- Windows with PowerShell 5.1 or newer and NTFS for isolated instance data.
- A Steam account owning Arma 3 for Workshop downloads and the profiling branch.
- A distinct five-port UDP block for each instance, allowed by the host firewall.
- For the bot: a Linux container runtime, network access to the Windows host's
  OpenSSH server, a bot SSH key and a verified host key file.

## Host setup

Copy `.env.example` to `.env` and adjust paths and credentials. Keep game data,
instance data and Workshop staging outside version control.

```powershell
Copy-Item .env.example .env
notepad .env
```

Example host settings:

```dotenv
SERVER_INSTALL_PATH=D:\Arma3Server
SERVER_UPDATE_BRANCH=public
STEAMCMD_PATH=D:\SteamCMD
WORKSHOP_STAGING_PATH=D:\Arma3Workshop
INSTANCE_DATA_PATH=D:\Arma3Instances
MAX_RUNNING_INSTANCES=2
MAX_TOTAL_HEADLESS_CLIENTS=4
STEAM_USERNAME=your_steam_username
```

Install and update the shared engine:

```powershell
.\setup\Install-Framework.ps1
.\setup\Update-Server.ps1
.\setup\Update-Server.ps1 -Branch profiling
```

Public installs use App ID 233780 anonymously. Profiling uses App ID 107410 with
the configured Steam account. Updates record `.arma3-server-branch` in the shared
installation. All instances must match that installed branch; changing a profile
does not create another installation. Shared updates require all Arma servers
and headless clients to be stopped.

Provision an instance after configuring the host paths:

```powershell
.\setup\New-Instance.ps1 -Profile friend -Port 2402 -BotUser arma_bot
.\mods\Sync-Mods.ps1 -Profile friend
.\scripts\Start-Server.ps1 -Profile friend
.\scripts\Get-ServerStatus.ps1 -Profile friend
.\scripts\Stop-Server.ps1 -Profile friend
```

Create the bot account first or omit `-BotUser` for initial local administration.
Review the generated server passwords, mods and settings before starting.
Provisioning does not open firewall ports or grant Discord access.

## Profiles and presets

Trusted control metadata is stored in `profiles/<id>/profile.json`. SFTP users
receive only their instance's `files/mpmissions` and `files/profile` directories.
Uploaded missions and configuration become active on the next start/restart.
Large game data is linked and mods are loaded from the shared inventory.

| Setting | Purpose |
| --- | --- |
| `Isolated` | Use private runtime data; set by `New-Instance.ps1` |
| `Port` | Game port; reserves `Port` through `Port+4` at startup preflight |
| `Branch` | Must match the shared installation |
| `Mods`, `ServerMods` | Approved shared mod folders |
| `WorkshopIds` | Workshop IDs and their canonical `@FolderName` |
| `HeadlessClientCount` | Approved HC count; also subject to the host limit |
| `FPSLimit`, `EnableAutoInit` | Supported startup options |
| `Presets` | Owner-prepared mod/settings selections for operators |
| `ExtraArgs` | Legacy only; isolated instances reject arbitrary arguments |

`MaxPlayers` is descriptive metadata; set the actual limit in `server.cfg`.
Headless clients connect to their own server on loopback with the selected mods.
The mission must provide playable headless-client slots and transfer AI work.

The [hosting guide](docs/multi-community-hosting.md#prepared-presets-and-commands)
includes the preset schema and migration procedure. `default` selects the base
profile; named presets can only be changed while that instance is stopped.

## Workshop management

```powershell
# Download missing mods for a profile and all its prepared presets
.\mods\Sync-Mods.ps1 -Profile friend

# Check metadata without deploying files
.\mods\Sync-Mods.ps1 -Profile _all -Update -CheckOnly

# Update every profile's shared mods while all instances are stopped
.\mods\Sync-Mods.ps1 -Profile _all -Update

# Stop/update/restart one profile, provided no other instance is active
.\mods\Sync-Mods.ps1 -Profile friend -Update -RestartServer
```

The first update establishes a deployment baseline. Later updates compare
Workshop timestamps and skip unchanged items. Mod replacement uses a temporary
folder and restores the previous folder on deployment failure. Updates cannot
replace shared files during another instance's session. Every Workshop ID must
use the same folder across profiles and presets; conflicting mappings are
rejected before downloading.

Pin Workshop items in `mods/update-exclusions.json`:

```json
{
  "WorkshopIds": [
    {"Id": "1234567890", "Reason": "Pinned for mission compatibility"}
  ]
}
```

Exclusions apply to update mode, including automatic updates. Normal and forced
syncs do not honor these update exclusions.

Export an HTML preset from Arma 3 Launcher and import it as the owner:

```powershell
.\mods\Import-Preset.ps1 -PresetFile "presets\MyPreset.html" -Profile friend -WhatIf
.\mods\Import-Preset.ps1 -PresetFile "presets\MyPreset.html" -Profile friend
.\mods\Import-Preset.ps1 -PresetFile "presets\MyPreset.html" -Profile friend -Merge -SyncAfter
```

Imports preserve isolation and prepared-preset metadata. Existing shared folder
names are reused. Stop the target instance and select its `default` preset before
importing. Server-only mods remain owner-managed; imports do not force Gruppe 9
extensions into another community's profile.

## Discord bot

In an administrator PowerShell on the dedicated host, prepare the bot account
and pin the host's SSH key:

```powershell
.\bot\setup-ssh-key.ps1
.\setup\Export-SshHostKey.ps1
```

For an existing bot account, run `setup/Grant-BotCimAccess.ps1 -BotUser arma_bot`
as administrator to grant process/UDP namespace reads and Remote Enable for SSH
network logons. Rerun the updated script if you previously granted only local reads. This is included
in new SSH setups; see [permission details](docs/multi-community-hosting.md).

Set `DISCORD_BOT_TOKEN`, `BOT_SSH_USER`, `BOT_SCRIPTS_PATH` and the SSH/query
endpoints in `.env`. For multiple guilds, copy
[`config/access.example.json`](config/access.example.json) to `config/access.json`,
replace every placeholder ID and set `BOT_ACCESS_CONFIG=/app/config/access.json`.
Invite the same application to both Discords. Roles and instance access are
assigned independently for each guild.

With `BOT_ACCESS_CONFIG` empty, the single-guild configuration uses
`DISCORD_GUILD_ID`, `DISCORD_ADMIN_ROLE_IDS` and `DISCORD_ADMIN_USER_IDS`.
A configured but invalid access policy prevents startup.

After host provisioning and permission checks:

```powershell
docker compose up -d --build
docker compose logs -f arma-bot
```

| Command | Access and behavior |
| --- | --- |
| `/server list` | List assigned instances |
| `/server status profile` | Instance CPU/RAM, uptime, HC count and A2S status |
| `/server start profile` | Start an assigned instance |
| `/server stop profile` | Stop only that instance's verified processes |
| `/server restart profile` | Stop and start that instance |
| `/server preset profile preset` | Select an approved preset while stopped |
| `/server update` | Owner: update the idle shared engine |
| `/mods sync`, `/mods update`, `/mods import-preset` | Owner: shared content management |

Operators cannot modify host paths, arbitrary startup arguments, Workshop content
or another guild's instances. Status panels and operation history are persisted
in `bot/data/jobs.sqlite3`. Jobs are serialized and permissions are checked again
before execution. Interrupted jobs are recorded without automatic replay.

Automatic updates are disabled by default. Set `BOT_AUTO_UPDATE_ENABLED=true`
only when unattended Steam credentials and a maintenance policy are ready.
The updater waits for an idle host, updates `SERVER_UPDATE_BRANCH`, then Workshop
content. Each phase reacquires the shared lock and checks idleness. See
`.env.example` for intervals and timeouts.

## SFTP and operations

Use [`setup/Configure-InstanceSFTP.ps1`](setup/Configure-InstanceSFTP.ps1) for new
per-person, per-instance SFTP accounts. The older `Configure-SFTP.ps1` targets
the shared legacy mission folder and is unsuitable for community separation.
The [hosting guide](docs/multi-community-hosting.md#restrict-sftp) explains keys,
permissions, backups and acceptance checks.

Stop/restart terminate the game processes. Save persistent missions first;
mission-specific graceful shutdown is not implemented. Process-count limits
do not impose hard CPU/RAM/disk quotas. Shared mods, engine branches and trusted
mission scripting still require coordination by the hardware owner.

## Validation

Install `bot/requirements.txt` into a local virtual environment, then run:

```powershell
python -B -m unittest discover -s tests -v
powershell -NoProfile -File tests\Test-Instances.ps1
powershell -NoProfile -File tests\Test-SharedRuntime.ps1
```

These checks use mocks and temporary filesystem fixtures. They do not launch
Arma, SteamCMD, Discord or SFTP services. Real host acceptance remains a separate
step; the [rollout checklist](docs/multi-community-hosting.md#validation-and-rollout-acceptance)
covers concurrent sessions, access isolation and persistent saves.
