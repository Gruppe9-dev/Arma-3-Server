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

// ---------------------------------------------------------------------------
// Helper: get connected HCs via the dedicated SQF variable
// Falls back to allPlayers filter if headlessClients is empty
// ---------------------------------------------------------------------------
private _fnc_getHCs = {
    private _hcs = headlessClients;
    // fallback: allPlayers that are not real players and not the server
    if (_hcs isEqualTo []) then {
        _hcs = allPlayers select { !isPlayer _x && !(isNull _x) };
    };
    _hcs select { !isNull _x }
};

// ---------------------------------------------------------------------------
// Helper: find the HC with the fewest assigned groups (load balancing)
// ---------------------------------------------------------------------------
private _fnc_leastLoadedHC = {
    params ["_hcs"];
    private _loads = _hcs apply { [owner _x, {groupOwner _x == owner _this} count allGroups] };
    (_loads select { _x select 1 == ((_loads apply { _x select 1 }) select [0, count _loads] call BIS_fnc_arraySortBy) select 0 }) select 0 select 0
};

// ---------------------------------------------------------------------------
// Helper: transfer all AI groups – each group goes to the least loaded HC
// ---------------------------------------------------------------------------
private _fnc_transfer = {
    private _hcs = [] call _fnc_getHCs;

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

        // Pick HC with fewest groups – capture owner ID in _hcId so the
        // inner count-condition _x (= a group) does not shadow the outer _x.
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
            diag_log format ["[HC-Transfer] %1 -> HC owner %2 (groups on that HC now: %3)",
                _grp, _best, _bestCount + 1];
        };

    } forEach allGroups;

    if (_debug) then {
        private _dist = _hcOwners apply { format ["HC%1: %2 groups", _x, {groupOwner _x == _x} count allGroups] };
        diag_log format ["[HC-Transfer] Done. Moved: %1 | Distribution: %2", _transferred, _dist];
    };
};

// ---------------------------------------------------------------------------
// Wait until at least one HC connects, then do initial transfer + setup rebalance
// ---------------------------------------------------------------------------
if (_debug) then {
    diag_log "[HC-Transfer] Script loaded. Waiting for Headless Clients...";
};

[
    // Condition: at least 1 HC present
    { (count ([] call (_thisArgs select 0))) > 0 },

    // On success: transfer and start periodic rebalance
    {
        params ["_fnc_getHCs", "_fnc_transfer", "_rebalanceInterval", "_debug"];
        private _hcCount = count ([] call _fnc_getHCs);
        if (_debug) then {
            diag_log format ["[HC-Transfer] %1 HC(s) connected. Running initial transfer.", _hcCount];
        };
        [] call _fnc_transfer;

        [
            { [] call (_thisArgs select 0); },
            [_fnc_transfer],
            _rebalanceInterval,
            _rebalanceInterval
        ] call CBA_fnc_addPerFrameHandler;
    },

    [_fnc_getHCs, _fnc_transfer, _rebalanceInterval, _debug],

    // Timeout
    _hcWaitTimeout,

    // On timeout: still set up rebalance so late-connecting HCs get groups
    {
        params ["_fnc_getHCs", "_fnc_transfer", "_rebalanceInterval", "_debug"];
        if (_debug) then {
            diag_log "[HC-Transfer] Timeout waiting for HCs. Rebalance loop still active.";
        };
        [
            { [] call (_thisArgs select 0); },
            [_fnc_transfer],
            _rebalanceInterval,
            _rebalanceInterval
        ] call CBA_fnc_addPerFrameHandler;
    },

    [_fnc_getHCs, _fnc_transfer, _rebalanceInterval, _debug]

] call CBA_fnc_waitUntilAndExecute;
