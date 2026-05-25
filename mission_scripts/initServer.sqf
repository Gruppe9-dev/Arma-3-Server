// =============================================================================
// initServer.sqf – Headless Client AI Transfer
// Place this file in your mission folder and call it from description.ext:
//
//   class Header {
//       onLoadMission = "Gruppe 9";
//   };
//   // At the bottom of description.ext:
//   // (nothing needed – initServer.sqf is auto-executed by Arma on the server)
//
// OR call it manually from your existing initServer.sqf:
//   execVM "initServer.sqf";
//
// Requirements:
//   - server.cfg must have: headlessClients[] = {"127.0.0.1"};
//                           localClient[]      = {"127.0.0.1"};
//   - Headless Clients must be started BEFORE or shortly after the mission loads.
// =============================================================================

if (!isServer) exitWith {};

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------
private _hcTransferDelay    = 15;   // seconds to wait after mission start before first transfer
                                     // (gives HCs time to connect and initialize)
private _rebalanceInterval  = 60;   // seconds between periodic rebalance checks
                                     // (picks up AI groups spawned mid-mission)
private _debug              = false; // set true to see transfer messages in server log

// ---------------------------------------------------------------------------
// Helper: log to server log (only when _debug = true)
// ---------------------------------------------------------------------------
private _fnc_log = {
    params ["_msg"];
    if (_debug) then {
        diag_log format ["[HC-Transfer] %1", _msg];
    };
};

// ---------------------------------------------------------------------------
// Helper: return list of connected Headless Clients (sorted by current load)
// ---------------------------------------------------------------------------
private _fnc_getHCList = {
    headlessClients select { !isNull _x && { alive _x } }
};

// ---------------------------------------------------------------------------
// Helper: transfer all non-player AI groups to HCs in round-robin
// ---------------------------------------------------------------------------
private _fnc_transferAI = {
    private _hcs = [] call _fnc_getHCList;

    if (_hcs isEqualTo []) exitWith {
        ["No Headless Clients connected – skipping transfer."] call _fnc_log;
    };

    private _hcCount    = count _hcs;
    private _idx        = 0;
    private _transferred = 0;
    private _skipped    = 0;

    {
        private _grp = _x;

        // Skip player groups, empty groups, and groups already on an HC
        if (isPlayer (leader _grp)) exitWith { _skipped = _skipped + 1; };
        if ((count units _grp) == 0) exitWith {};

        private _currentOwner = groupOwner _grp;
        private _targetHC     = _hcs select (_idx mod _hcCount);
        private _targetOwner  = owner _targetHC;

        if (_currentOwner != _targetOwner) then {
            _grp setGroupOwner _targetOwner;
            _transferred = _transferred + 1;
            [format ["Transferred %1 (leader: %2) -> HC owner %3",
                _grp, leader _grp, _targetOwner]] call _fnc_log;
        };

        _idx = _idx + 1;

    } forEach allGroups;

    [format ["Transfer complete. Moved: %1  Skipped (player): %2  HCs: %3",
        _transferred, _skipped, _hcCount]] call _fnc_log;
};

// ---------------------------------------------------------------------------
// Initial transfer – wait for HCs to connect first
// ---------------------------------------------------------------------------
[
    {
        params ["_fnc_transferAI", "_fnc_log", "_rebalanceInterval"];

        ["Initial HC transfer starting..."] call _fnc_log;
        [] call _fnc_transferAI;

        // Periodic rebalance – catches groups spawned mid-mission
        [{
            params ["_fnc_transferAI", "_fnc_log"];
            ["Periodic rebalance..."] call _fnc_log;
            [] call _fnc_transferAI;
        }, [_fnc_transferAI, _fnc_log], _rebalanceInterval, _rebalanceInterval] call CBA_fnc_addPerFrameHandler;

    },
    [_fnc_transferAI, _fnc_log, _rebalanceInterval],
    _hcTransferDelay
] call CBA_fnc_waitAndExecute;

["HC Transfer script loaded. First transfer in %1s, rebalance every %2s.",
    _hcTransferDelay, _rebalanceInterval] call _fnc_log;
