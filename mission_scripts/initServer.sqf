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
private _hcWaitTimeout     = 60;  // max seconds to wait for HCs before giving up
private _rebalanceInterval = 60;  // seconds between periodic rebalances
private _debug             = true;

// Store config in missionNamespace – private variables don't survive CBA callbacks
missionNamespace setVariable ["HC_debug",             _debug];
missionNamespace setVariable ["HC_rebalanceInterval", _rebalanceInterval];

// ---------------------------------------------------------------------------
// Helper: get connected HCs
// Stored in missionNamespace so CBA callbacks can reach it
// ---------------------------------------------------------------------------
missionNamespace setVariable ["HC_fnc_getHCs", {
    private _hcs = headlessClients;
    if (_hcs isEqualTo []) then {
        _hcs = allPlayers select { !isPlayer _x && !(isNull _x) };
    };
    _hcs select { !isNull _x }
}];

// ---------------------------------------------------------------------------
// Helper: transfer all AI groups to HCs with load balancing
// ---------------------------------------------------------------------------
missionNamespace setVariable ["HC_fnc_transfer", {
    private _debug    = missionNamespace getVariable ["HC_debug", false];
    private _hcs      = [] call (missionNamespace getVariable "HC_fnc_getHCs");

    if (_hcs isEqualTo []) exitWith {
        if (_debug) then { diag_log "[HC-Transfer] No HCs found – skipping." };
    };

    private _transferred = 0;
    private _hcOwners    = _hcs apply { owner _x };

    {
        private _grp = _x;
        if (isPlayer (leader _grp)) exitWith {};
        if ((count units _grp) == 0) exitWith {};
        if (groupOwner _grp in _hcOwners) exitWith {};  // already on an HC

        // Pick HC with fewest groups.
        // _hcId captures the outer forEach _x so the inner count-condition
        // can use _x freely for the group without shadowing the owner ID.
        private _best      = _hcOwners select 0;
        private _hcId      = _best;
        private _bestCount = { groupOwner _x == _hcId } count allGroups;

        {
            _hcId            = _x;
            private _cnt     = { groupOwner _x == _hcId } count allGroups;
            if (_cnt < _bestCount) then { _best = _hcId; _bestCount = _cnt; };
        } forEach _hcOwners;

        _grp setGroupOwner _best;
        _transferred = _transferred + 1;

        if (_debug) then {
            diag_log format ["[HC-Transfer] %1 -> owner %2 (HC groups now: %3)",
                _grp, _best, _bestCount + 1];
        };
    } forEach allGroups;

    if (_debug) then {
        private _dist = _hcOwners apply {
            private _id = _x;
            format ["HC%1: %2 grps", _id, { groupOwner _x == _id } count allGroups]
        };
        diag_log format ["[HC-Transfer] Done. Moved: %1 | Distribution: %2", _transferred, _dist];
    };
}];

if (_debug) then {
    diag_log "[HC-Transfer] Script loaded. Waiting for Headless Clients...";
};

// ---------------------------------------------------------------------------
// Wait until at least one HC connects, then initial transfer + rebalance loop
// ---------------------------------------------------------------------------
[
    // Condition – checked every frame by CBA
    { count ([] call (missionNamespace getVariable "HC_fnc_getHCs")) > 0 },

    // On success
    {
        private _debug   = missionNamespace getVariable ["HC_debug", false];
        private _hcCount = count ([] call (missionNamespace getVariable "HC_fnc_getHCs"));

        if (_debug) then {
            diag_log format ["[HC-Transfer] %1 HC(s) connected. Running initial transfer.", _hcCount];
        };

        [] call (missionNamespace getVariable "HC_fnc_transfer");

        // Periodic rebalance
        [
            { [] call (missionNamespace getVariable "HC_fnc_transfer"); },
            [],
            missionNamespace getVariable ["HC_rebalanceInterval", 60]
        ] call CBA_fnc_addPerFrameHandler;
    },

    [],  // no args needed – functions are in missionNamespace

    // Timeout
    _hcWaitTimeout,

    // On timeout – still start rebalance loop so late-connecting HCs get groups
    {
        private _debug = missionNamespace getVariable ["HC_debug", false];
        if (_debug) then {
            diag_log "[HC-Transfer] Timeout waiting for HCs. Rebalance loop still active.";
        };
        [
            { [] call (missionNamespace getVariable "HC_fnc_transfer"); },
            [],
            missionNamespace getVariable ["HC_rebalanceInterval", 60]
        ] call CBA_fnc_addPerFrameHandler;
    },

    []  // no args needed

] call CBA_fnc_waitUntilAndExecute;
