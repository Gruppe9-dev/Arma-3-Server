// =============================================================================
// initServer.sqf – Headless Client AI Transfer with Load Balancing
// Drop into your mission folder. Arma 3 executes this automatically on server.
//
// Requirements:
//   - CBA_A3 loaded
//   - server.cfg: headlessClients[] = {"127.0.0.1"};
//                 localClient[]     = {"127.0.0.1"};
// =============================================================================

if (!isServer) exitWith {};

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------
private _debug             = true;
private _rebalanceInterval = 60;   // seconds between rebalances
private _fpsPollInterval   = 10;   // seconds between HC FPS reports

missionNamespace setVariable ["HC_debug",             _debug];
missionNamespace setVariable ["HC_rebalanceInterval", _rebalanceInterval];
missionNamespace setVariable ["HC_fpsPollInterval",   _fpsPollInterval];
missionNamespace setVariable ["HC_initialized",       false];
missionNamespace setVariable ["HC_lastRebalance",     -9999];
missionNamespace setVariable ["HC_ownerIds",          []];
missionNamespace setVariable ["HC_initDelay",         10];  // wait 10 s after start before first transfer

// ---------------------------------------------------------------------------
// HC FPS Monitoring
// ---------------------------------------------------------------------------

// Creates a map marker for a single HC. Called when the HC registers.
// Markers are placed in a column in the top-right corner of the map.
HC_fnc_createFPSMarker = {
    params ["_ownerId", "_idx"];
    private _markerName = format ["HC_FPS_%1", _ownerId];
    private _pos = [worldSize - 100, worldSize - 100 - (_idx * 80), 0];
    private _m = createMarker [_markerName, _pos];
    _m setMarkerShape "ICON";
    _m setMarkerType "mil_dot";
    _m setMarkerColor "ColorGreen";
    _m setMarkerText format ["HC%1: -- FPS", _idx + 1];
    _m setMarkerAlpha 0.9;
};

// Pushes the FPS reporting loop to an HC machine.
// The HC sends its diag_fps every HC_fpsPollInterval seconds via publicVariableServer.
// publicVariableServer + addPublicVariableEventHandler avoids CfgRemoteExec restrictions.
HC_fnc_startFPSReporting = {
    params ["_ownerId"];
    private _interval = missionNamespace getVariable ["HC_fpsPollInterval", 5];
    [
        {
            [{ HC_fps_report = [clientOwner, round diag_fps]; publicVariableServer "HC_fps_report"; },
             missionNamespace getVariable ["HC_fpsPollInterval", 5]] call CBA_fnc_addPerFrameHandler;
        },
        _interval
    ] remoteExec ["call", _ownerId];
};

// Server-side listener: receives FPS reports from HCs and updates their markers.
addPublicVariableEventHandler ["HC_fps_report", {
    (_this select 1) params ["_ownerId", "_fps"];
    private _hcOwners = missionNamespace getVariable ["HC_ownerIds", []];
    private _idx = _hcOwners find _ownerId;
    if (_idx < 0) exitWith {};
    private _markerName = format ["HC_FPS_%1", _ownerId];
    _markerName setMarkerText format ["HC%1: %2 FPS", _idx + 1, _fps];
}];

// ---------------------------------------------------------------------------
// Capture HC owner IDs via PlayerConnected event.
// Parameters: [id, uid, name, jip, ownerId, idstr]
// ownerId is the machine's clientOwner – exactly what setGroupOwner needs.
// ---------------------------------------------------------------------------
addMissionEventHandler ["PlayerConnected", {
    params ["_id", "_uid", "_name", "_jip", "_ownerId", "_idstr"];
    private _debug = missionNamespace getVariable ["HC_debug", false];

    // Log all connects for diagnostics
    if (_debug) then {
        diag_log format ["[HC-Transfer] PlayerConnected: name=%1  ownerId=%2", _name, _ownerId];
    };

    // Match both profile-name style (hc_1) and game-name style (headlessclient)
    private _lname = toLower _name;
    if ((_lname find "hc") != 0 && (_lname find "headless") != 0) exitWith {};  // not an HC

    private _list = missionNamespace getVariable ["HC_ownerIds", []];
    if (_ownerId in _list) exitWith {};  // already registered

    _list pushBack _ownerId;
    missionNamespace setVariable ["HC_ownerIds", _list];

    if (_debug) then {
        diag_log format ["[HC-Transfer] HC connected: name=%1 ownerId=%2 (total: %3)",
            _name, _ownerId, count _list];
    };

    // Create FPS marker and start reporting loop on this HC
    private _idx = (count _list) - 1;
    [_ownerId, _idx] call HC_fnc_createFPSMarker;
    [_ownerId] call HC_fnc_startFPSReporting;
}];

