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

missionNamespace setVariable ["HC_debug",             _debug];
missionNamespace setVariable ["HC_rebalanceInterval", _rebalanceInterval];
missionNamespace setVariable ["HC_initialized",       false];
missionNamespace setVariable ["HC_lastRebalance",     -9999];
missionNamespace setVariable ["HC_lastWaitLog",       -999];
missionNamespace setVariable ["HC_ownerIds",          []];

// ---------------------------------------------------------------------------
// HC_fnc_registerOwner – called (broadcast) by each HC via remoteExec.
// Guard with isServer so only the server stores the ID.
// ---------------------------------------------------------------------------
HC_fnc_registerOwner = {
    if (!isServer) exitWith {};
    params [["_ownerId", 0]];
    if (_ownerId == 0) exitWith {};
    private _list = missionNamespace getVariable ["HC_ownerIds", []];
    if (_ownerId in _list) exitWith {};
    _list pushBack _ownerId;
    missionNamespace setVariable ["HC_ownerIds", _list];
    if (missionNamespace getVariable ["HC_debug", false]) then {
        diag_log format ["[HC-Transfer] HC registered owner ID: %1  (total: %2)", _ownerId, count _list];
    };
};

// ---------------------------------------------------------------------------
// Transfer function – uses the registered HC machine IDs
// ---------------------------------------------------------------------------
missionNamespace setVariable ["HC_fnc_transfer", {
    private _debug    = missionNamespace getVariable ["HC_debug",    false];
    private _hcOwners = missionNamespace getVariable ["HC_ownerIds", []];

    missionNamespace setVariable ["HC_lastRebalance", time];

    if (_hcOwners isEqualTo []) exitWith {
        if (_debug) then { diag_log "[HC-Transfer] No HC owner IDs registered – skipping." };
    };

    private _transferred = 0;

    {
        private _grp          = _x;
        private _currentOwner = groupOwner _grp;

        if (isPlayer (leader _grp)) exitWith {};
        if ((count units _grp) == 0) exitWith {};

        // Find HC with fewest groups
        private _best      = _hcOwners select 0;
        private _hcId      = _best;
        private _bestCount = { groupOwner _x == _hcId } count allGroups;

        {
            _hcId        = _x;
            private _cnt = { groupOwner _x == _hcId } count allGroups;
            if (_cnt < _bestCount) then { _best = _hcId; _bestCount = _cnt; };
        } forEach _hcOwners;

        if (_currentOwner == _best) exitWith {};

        if (_currentOwner in _hcOwners) then {
            private _currentCount = { groupOwner _x == _currentOwner } count allGroups;
            if ((_currentCount - _bestCount) < 2) exitWith {};
        };

        _grp setGroupOwner _best;
        _transferred = _transferred + 1;

        if (_debug) then {
            diag_log format ["[HC-Transfer] %1 -> owner %2 (HC groups now: %3)",
                groupId _grp, _best, _bestCount + 1];
        };
    } forEach allGroups;

    if (_debug) then {
        private _distStr = "";
        {
            private _id  = _x;
            private _cnt = { groupOwner _x == _id } count allGroups;
            _distStr = _distStr + format ["HC%1:%2g ", _id, _cnt];
        } forEach _hcOwners;
        diag_log format ["[HC-Transfer] Done. Moved: %1 | Dist: %2", _transferred, _distStr];
    };
}];

if (_debug) then {
    diag_log "[HC-Transfer] Script loaded. Waiting for HC self-registration...";
};

// ---------------------------------------------------------------------------
// Per-frame handler (every 1 s):
//   1. Detect HC player objects by name
//   2. Ask each HC to call back with its clientOwner ID (broadcast, guarded by isServer)
//   3. Initial transfer once HCs have registered
//   4. Periodic rebalance
// ---------------------------------------------------------------------------
[{
    private _debug             = missionNamespace getVariable ["HC_debug",             false];
    private _initialized       = missionNamespace getVariable ["HC_initialized",       false];
    private _lastRebalance     = missionNamespace getVariable ["HC_lastRebalance",     -9999];
    private _rebalanceInterval = missionNamespace getVariable ["HC_rebalanceInterval", 60];
    private _hcOwners          = missionNamespace getVariable ["HC_ownerIds",          []];

    // Detect HC player objects by name (hc_1, hc_2, …)
    private _hcPlayers = headlessClients;
    if (!(_hcPlayers isEqualType []) || { _hcPlayers isEqualTo [] }) then {
        _hcPlayers = allPlayers select { !isNull _x && (toLower (name _x) find "hc") == 0 };
    };
    _hcPlayers = _hcPlayers select { !isNull _x };

    // Ask each detected HC to report its clientOwner back to the server.
    // remoteExec with a player object runs on THAT player's machine.
    // HC_fnc_registerOwner is broadcast and guarded with isServer.
    {
        private _hcPlayer = _x;
        [{ [clientOwner] remoteExec ["HC_fnc_registerOwner"] }] remoteExec ["call", _hcPlayer];
    } forEach _hcPlayers;

    // Refresh owner list after potential new registrations this frame
    _hcOwners = missionNamespace getVariable ["HC_ownerIds", []];

    // --- Initial transfer ---
    if (!_initialized && count _hcOwners > 0) then {
        if (_debug) then {
            diag_log format ["[HC-Transfer] %1 HC(s) registered. Initial transfer. IDs: %2",
                count _hcOwners, _hcOwners];
        };
        [] call (missionNamespace getVariable "HC_fnc_transfer");
        missionNamespace setVariable ["HC_initialized", true];
    };

    // --- Still waiting: log every 30 s ---
    if (!_initialized && _debug) then {
        private _loggedAt = missionNamespace getVariable ["HC_lastWaitLog", -999];
        if (time - _loggedAt >= 30) then {
            diag_log format ["[HC-Transfer] Waiting... hcPlayers=%1 registeredOwners=%2",
                count _hcPlayers, _hcOwners];
            missionNamespace setVariable ["HC_lastWaitLog", time];
        };
    };

    // --- Periodic rebalance ---
    if (_initialized && (time - _lastRebalance) >= _rebalanceInterval) then {
        if (_debug) then { diag_log "[HC-Transfer] Periodic rebalance..." };
        [] call (missionNamespace getVariable "HC_fnc_transfer");
    };

}, 1] call CBA_fnc_addPerFrameHandler;
