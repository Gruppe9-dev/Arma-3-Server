// =============================================================================
// hc_fps_monitor.sqf - Headless Client FPS markers
//
// Creates map markers for the dedicated server and connected Headless Clients.
// Headless Clients report diag_fps back to the server; the server updates the
// marker text so Zeus can inspect HC/server performance.
//
// This script does not transfer AI groups. ACE Headless handles HC balancing.
// =============================================================================

if (!isServer) exitWith {};

private _debug           = true;
private _fpsPollInterval = 10;

missionNamespace setVariable ["HC_monitorDebug",       _debug];
missionNamespace setVariable ["HC_fpsPollInterval",   _fpsPollInterval];
missionNamespace setVariable ["HC_lastFpsUpdate",     -9999];
missionNamespace setVariable ["HC_ownerIds",          []];

HC_fnc_createFPSMarker = {
    params ["_ownerId", "_idx"];

    private _mName = format ["HC_FPS_%1", _ownerId];
    deleteMarker _mName;

    private _m = createMarker [_mName, [worldSize - 100, worldSize - 130 - (_idx * 80), 0]];
    _m setMarkerShape "ICON";
    _m setMarkerType "Empty";
    _m setMarkerColor "ColorGreen";
    _m setMarkerText format ["HC%1: -- FPS", _idx + 1];
    _m setMarkerAlpha 0.9;
};

deleteMarker "HC_FPS_server";
private _srvM = createMarker ["HC_FPS_server", [worldSize - 100, worldSize - 50, 0]];
_srvM setMarkerShape "ICON";
_srvM setMarkerType "Empty";
_srvM setMarkerColor "ColorBlue";
_srvM setMarkerText "Server: -- FPS";
_srvM setMarkerAlpha 0.9;

HC_fnc_startFPSReporting = {
    params ["_ownerId"];

    {
        if (missionNamespace getVariable ["HC_fpsReportingStarted", false]) exitWith {};
        missionNamespace setVariable ["HC_fpsReportingStarted", true];

        0 spawn {
            while { true } do {
                private _key = format ["HC_fps_%1", clientOwner];
                missionNamespace setVariable [_key, round diag_fps, true];
                sleep 10;
            };
        };
    } remoteExec ["call", _ownerId];
};

HC_fnc_registerOwner = {
    params ["_name", "_ownerId"];

    if (_ownerId == 0) exitWith {};

    private _lname = toLower _name;
    if ((_lname find "hc") != 0 && (_lname find "headless") != 0) exitWith {};

    private _list = missionNamespace getVariable ["HC_ownerIds", []];
    if (_ownerId in _list) exitWith {};

    _list pushBack _ownerId;
    missionNamespace setVariable ["HC_ownerIds", _list];

    private _idx = (count _list) - 1;
    [_ownerId, _idx] call HC_fnc_createFPSMarker;
    [_ownerId] call HC_fnc_startFPSReporting;

    if (missionNamespace getVariable ["HC_monitorDebug", false]) then {
        diag_log format ["[HC-Monitor] HC registered: name=%1 ownerId=%2 total=%3", _name, _ownerId, count _list];
    };
};

addMissionEventHandler ["PlayerConnected", {
    params ["_id", "_uid", "_name", "_jip", "_ownerId", "_idstr"];

    if (missionNamespace getVariable ["HC_monitorDebug", false]) then {
        diag_log format ["[HC-Monitor] PlayerConnected: name=%1 ownerId=%2", _name, _ownerId];
    };

    [_name, _ownerId] call HC_fnc_registerOwner;
}];

{
    [name _x, owner _x] call HC_fnc_registerOwner;
} forEach allPlayers;

[{
    private _lastFpsUpdate = missionNamespace getVariable ["HC_lastFpsUpdate", -9999];
    private _fpsInterval   = missionNamespace getVariable ["HC_fpsPollInterval", 10];
    if ((time - _lastFpsUpdate) < _fpsInterval) exitWith {};

    missionNamespace setVariable ["HC_lastFpsUpdate", time];
    "HC_FPS_server" setMarkerText format ["Server: %1 FPS", round diag_fps];

    private _hcOwners = missionNamespace getVariable ["HC_ownerIds", []];
    {
        private _id  = _x;
        private _fps = missionNamespace getVariable [format ["HC_fps_%1", _id], -1];
        if (_fps >= 0) then {
            private _idx = _hcOwners find _id;
            format ["HC_FPS_%1", _id] setMarkerText format ["HC%1: %2 FPS", _idx + 1, _fps];
        };
    } forEach _hcOwners;
}, 1] call CBA_fnc_addPerFrameHandler;

if (_debug) then {
    diag_log "[HC-Monitor] FPS marker monitor loaded.";
};
