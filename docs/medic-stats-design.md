# Medic Stats Tracking Design Notes

This document captures the current design idea for possible future Medic Stats tracking on the Gruppe 9 Arma 3 server.

## Goal

Track meaningful ACE3 medical actions during an operation without harming server performance.

The first version should collect raw medic treatment events, keep them in memory on the server during the mission, and aggregate them only at operation end. This keeps runtime overhead low and preserves enough raw data to change scoring rules later.

## Non-Goals

- Do not track every damage event.
- Do not write to a database or external API on every medical action.
- Do not broadcast medical stats to all clients in real time.
- Do not trust client-submitted data without basic server-side validation.
- Do not attempt to persist full ACE medical state, inventory, position, or loadout in this design.

## Relevant ACE3 Events

Primary event:

```sqf
["ace_treatmentSucceded", {
    params ["_medic", "_patient", "_bodyPart", "_classname", "_itemUser", "_usedItem", "_createLitter"];
}] call CBA_fnc_addEventHandler;
```

ACE uses the spelling `Succeded` in this event name.

Useful supplemental events:

```sqf
["ace_treatmentStarted", { ... }] call CBA_fnc_addEventHandler;
["ace_unconscious", { ... }] call CBA_fnc_addEventHandler;
["ace_medical_woundReceived", { ... }] call CBA_fnc_addEventHandler;
```

The first implementation should use `ace_treatmentSucceded` only. It is enough for counting completed treatments and avoids noisy intermediate state.

## Client-to-Server Flow

Recommended flow:

```text
Client
-> local ACE event fires
-> client builds a small medic event object
-> client buffers events locally
-> every 10-15 seconds client sends a batch to the dedicated server

Server
-> validates sender and event shape
-> adds server time and operation id
-> stores raw event in RAM
-> aggregates and persists once at operation end
```

Batching is preferred over sending a `remoteExecCall` for every treatment. Per-action sending is probably still acceptable for normal mission sizes, but batching is a safer default.

## Raw Event Shape

Store raw events first. Aggregates can be calculated later.

```text
operation_id
server_time
mission_time
client_time
medic_uid
medic_name
patient_uid
patient_name
body_part
treatment
used_item
self_treatment
remote_owner
```

`medic_uid` should always come from `getPlayerUID`. Names are display metadata only and must not be used as identity.

## Suggested Client Collector

This belongs in `initPlayerLocal.sqf` or a client-loaded mission script.

```sqf
if (!hasInterface) exitWith {};

G9_pendingMedicEvents = [];

["ace_treatmentSucceded", {
    params ["_medic", "_patient", "_bodyPart", "_classname", "_itemUser", "_usedItem", "_createLitter"];

    if (!local _medic) exitWith {};
    if (!isPlayer _medic) exitWith {};

    private _medicUid = getPlayerUID _medic;
    if (_medicUid isEqualTo "") exitWith {};

    private _patientUid = "";
    private _patientName = "";

    if (!isNull _patient) then {
        _patientUid = getPlayerUID _patient;
        _patientName = name _patient;
    };

    G9_pendingMedicEvents pushBack createHashMapFromArray [
        ["type", "ace_treatment"],
        ["medic_uid", _medicUid],
        ["medic_name", name _medic],
        ["patient_uid", _patientUid],
        ["patient_name", _patientName],
        ["body_part", _bodyPart],
        ["treatment", _classname],
        ["used_item", _usedItem],
        ["self_treatment", _medic isEqualTo _patient],
        ["client_time", time]
    ];
}] call CBA_fnc_addEventHandler;

[] spawn {
    while { true } do {
        sleep 15;

        if (G9_pendingMedicEvents isEqualTo []) then {
            continue;
        };

        private _batch = +G9_pendingMedicEvents;
        G9_pendingMedicEvents = [];

        [_batch] remoteExecCall ["G9_fnc_recordMedicEventBatch", 2];
    };
};
```

## Suggested Server Receiver

This belongs in `initServer.sqf` or a server-loaded mission script.

```sqf
if (!isServer) exitWith {};

G9_medicEvents = [];

G9_fnc_recordMedicEventBatch = {
    params ["_events"];

    if !(_events isEqualType []) exitWith {};

    private _senderOwner = remoteExecutedOwner;
    private _operationId = missionNamespace getVariable ["G9_operationId", ""];

    {
        if !(_x isEqualType createHashMap) then {
            continue;
        };

        private _medicUid = _x getOrDefault ["medic_uid", ""];
        private _treatment = _x getOrDefault ["treatment", ""];

        if (_medicUid isEqualTo "") then {
            continue;
        };

        if (_treatment isEqualTo "") then {
            continue;
        };

        private _validSender = false;
        {
            if (
                isPlayer _x &&
                { getPlayerUID _x == _medicUid } &&
                { owner _x == _senderOwner }
            ) exitWith {
                _validSender = true;
            };
        } forEach allPlayers;

        if (!_validSender) then {
            diag_log format [
                "[G9-MedicStats] Rejected spoofed medic event. owner=%1 medic_uid=%2",
                _senderOwner,
                _medicUid
            ];
            continue;
        };

        private _record = +_x;
        _record set ["operation_id", _operationId];
        _record set ["server_time", serverTime];
        _record set ["mission_time", time];
        _record set ["remote_owner", _senderOwner];

        G9_medicEvents pushBack _record;
    } forEach _events;
};

publicVariable "G9_fnc_recordMedicEventBatch";
```