// Also register HCs that connected before this script ran (JIP / already present)
{
    private _name    = name _x;
    private _ownerId = owner _x;
    if (((toLower _name) find "hc") == 0 && _ownerId != 0) then {
        private _list = missionNamespace getVariable ["HC_ownerIds", []];
        if !(_ownerId in _list) then {
            _list pushBack _ownerId;
            missionNamespace setVariable ["HC_ownerIds", _list];
            if (_debug) then {
                diag_log format ["[HC-Transfer] HC pre-connected: name=%1 ownerId=%2", _name, _ownerId];
            };
            // Create FPS marker and start reporting loop
            private _idx = (count _list) - 1;
            [_ownerId, _idx] call HC_fnc_createFPSMarker;
            [_ownerId] call HC_fnc_startFPSReporting;
        };
    };
} forEach allPlayers;

// ---------------------------------------------------------------------------
// Transfer function
// ---------------------------------------------------------------------------
missionNamespace setVariable ["HC_fnc_transfer", {
    private _debug    = missionNamespace getVariable ["HC_debug",    false];
    private _hcOwners = missionNamespace getVariable ["HC_ownerIds", []];

    missionNamespace setVariable ["HC_lastRebalance", time];

    if (_hcOwners isEqualTo []) exitWith {
        if (_debug) then { diag_log "[HC-Transfer] No HC owner IDs registered – skipping." };
    };

    private _transferred = 0;

    // Pre-filter: only AI-led groups with units.
    // exitWith inside forEach acts as break (exits entire loop), not continue.
    // Pre-filtering + if/then avoids that trap entirely.
    private _candidates = allGroups select {
        !isPlayer (leader _x) && count units _x > 0
    };

    // Local group counts per HC – updated immediately after each setGroupOwner
    // so the load balancer sees correct values within the same frame.
    // (groupOwner reflects changes asynchronously; querying allGroups mid-loop gives stale data.)
    // Only count non-empty groups so dead/empty groups do not skew the balance.
    private _localCounts = _hcOwners apply {
        private _id = _x;
        { groupOwner _x == _id && count units _x > 0 } count allGroups
    };

    {
        private _grp          = _x;
        private _currentOwner = groupOwner _grp;

        // Find least-loaded HC using local counts
        private _bestIdx   = 0;
        private _bestCount = _localCounts select 0;
        for "_i" from 1 to (count _hcOwners - 1) do {
            if ((_localCounts select _i) < _bestCount) then {
                _bestIdx   = _i;
                _bestCount = _localCounts select _i;
            };
        };
        private _best = _hcOwners select _bestIdx;

        if (_currentOwner != _best) then {
            private _doMove = true;
            if (_currentOwner in _hcOwners) then {
                private _currentIdx   = _hcOwners find _currentOwner;
                private _currentCount = _localCounts select _currentIdx;
                if ((_currentCount - _bestCount) < 2) then { _doMove = false; };
            };
            if (_doMove) then {
                _grp setGroupOwner _best;
                _transferred = _transferred + 1;

                // Update local counts immediately
                _localCounts set [_bestIdx, _bestCount + 1];
                if (_currentOwner in _hcOwners) then {
                    private _curIdx = _hcOwners find _currentOwner;
                    _localCounts set [_curIdx, (_localCounts select _curIdx) - 1];
                };

                if (_debug) then {
                    diag_log format ["[HC-Transfer] %1 -> owner %2 (HC groups now: %3)",
                        groupId _grp, _best, _bestCount + 1];
                };
            };
        };
    } forEach _candidates;

    if (_debug) then {
        private _distStr = "";
        for "_i" from 0 to (count _hcOwners - 1) do {
            _distStr = _distStr + format ["HC%1:%2g ", _hcOwners select _i, _localCounts select _i];
        };
        diag_log format ["[HC-Transfer] Done. Moved: %1 | Dist: %2", _transferred, _distStr];
    };
}];

if (_debug) then {
    diag_log "[HC-Transfer] Script loaded. Waiting for HC connections...";
};

// ---------------------------------------------------------------------------
// Per-frame handler – initial transfer + periodic rebalance
// ---------------------------------------------------------------------------
[{
    private _debug             = missionNamespace getVariable ["HC_debug",             false];
    private _initialized       = missionNamespace getVariable ["HC_initialized",       false];
    private _lastRebalance     = missionNamespace getVariable ["HC_lastRebalance",     -9999];
    private _rebalanceInterval = missionNamespace getVariable ["HC_rebalanceInterval", 60];
    private _hcOwners          = missionNamespace getVariable ["HC_ownerIds",          []];

    // --- Initial transfer once HCs are registered AND mission has had time to load ---
    private _initDelay = missionNamespace getVariable ["HC_initDelay", 10];
    if (!_initialized && count _hcOwners > 0 && time >= _initDelay) then {
        if (_debug) then {
            diag_log format ["[HC-Transfer] %1 HC(s) ready. Running initial transfer. IDs: %2",
                count _hcOwners, _hcOwners];
        };
        [] call (missionNamespace getVariable "HC_fnc_transfer");
        missionNamespace setVariable ["HC_initialized", true];
    };

    // --- Periodic rebalance ---
    if (_initialized && (time - _lastRebalance) >= _rebalanceInterval) then {
        if (_debug) then { diag_log "[HC-Transfer] Periodic rebalance..." };
        [] call (missionNamespace getVariable "HC_fnc_transfer");
    };

}, 1] call CBA_fnc_addPerFrameHandler;
