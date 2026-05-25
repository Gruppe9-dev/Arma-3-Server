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

**Step 1 – Check if HCs are connected**

Admin panel → **Server Exec**:
```sqf
(format ["headlessClients: %1 | count: %2", headlessClients, count headlessClients]) remoteExec ["hint"];
```
> `headlessClients` is only populated on the server, so *Server Exec* is required.
> `remoteExec ["hint"]` sends the result as a popup to all clients (including you).
> If count is `0` the HCs aren't connecting – check `server.cfg` and that `Start-Server.ps1` started the HC processes.

**Step 2 – Check group ownership** (run after mission start + 15 s)

Admin panel → **Global Exec**:
```sqf
private _result = "";
{ _result = _result + format ["%1 -> owner %2\n", _x, groupOwner _x]; } forEach allGroups;
_result remoteExec ["hint"];
```
> `remoteExec ["hint"]` is required – plain `hint` only shows on the machine that ran the code.
> When executed globally it runs locally and shows the hint on your screen.
> - `owner 0` = still on server (not transferred yet, or player group)
> - `owner 2 / 3 / …` = on a Headless Client ✓

**Step 3 – Check server RPT log** for `[HC-Transfer]` lines

When `_debug = true` all transfer actions are written via `diag_log` to the server's RPT file:
```
profiles\<ProfileName>\<ProfileName>_<Date>_<PID>.rpt
```
Example:
```
profiles\main\main_2026-05-25_17-01-20.rpt
```
Search for `[HC-Transfer]` to see exactly which groups were moved and the load distribution.

### Requirements

- CBA_A3 must be loaded (uses `CBA_fnc_waitAndExecute` and `CBA_fnc_addPerFrameHandler`)
- `server.cfg` must contain:
  ```cpp
  headlessClients[] = {"127.0.0.1"};
  localClient[]     = {"127.0.0.1"};
  ```
- At least one Headless Client process running (started via `Start-Server.ps1`)
