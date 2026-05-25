# Mission Scripts

Ready-to-use scripts to drop into your Arma 3 missions.

## initServer.sqf – Headless Client AI Transfer

Automatically transfers all AI groups to connected Headless Clients.
Rebalances periodically to catch groups spawned mid-mission.

### How to use

1. Copy `initServer.sqf` into your mission folder (next to `description.ext` and `mission.sqm`).
2. Arma 3 executes `initServer.sqf` **automatically** on the server when a mission starts –
   no changes to `description.ext` needed.
3. If your mission already has an `initServer.sqf`, add this line at the top:
   ```sqf
   execVM "hc_transfer.sqf"; // rename the file to avoid conflict
   ```

### Configuration (top of file)

| Variable              | Default | Description                                              |
|-----------------------|---------|----------------------------------------------------------|
| `_hcTransferDelay`    | `15`    | Seconds to wait after mission start before first transfer |
| `_rebalanceInterval`  | `60`    | Seconds between automatic rebalance checks               |
| `_debug`              | `false` | Set `true` to log transfer details to the server log     |

### How to verify it's working

**Step 1 – Check if HCs are connected** (SERVER EXEC):
```sqf
// headlessClients is the reliable SQF variable for HCs
(format ["headlessClients: %1 | count: %2", headlessClients, count headlessClients]) remoteExec ["hint"];
```
If this returns `0`, the HCs aren't connecting. Check `server.cfg` and that `Start-Server.ps1` started the HC processes.

**Step 2 – Check group ownership** (after mission start + 15s):
```sqf
{
    private _owner = groupOwner _x;
    systemChat format ["%1 -> owner %2 (player: %3)", _x, _owner, isPlayer leader _x];
} forEach allGroups;
```
- `owner 0` = Server (AI not transferred yet, or player group)
- `owner 2+` = Headless Client ✓

**Step 3 – Check server RPT log** for `[HC-Transfer]` lines:
```
profiles\main\server_console_<PID>.log
```

### Requirements

- CBA_A3 must be loaded (uses `CBA_fnc_waitAndExecute` and `CBA_fnc_addPerFrameHandler`)
- `server.cfg` must contain:
  ```cpp
  headlessClients[] = {"127.0.0.1"};
  localClient[]     = {"127.0.0.1"};
  ```
- At least one Headless Client process running (started via `Start-Server.ps1`)
