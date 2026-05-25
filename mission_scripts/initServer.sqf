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
private _hcWaitTimeout     = 60;   // seconds to wait for first HC before giving up

// Store everything in missionNamespace – private vars don't survive callbacks
missionNamespace setVariable ["HC_debug",             _debug];
missionNamespace setVariable ["HC_rebalanceInterval", _rebalanceInterval];
missionNamespace setVariable ["HC_initialized",       false];
missionNamespace setVariable ["HC_lastRebalance",     -9999];
missionNamespace setVariable ["HC_startTime",         time];
missionNamespace setVariable ["HC_hcWaitTimeout",     _hcWaitTimeout];

// ---------------------------------------------------------------------------
// Helper: get connected HCs
// ---------------------------------------------------------------------------
missionNamespace setVariable ["HC_fnc_getHCs", {
    private _hcs = headlessClients;
    if (_hcs isEqualTo []) then {
        _hcs = allPlayers select { !isPlayer _x && !(isNull _x) };
    };
    _hcs select { !isNull _x }
}];

// ---------------------------------------------------------------------------
// Helper: transfer + rebalance all AI groups across HCs
// ---------------------------------------------------------------------------
missionNamespace setVariable ["HC_fnc_transfer", {
    private _debug    = missionNamespace getVariable ["HC_debug", false];
    private _hcs      = [] call (missionNamespace getVariable "HC_fnc_getHCs");

    // Always update the timestamp – even if we exit early – so the timer
    // does not immediately fire again on the next frame.
    missionNamespace setVariable ["HC_lastRebalance", time];

    if (_hcs isEqualTo []) exitWith {
        if (_debug) then { diag_log "[HC-Transfer] No HCs found – skipping." };
    };

    private _transferred = 0;
    private _hcOwners    = _hcs apply { owner _x };

    {
        private _grp          = _x;
        private _currentOwner = groupOwner _grp;

        if (isPlayer (leader _grp)) exitWith {};
        if ((count units _grp) == 0) exitWith {};

        // Find HC with fewest groups (load balancing)
        private _best      = _hcOwners select 0;
        private _hcId      = _best;
        private _bestCount = { groupOwner _x == _hcId } count allGroups;

        {
            _hcId        = _x;
            private _cnt = { groupOwner _x == _hcId } count allGroups;
            if (_cnt < _bestCount) then { _best = _hcId; _bestCount = _cnt; };
        } forEach _hcOwners;

        // Skip if already on the best HC
        if (_currentOwner == _best) exitWith {};

        // Skip if already on an HC and the imbalance is less than 2 groups
        // (avoids constant ping-ponging between equally loaded HCs)
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
    diag_log "[HC-Transfer] Script loaded. Waiting for Headless Clients...";
};

// ---------------------------------------------------------------------------
// Single per-frame handler (runs every 1 s) – manages the full lifecycle.
// Using one handler instead of CBA_fnc_waitUntilAndExecute avoids the issue
// where the success-callback fires every frame while the condition is true.
// ---------------------------------------------------------------------------
[{
    private _debug             = missionNamespace getVariable ["HC_debug",             false];
    private _initialized       = missionNamespace getVariable ["HC_initialized",       false];
    private _lastRebalance     = missionNamespace getVariable ["HC_lastRebalance",     -9999];
    private _startTime         = missionNamespace getVariable ["HC_startTime",         0];
    private _rebalanceInterval = missionNamespace getVariable ["HC_rebalanceInterval", 60];
    private _hcWaitTimeout     = missionNamespace getVariable ["HC_hcWaitTimeout",     60];
    private _hcs               = [] call (missionNamespace getVariable "HC_fnc_getHCs");

    // --- Initial transfer: fire once when first HC connects ---
    if (!_initialized && count _hcs > 0) then {
        if (_debug) then {
            diag_log format ["[HC-Transfer] %1 HC(s) connected. Running initial transfer.", count _hcs];
        };
        [] call (missionNamespace getVariable "HC_fnc_transfer");
        missionNamespace setVariable ["HC_initialized", true];
    };

    // --- Timeout: stop waiting even if no HC ever connected ---
    if (!_initialized && (time - _startTime) > _hcWaitTimeout) then {
        if (_debug) then {
            diag_log "[HC-Transfer] Timeout – no HCs connected. Rebalance loop still active.";
        };
        missionNamespace setVariable ["HC_initialized",   true];
        missionNamespace setVariable ["HC_lastRebalance", time];
    };

    // --- Periodic rebalance ---
    if (_initialized && (time - _lastRebalance) >= _rebalanceInterval) then {
        if (_debug) then { diag_log "[HC-Transfer] Periodic rebalance..." };
        [] call (missionNamespace getVariable "HC_fnc_transfer");
    };

}, [], 1] call CBA_fnc_addPerFrameHandler;
