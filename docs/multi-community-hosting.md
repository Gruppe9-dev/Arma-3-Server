# Shared-installation community hosting

Status: implemented in source; production migration and live Arma/Discord/SFTP
acceptance are still required. Start with the friend instance and migrate the
existing main profile during an announced maintenance window.

## Architecture decision

Use one centrally operated Discord bot in both guilds and one shared Arma engine
installation with one installed branch. Each community receives an assigned
profile/instance, private mutable data, and optionally a dedicated SFTP account.

Large engine directories are NTFS junctions into the shared installation.
Instances load mods by absolute path from the same shared mod inventory. Small
root executables/DLLs are refreshed into the instance runtime before each start.
Missions and editable configuration are deployed as private snapshots. There is
no SteamCMD installation/download per community and no complete game copy.

This trades some per-instance binary/mission storage for independent userconfig,
keys, saves, logs, and mission deployment. Shared updates still require downtime
for all instances. Distinct Arma branches or distinct versions of the same mod
are not supported by this layout. Independent full installations are appropriate
only if that requirement changes.

Windows instance data must be on **NTFS**; no fallback copies of large data are
made when junction creation is unavailable. Put `INSTANCE_DATA_PATH` outside
`SERVER_INSTALL_PATH`. CPU/RAM are consumed separately by each running game/HC
process. The configured limits restrict process counts; they are not hard CPU,
RAM, or disk quotas and this is not a sandbox for hostile native extensions.

```text
Shared Arma installation/
  addons/, dta/, DLC directories, @mods/   shared large content
Framework/
  profiles/friend/profile.json             owner-controlled metadata
  .state/friend/                           internal state; never exposed over SFTP
  config/access.json                      Discord policy; never exposed over SFTP
Instance data/friend/
  files/                                  SFTP root (read-only root itself)
    mpmissions/                           uploaded .pbo missions
    profile/                              editable server.cfg, basic.cfg,
                                          friend.Arma3Profile, userconfig/
  runtime/                                private to the operator/bot
    game/                                 engine junctions, small binary copies,
                                          local userconfig, keys, mpmissions, BE
    config/                               configuration snapshot
    profiles/                             Arma profiles, saves, RPT and log archives
```

## Configure the host

Work in the actual **dedicated host checkout**, not a separate development copy.
Back up the existing `.env`, local profiles, missions and persistent saves first.
Profile folders other than `_template` are ignored by Git; Git is not a backup.

Add these settings to the host `.env`, adjusting paths and capacities:

```dotenv
INSTANCE_DATA_PATH=C:\Arma3Instances
MAX_RUNNING_INSTANCES=2
MAX_TOTAL_HEADLESS_CLIENTS=4
```

Defaults are two main server processes and four HCs if the limits are omitted.
The trusted `HeadlessClientCount` in each profile further limits its HCs. HCs
left running after a failed session also count and block duplicate starts.
The main server reserves its five-port UDP block at preflight. The framework
serializes start/stop/maintenance across processes; external manual starts are
outside its control.

The SSH bot account needs read/execute on framework scripts, Modify on the
framework `profiles`, `presets`, `.state`, shared installation, Workshop staging
and SteamCMD data. `bot/setup-ssh-key.ps1` grants the framework portion for new
setups. Review inherited/old explicit ACLs when upgrading an existing account.
Never give SFTP users access to any of those control/maintenance locations.

Instance filesystem checks use the [Windows volume API](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getvolumepathnamew), including mounted-volume
paths, rather than the Storage CIM provider. A bot account with the required file
permissions does not need Storage CIM access for the NTFS check. If an older
deployment fails at `Get-Volume` with `Cannot connect to CIM server. Access denied`,
update `scripts/Instances.ps1` and `setup/New-Instance.ps1`. Other filesystem and
process-access failures still require checking the specific operation and path.

