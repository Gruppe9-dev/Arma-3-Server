# Mission Scripts

Ready-to-use scripts to drop into Arma 3 missions.

## Current setup

`initServer.sqf` is now a small mission entry point:

- ACE Headless handles AI transfer and load balancing.
- `hc_fps_monitor.sqf` only adds server/HC FPS markers for Zeus.
- `hc_transfer_legacy.sqf` keeps the old custom `setGroupOwner` balancer as a fallback.

Do not run `hc_transfer_legacy.sqf` together with ACE Headless. Both systems would try to control AI group ownership.

## How to use

Copy these files into the mission root, next to `description.ext` and `mission.sqm`:

- `initServer.sqf`
- `hc_fps_monitor.sqf`

Arma 3 executes `initServer.sqf` automatically on the server when the mission starts.

If the mission already has an `initServer.sqf`, add this line to it:

```sqf
execVM "hc_fps_monitor.sqf";
```

## ACE Headless settings

ACE Headless is enabled through CBA settings in this project:

- `profiles/_template/userconfig/cba_settings.sqf`
- `profiles/main/userconfig/cba_settings.sqf`
- `profiles/star_wars/userconfig/cba_settings.sqf`

Relevant settings:

```sqf
force acex_headless_enabled         = true;
force acex_headless_delay           = 10;
force acex_headless_endMission      = false;
force acex_headless_log             = true;
force acex_headless_transferLoadout = false;
```

`scripts/Start-Server.ps1` deploys a profile's `userconfig` folder to the server root before launch.

## Legacy custom transfer

Use `hc_transfer_legacy.sqf` only if you intentionally disable ACE Headless and want the previous custom balancer back:

```sqf
execVM "hc_transfer_legacy.sqf";
```

## How to verify

### Check if HCs are connected

Admin panel -> Server Exec:

```sqf
(format ["headlessClients: %1 | count: %2", headlessClients, count headlessClients]) remoteExec ["hint"];
```

`headlessClients` is only populated on the server, so Server Exec is required.

### Check group ownership

Run after mission start plus the ACE Headless delay:

```sqf
private _result = "";
{ _result = _result + format ["%1 -> owner %2\n", _x, groupOwner _x]; } forEach allGroups;
_result remoteExec ["hint"];
```

- `owner 0` means the group is still on the server.
- `owner 2`, `owner 3`, and similar values mean a Headless Client owns the group.

### Check logs

Search the server RPT log for ACE Headless entries and for `[HC-Monitor]` marker-monitor entries.

## Requirements

- CBA_A3 loaded.
- ACE3 loaded.
- `server.cfg` contains matching Headless Client entries, for example:

```cpp
headlessClients[] = {"127.0.0.1"};
localClient[]     = {"127.0.0.1"};
```

- At least one Headless Client process running, started through `scripts/Start-Server.ps1`.