## RemoteExec Requirement

The mission should restrict remote execution. Only the server receiver should be callable by clients.

```cpp
class CfgRemoteExec
{
    class Functions
    {
        mode = 1;
        jip = 0;

        class G9_fnc_recordMedicEventBatch
        {
            allowedTargets = 2;
        };
    };
};
```

## Aggregation Targets

At operation end, build per-medic counters from `G9_medicEvents`.

Useful first counters:

```text
bandages_applied
tourniquets_applied
tourniquets_removed
splints_applied
morphine_given
epinephrine_given
adenosine_given
iv_blood_given
iv_plasma_given
iv_saline_given
cpr_actions
surgical_kit_uses
pak_uses
self_treatments
unique_patients_treated
total_treatments
```

Keep the raw event list as the source of truth. Aggregates are derived data.

## Treatment Categorization Draft

Initial categorization can use ACE treatment class names.

```text
FieldDressing, PackingBandage, ElasticBandage, QuikClot -> bandages_applied
ApplyTourniquet -> tourniquets_applied
RemoveTourniquet -> tourniquets_removed
Splint -> splints_applied
Morphine -> morphine_given
Epinephrine -> epinephrine_given
Adenosine -> adenosine_given
BloodIV, BloodIV_500, BloodIV_250 -> iv_blood_given
PlasmaIV, PlasmaIV_500, PlasmaIV_250 -> iv_plasma_given
SalineIV, SalineIV_500, SalineIV_250 -> iv_saline_given
CPR -> cpr_actions
SurgicalKit -> surgical_kit_uses
PersonalAidKit -> pak_uses
```

The exact class names should be verified against the ACE version loaded on the server before implementation is finalized.

## Performance Notes

Expected overhead is low because medical treatment events are sparse compared to normal Arma network traffic.

Performance rules:

- Send small scalar values, not object references.
- Batch client events every 10-15 seconds.
- Store in RAM during the operation.
- Avoid per-event database, HTTP, or file writes.
- Avoid high-frequency events such as raw damage tracking for the first version.
- Avoid excessive `diag_log` spam during live missions.

Optional crash-safety improvement:

- Write a compact server-side snapshot every few minutes or at operation milestones.
- Keep this out of the hot path and do not write once per treatment.

## Open Questions

- Should self-treatment count for public medic stats or only internal stats?
- Should only players with a medic role/class receive medic credit?
- Should CPR count only as an action, or should successful revive/wake-up be tracked separately?
- Should failed operations still award medic stats?
- Should stats be visible in-game, web-only, or admin-only?
- Should raw event payloads be persisted indefinitely or summarized after export?

## Prompt For Another Agent

Use this prompt if another agent should continue the implementation later:

```text
You are working in the project:
F:\#Communitys\Gruppe 9\Arma 3 Server

Follow the repository instructions:
- Code and documentation must be written in English.
- Chat with the user in German.
- Only work inside this project.
- Do not revert unrelated user changes.

Task:
Implement the first version of ACE3 Medic Stats tracking based on docs/medic-stats-design.md.

Requirements:
1. Add mission-side SQF scripts for client collection and server receiving.
2. Track ACE3 `ace_treatmentSucceded` events on clients.
3. Buffer events client-side and send batches to the dedicated server every 10-15 seconds.
4. Send only compact scalar data: UIDs, names, treatment class, used item, body part, self-treatment flag, and client time.
5. Validate server-side that the remoteExec sender owns the reported medic player UID.
6. Store raw events in server memory as the source of truth.
7. Add an aggregation function that can produce per-medic counters at operation end.
8. Avoid per-event DB/API/file writes.
9. Add or document the required `CfgRemoteExec` entry.
10. Keep the implementation compatible with existing mission_scripts conventions.

Nice-to-have:
- Add an example debug export to RPT or JSON at mission end.
- Keep raw events and aggregate counters separated.
- Include clear comments where ACE event locality matters.

Do not:
- Track raw damage events.
- Broadcast medic stats to all clients.
- Trust client-submitted medic UID without server-side validation.
- Implement a database or external API unless explicitly requested.
```