Process identification still uses `Win32_Process` in `root/cimv2`, and UDP port
checks use `root/StandardCimv2`. Existing bot accounts that receive
`HRESULT 0x80041003` from `Get-CimInstance` may lack namespace read or Remote Enable
access. [OpenSSH network logons require Remote Enable for WMI queries](https://github.com/PowerShell/Win32-OpenSSH/issues/2077),
even when the query targets the same host.
Run this once in an **administrator PowerShell on the dedicated host**:

```powershell
.\setup\Grant-BotCimAccess.ps1 -BotUser arma_bot
```

New `bot/setup-ssh-key.ps1` runs include this step. The grant adds only
[`WBEM_ENABLE` / Enable Account and `WBEM_REMOTE_ACCESS` / Remote Enable (0x21)](https://learn.microsoft.com/en-us/windows/win32/wmisdk/namespace-access-rights-constants)
on these two namespaces, without inheritance. Rerun the updated script to upgrade
an earlier Enable Account-only grant; it adds only missing rights. These are
namespace permissions, not per-class permissions. Remote Enable allows existing
namespace rights to be used through remote logons as well; it is not limited to
SSH. The script adds no method-execution, write or administrator rights and changes
no firewall rules or WinRM configuration. Existing permissions remain intact. Binary ACL backups
are written to `.state/cim-permissions` before each change. Repeated runs leave
an existing complete grant unchanged; `-WhatIf` previews without writing.

Verify from the same SSH identity used by the bot (this only counts processes
and UDP endpoints; it does not start a server):

```powershell
docker compose exec -T arma-bot python -c "import asyncio; from ssh_helper import run_ps_command; print(asyncio.run(run_ps_command('Get-CimInstance Win32_Process -ErrorAction Stop | Measure-Object; Get-NetUDPEndpoint -ErrorAction Stop | Measure-Object'))[1])"
```

Both queries should return counts without access errors. Run managed Arma
processes as the bot account so it can read their command lines and control
them. Existing deny policies or additional provider restrictions can still
block queries; the setup does not remove those policies. Instance identity
checks must remain enabled so stop/restart cannot target a foreign process.

Host-operation failures are reported with the original script path, line number
and error ID. Deploy changes to `bot/ssh_helper.py` with a bot image rebuild to
receive plain-text output instead of PowerShell CLIXML in the bot logs.

Pin the dedicated host's SSH identity, on that host:

```powershell
.\setup\Export-SshHostKey.ps1
```

Use `-HostName` and `-Port` if the bot SSH endpoint differs from
`host.docker.internal:22`. The bot requires the resulting
`bot/ssh/known_hosts`; there is no insecure fallback. The Compose file mounts it
read-only. Verify key changes locally instead of accepting an unknown network
key. Existing bots need this file before rebuilding with this version.

## Provision the friend instance

Stop all framework servers before provisioning. Preview first if desired:

```powershell
.\setup\New-Instance.ps1 -Profile friend -Port 2402 -WhatIf
.\setup\New-Instance.ps1 -Profile friend -Port 2402 -BotUser arma_bot
```

The template inherits the shared installation's recorded branch and starts with
CBA as the approved client mod. It does not force the Gruppe 9 stats extension.
Edit the trusted `profiles/friend/profile.json` to approve the desired mods,
Workshop IDs, HC count and presets. Change default passwords in the editable
`files/profile/server.cfg` before starting. `MaxPlayers` in profile metadata is
descriptive; Arma's effective slot limit is configured in `server.cfg`.

Download approved mods **once** while all instances are stopped:

```powershell
.\mods\Sync-Mods.ps1 -Profile friend
```

Shared Workshop IDs must use consistent folder names across profiles and
presets. Sync includes all prepared presets for that profile. Client mods,
server-only mods, and their keys must exist before a start succeeds.

The original `main` profile remains a legacy profile until explicitly migrated.
To enable independent userconfig during concurrent operation:

```powershell
.\setup\New-Instance.ps1 -Profile main -MigrateExisting -CopyMissions -BotUser arma_bot
```

This keeps original source files and backs up `profile.json` under
`.state/main/migration`. Existing `.vars.Arma3Profile` files are copied to runtime
profiles, including the existing `Users` tree. Inventory any mod-specific persistence locations, custom `ExtraArgs`,
and Battleye/RCon configuration before migrating; they may need explicit owner
configuration in the private runtime. Free-form `ExtraArgs` are rejected for
isolated instances. Legacy profiles with userconfig refuse concurrent starts.

To revert a stopped migrated profile, restore its saved `profile.json` and use
its preserved original configuration. Copy back any subsequently changed saves
deliberately. Do not recursively delete runtime views without removing junctions
as links; their targets contain shared game data.

## Restrict SFTP

Use a **new dedicated account** and an elevated PowerShell on the dedicated host.
Choose either an ed25519 public key or password-only authentication. Do not reuse
the bot's SSH account or private key. The current installer replaces the instance
directory ACLs: provision only one instance SFTP account per instance. To retain
access for existing global SFTP accounts, explicitly pass
`-GlobalSftpUsers main_sftp` (or a comma-separated list of local account names).
This grants access to this instance, without creating accounts or changing their
SSH configuration. Its `files` root remains read-only; `/profile` and `/mpmissions`
are writable. Manually added ACL entries are otherwise replaced.

```powershell
.\setup\Configure-InstanceSFTP.ps1 -Profile friend -SftpUser friend_sftp `
    -PublicKeyFile C:\Setup\friend.pub -BotUser arma_bot -WhatIf
.\setup\Configure-InstanceSFTP.ps1 -Profile friend -SftpUser friend_sftp `
    -PublicKeyFile C:\Setup\friend.pub -BotUser arma_bot
```

For password-only access, use these commands instead:

```powershell
.\setup\Configure-InstanceSFTP.ps1 -Profile 60th -SftpUser sftp_60th -BotUser arma_bot -UsePassword -WhatIf
.\setup\Configure-InstanceSFTP.ps1 -Profile 60th -SftpUser sftp_60th -BotUser arma_bot -UsePassword
```

The second command prompts for the password with hidden input; the preview does
not prompt. No public key file is required. Windows account password policy still
applies. In WinSCP, select SFTP, the host and SSH port, and the new username/password.
For automation, `-Password` accepts a `SecureString` together with `-UsePassword`.
Do not put a plaintext password in the command line or configuration files.

Password mode applies `AuthenticationMethods password`, `PasswordAuthentication yes`,
and `PubkeyAuthentication no` inside this user's `Match` block. Key mode retains
public-key-only authentication. The generated user block precedes existing `Match`
blocks so its explicit confinement/authentication settings take precedence. The
complete candidate is syntax-checked with `sshd -t`. These explicit settings are
then checked with `sshd -T` using the global configuration and generated block
only: evaluating later `Match Group` rules from an administrator process can fail
on Windows with `ga_init, unable to resolve user`, even when the account exists.
This check does not establish eligibility under every group/IP login rule; verify
a real SFTP login after setup. Configurations using active `Include` directives
are rejected before changes because their rule ordering is not handled.

The script creates a disabled account, prepares NTFS rights and an SFTP-only
match block, validates the configuration as described above, backs up
`sshd_config`, restarts SSH, and enables the account only after success. If that
final step fails, it attempts to restore the previous configuration and leaves
the account disabled. Keep an existing administrative console available
while applying host SSH configuration. Unrelated existing accounts are not repurposed.

To resume a failed setup, first inspect the account, then repeat the setup with
`-ResumeExisting`. For example, retaining an existing `main_sftp` account's access:

```powershell
Get-LocalUser -Name sftp_60th | Select-Object Name, Enabled, Description
.\setup\Configure-InstanceSFTP.ps1 -Profile 60th -SftpUser sftp_60th -BotUser arma_bot -UsePassword -ResumeExisting -GlobalSftpUsers main_sftp
```

Recovery requires a disabled account with the exact description
`SFTP for Arma instance 60th` and no existing SSH user block for that account.
It retains the account SID and password without another password prompt, unless
`-Password` is explicitly supplied. Do not manually enable the account before
the restricted SSH configuration has been installed. If no account exists,
omit `-ResumeExisting` to create it.

The user sees `/mpmissions` and `/profile`. They cannot change trusted
`profile.json`, instance ownership, ports, free startup parameters, process state,
framework scripts or Discord/Steam credentials through this SFTP root. This
confinement is the same for both authentication modes. Enabled or unrelated
existing accounts are rejected; `-UsePassword` does not convert an already
provisioned key account.

Upload complete `.pbo` missions (temporary upload extensions are not deployed).
Use a stopped server/start or restart to deploy changes. Running servers keep
their previous mission/config snapshot; uploading does not hot-reload a session.
The importer locks each source file against writers while copying it. Loose
mission directories are not deployed. `userconfig` supports `.sqf`, `.hpp`, `.h`,
`.inc`, `.cfg`, `.txt` files up to 2 MiB each. `server.cfg`/`basic.cfg` must be
self-contained and at most 2 MiB. Uploaded `profile.json` files are ignored.
`profile/<id>.Arma3Profile` is deployed to `runtime/profiles/Users/<id>/`.
Runtime saves stay private and are not overwritten by configuration uploads.

## Connect both Discord guilds

Copy `config/access.example.json` to `config/access.json` and replace **all**
placeholder IDs. The example deliberately fails validation until completed.
Use Discord Developer Mode to copy guild, role and user IDs. Then set:

```dotenv
BOT_ACCESS_CONFIG=/app/config/access.json
```

Install the same bot application in both guilds. Keep the bot token on your own
host. Each guild's `profiles` object binds only its own instances; profile IDs
are lowercase and must match the framework folders. Owners may run shared
maintenance in configured guilds; published instance status remains guild-bound.
Operators can start, stop, restart, select prepared presets and view status.
Viewers can list/view only. Discord's Administrator permission is not an implicit
grant. Roles are fetched again before a queued operation executes.

An empty `BOT_ACCESS_CONFIG` preserves the previous single-guild admin role/user
configuration, strictly scoped to `DISCORD_GUILD_ID`. A missing or invalid
configured policy aborts startup instead of falling back. Policy changes require
a bot restart. Provision instance data and access rules before deploying:

```powershell
docker compose up -d --build
```

Do not run this deployment command in a development checkout expecting it to
update the dedicated host. This source change does not modify live services.

## Prepared presets and commands

Add optional `Presets` to the owner-controlled `profile.json`. A named preset can
override `Mods`, `ServerMods`, `WorkshopIds`, `HeadlessClientCount`, `FPSLimit`
and `EnableAutoInit`; omitted fields inherit the base profile. `default` means
the base profile and is reserved. Example:

```json
"Presets": {
  "training": {
    "Mods": ["@CBA_A3"],
    "ServerMods": [],
    "WorkshopIds": [{"Id": "450814997", "FolderName": "@CBA_A3"}],
    "HeadlessClientCount": 0
  }
}
```

| Command | Scope |
| --- | --- |
| `/server list` | List only assigned instances |
| `/server status profile` | Instance CPU/RAM, process state, A2S and RPT fallback |
| `/server start profile` | Validate, deploy snapshots, start server and HCs |
| `/server stop profile` | Terminate only verified instance processes |
| `/server restart profile` | Stop/start; ends the active game session |
| `/server preset profile preset` | Select an approved preset while stopped |
| `/server update` | Owner-only shared Arma update, idle-only |
| `/mods sync`, `/mods update`, `/mods import-preset` | Owner-only shared content/control changes |

Stop/restart currently terminate game processes; persistent missions should save
first. They do not implement mission-specific graceful save/RCon shutdown.
Mod update with `restart_server` refuses if any other instance is active.
Manual sync/force sync and server updates use the same idle checks and lock as
automatic maintenance. Auto-update remains opt-in and waits for all instances.
Each maintenance phase acquires its own lock and checks idleness again.

The bot serializes jobs and persists their audit trail and status-panel IDs in
`bot/data/jobs.sqlite3`. Host locks also protect against another bot or CLI.
Panels recover after bot restart. Interrupted/unknown jobs are never blindly
replayed; check host status before retrying. Regular status messages survive
Discord's interaction-token lifetime. Grant the bot View Channel, Send Messages,
Embed Links and Read Message History in the intended management channels.

## Enable and diagnose automatic updates

After rollout acceptance, explicitly enable scheduling in the **production**
`.env`. Leaving the rollout value `false` disables both game and mod schedules:

```dotenv
BOT_AUTO_UPDATE_ENABLED=true
BOT_AUTO_UPDATE_INTERVAL_MINUTES=60
```

Recreate the bot to load the settings and then inspect its effective configuration:

```powershell
docker compose up -d --force-recreate arma-bot
docker compose exec -T arma-bot python -c "import config; print('enabled=', config.AUTO_UPDATE_ENABLED, 'interval_minutes=', config.AUTO_UPDATE_INTERVAL_MINUTES, 'scripts_path=', config.SCRIPTS_PATH)"
docker compose logs --since 72h --tail 250 arma-bot
```

The log must announce that automatic updates are enabled and show periodic update
attempts. A stopped game server does not imply a completed update: leftover HCs,
an active maintenance operation, missing unattended Steam credentials or a failed
server update can prevent Workshop updates. The engine phase runs first; if it
fails, the Workshop phase is not attempted in that cycle.

`AUTO_UPDATE_RESULT=complete` confirms both host phases returned successfully.
`skipped_active` and `skipped_locked` mean no updates were applied, and `failed`
requires inspecting the preceding error. The bot records skips separately from
completed jobs. A transport timeout leaves the host outcome uncertain.

For a read-only Workshop comparison on the dedicated host:

```powershell
.\mods\Sync-Mods.ps1 -Profile _all -Update -CheckOnly
```

This checks selected Workshop metadata; it does not download updates. Check
`mods/update-exclusions.json` if a specific mod is intentionally pinned. Do not
delete lock files or terminate unknown processes to bypass the idle checks.

## Validation and rollout acceptance

Offline checks (no live services involved):

```powershell
python -m unittest discover -s tests -v
powershell -NoProfile -File tests\Test-Instances.ps1
powershell -NoProfile -File tests\Test-SharedRuntime.ps1
```

Validation on 2026-09-19: 14 Python tests, 23 PowerShell instance checks and 20
filesystem checks passed. PowerShell parsing, Python 3.12 syntax/import checks,
Git whitespace checks and Compose configuration validation passed. Python tests
ran on local Python 3.14. A container build/run was not tested because the local
Docker engine was unavailable.

Before granting production access, verify on the dedicated host:

1. Both Discords list only their assigned instances; crafted foreign IDs fail.
2. Friend SFTP can modify its two folders but cannot read the main instance,
   runtime/control data or secrets, and cannot open a shell/forward connections.
3. Both servers start with different missions/userconfig and connectable ports.
   Check Arma/Battleye/RPT behavior using the real installed build and mods.
4. Stopping the friend leaves Gruppe 9 and its HCs running; repeat with missing
   PID files. Duplicate starts and shared updates during play are rejected.
5. A bot restart restores status panels without replaying a start/stop/update.
6. A stopped-server deployment applies uploaded PBO/config changes and approved
   presets; backups restore persistent mission state correctly.

Automated fixtures prove authorization, process matching, locks and filesystem
layout. They do not prove live Arma junction compatibility, network reachability,
installed OpenSSH ACL behavior, or workload capacity.

Implementation references: [Arma startup parameters](https://community.bistudio.com/wiki/Arma_3:_Startup_Parameters)
and [Windows OpenSSH configuration](https://github.com/PowerShell/Win32-OpenSSH/wiki/sshd_config).
