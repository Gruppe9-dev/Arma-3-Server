# General Stats Tracking Design Notes

This document captures the current design idea for a future general stats tracking system for the Gruppe 9 Arma 3 server.

The intended architecture is a dedicated Arma server-side mod plus a backend API. The API must be protected so only the trusted dedicated server can submit mission data.

## Goal

Build a reliable operation stats pipeline for Arma 3 missions.

The first version should track operation attendance and gameplay stats with low runtime overhead:

- operation start and finish
- player identity by Steam UID
- scoreboard deltas
- optional ACE3 medic event aggregates
- attendance duration and reconnects
- raw payload retention for later reprocessing
- secure server-only submission to a backend API

## Non-Goals

- Do not expose the ingest API directly to players.
- Do not put API tokens into a client-loaded mod.
- Do not write to the backend on every small event.
- Do not trust client-side data without server validation.
- Do not build a full persistence system for loadouts, positions, vehicles, or ACE medical state in the first version.
- Do not require mission makers to manually edit every mission beyond adding a small init hook, if possible.

## High-Level Architecture

Recommended split:

```text
@g9_stats
  Client/server addon loaded by all clients and the server.
  Contains public SQF functions, event collectors, and optional Zeus/admin controls.
  Contains no API secrets.

@g9_stats_server
  Server-only mod loaded with -serverMod.
  Contains native extension or server-only bridge code.
  Contains API configuration, local retry queue, and secrets.

Backend API
  HTTPS API and database.
  Accepts ingest only from the trusted dedicated server identity.
  Stores operations, raw payloads, normalized player stats, and aggregates.
```

Recommended server launch shape:

```text
-mod=@CBA_A3;@ace;@g9_stats -serverMod=@g9_stats_server
```

Secrets must live only in `@g9_stats_server` or in server environment variables. The normal client mod must never contain API tokens, bearer secrets, database passwords, or signing keys.

## Reference Repositories

The current design should explicitly use these two repositories as reference material:

- `arma-attendance-web`: <https://github.com/JTM-rootstorm/arma-attendance-web>
- `arma-attendance-server-extension`: <https://github.com/JTM-rootstorm/arma-attendance-server-extension>

They are not a drop-in solution for Gruppe 9, but they contain valuable implementation patterns for exactly this kind of Arma-to-backend stats pipeline.

### Useful Patterns From `arma-attendance-server-extension`

Reference links:

- <https://github.com/JTM-rootstorm/arma-attendance-server-extension/blob/main/README.md>
- <https://github.com/JTM-rootstorm/arma-attendance-server-extension/blob/main/docs/WEB_API_CONTRACT_CURRENT.md>
- <https://github.com/JTM-rootstorm/arma-attendance-server-extension/blob/main/docs/PRESENCE_LEDGER.md>

Important ideas to reuse:

- Split client/server addon and server-only extension into separate packages.
- Launch with a normal addon in `-mod` and the secret-bearing server package in `-serverMod`.
- Keep API secrets in a TOML config next to the server-only extension, not in client PBOs or mission files.
- Use SQF to build operation start/finish payloads and a native extension to submit HTTP requests.
- Use a low-risk `health` and `poke` path before implementing full operation ingest.
- Use `operation_start` and `operation_finish` commands rather than continuous API writes.
- Store `operation_id` after successful start so finish can target the same operation.
- Use a local NDJSON retry queue for operation submissions.
- Keep queue commands such as `queue_status`, `queue_flush`, and `queue_compact`.
- Filter headless clients before snapshots and attendance calculations.
- Track presence by UID across connect, disconnect, and reconnect.
- At finish, send both a current `players` snapshot and a full `attendance_records` ledger.

The extension contract is especially useful because it defines the server-to-backend boundary:

```http
GET  /health
POST /v1/debug/poke
POST /v1/operations/start
POST /v1/operations/:operation_id/finish
GET  /v1/ingest-requests/:request_id
GET  /v1/operations/:operation_id
GET  /v1/operations/:operation_id/attendance
GET  /v1/operations/:operation_id/payloads
```

For Gruppe 9, this contract can be used as the baseline and extended with medic aggregates or other unit-specific stats later.

### Useful Patterns From `arma-attendance-web`

Reference links:

- <https://github.com/JTM-rootstorm/arma-attendance-web/blob/main/README.md>
- <https://github.com/JTM-rootstorm/arma-attendance-web/blob/main/docs/API.md>

Important ideas to reuse:

- Fastify/TypeScript backend with explicit request validation.
- PostgreSQL-backed operation, player, attendance, and stats persistence.
- Machine-token authentication for Arma ingest.
- Browser/admin workflows separated from machine ingest workflows.
- Raw payload storage plus normalized relational tables.
- Idempotent ingest by `request_id`.
- Readback diagnostics for ingest requests, operation payloads, operations, and attendance.
- CSV/export endpoints for later analysis.
- Admin-only machine-token creation and rotation.
- Dashboard and leaderboard read APIs built from normalized rows, not from raw JSON only.

The web repo reinforces an important design rule: raw payloads should be retained, but dashboards and exports should read from normalized tables. This gives us both auditability and query performance.

### Reference Payload Shape

The reference extension uses operation payloads shaped like this:

```json
{
  "request_id": "main:start:2026-06-26T18-00-00Z:altis:mission-name",
  "server_key": "main",
  "payload_version": 1,
  "mission": {
    "mission_uid": "altis:mission-name:generated-id",
    "mission_name": "Coop Night",
    "world_name": "Altis"
  },
  "source": {
    "kind": "arma3-addon",
    "addon": "g9_stats",
    "extension": "g9_stats_server"
  },
  "players": []
}
```

Finish payloads should add:

```json
{
  "outcome": "success",
  "players": [],
  "attendance_records": [],
  "scoreboard_stats": [],
  "medic_aggregates": []
}
```

The exact final schema can differ, but it should keep these concepts:

- unique `request_id`
- stable `server_key`
- mission metadata
- source metadata
- raw player snapshot
- full attendance ledger
- normalized stats or stats-ready records

### Reference Security Lessons

The reference repos use bearer-token machine authentication as the basic model. Gruppe 9 should treat that as the minimum and add hardening where practical:

- keep the token only in the server-only mod or environment
- never ship the token in a client addon
- never log the token
- use HTTPS
- use idempotent request IDs
- verify `server_key` against the authenticated token
- add reverse-proxy IP allowlisting for the dedicated server
- consider HMAC request signatures for replay protection

### How To Use These Repos During Implementation

Before implementing the Gruppe 9 version, inspect these parts of the reference repos:

```text
arma-attendance-server-extension
  README.md
  docs/WEB_API_CONTRACT_CURRENT.md
  docs/PRESENCE_LEDGER.md
  addons/main/functions/fnc_buildOperationStartPayload.sqf
  addons/main/functions/fnc_buildOperationFinishPayload.sqf
  addons/main/functions/fnc_buildPlayerSnapshot.sqf
  extension/src/commands.cpp
  servermod/*.example.toml

arma-attendance-web
  README.md
  docs/API.md
  apps/api/src/routes/operations*
  apps/api/src/operations/operationIngest*
  apps/api/src/normalization/*
  apps/api/src/db/schema/*
  sql/migrations/*
```

Do not copy blindly. Use them to validate the architecture, payload contracts, queue behavior, and database normalization approach.

## Data Flow

```text
Mission starts
-> server creates operation_id locally or receives one from backend
-> server captures player score baselines
-> server starts attendance/presence tracking

During mission
-> server periodically reconciles current players
-> clients may send validated low-volume event batches, e.g. medic events
-> server keeps raw events in RAM
-> optional local snapshot every few minutes for crash recovery

Mission ends
-> server captures latest scoreboards
-> server calculates deltas
-> server finalizes attendance and aggregates
-> server sends one finish payload to backend
-> backend stores raw payload and normalized rows
```

The system should prefer operation-level payloads over frequent API writes. Runtime collection happens in Arma memory; persistence happens at operation milestones.

## Core Stats To Track

### Operation

```text
operation_id
server_key
mission_uid
mission_name
world_name
started_at
ended_at
status
outcome
source
raw_start_payload
raw_finish_payload
```

### Player Identity

```text
player_uid
last_name
first_seen_at
last_seen_at
raw_last_player
```

Use `getPlayerUID` as the only identity key. Player names are display metadata.

### Attendance

```text
operation_id
player_uid
name_at_start
name_at_end
side_at_start
side_at_end
group_at_start
group_at_end
role_at_start
role_at_end
present_at_start
present_at_end
joined_after_start
disconnect_count
reconnect_count
operation_seconds
attended_seconds
missed_seconds
attendance_ratio
attendance_percent
attendance_credit
```

### Scoreboard Stats

Use start and finish snapshots from `getPlayerScores`.

```text
operation_id
player_uid
scoreboard_baseline
scoreboard_latest
infantry_kills
soft_vehicle_kills
armor_kills
air_kills
ground_vehicle_kills
all_vehicle_kills
vehicle_kills
deaths
score
stats_source
```

Store the raw arrays as well as normalized columns. This keeps old operations reprocessable if mapping rules change later.

### Optional Medic Stats

Medic stats should be based on raw ACE treatment events from `docs/medic-stats-design.md`.

Store raw events separately and derive counters such as:

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

## Arma Server Mod Responsibilities

The Arma server-side implementation should own:

- operation lifecycle state
- attendance ledger keyed by player UID
- scoreboard baseline/latest snapshots
- optional medic event receiving and aggregation
- payload construction
- local retry queue
- API authentication headers or signatures
- safe logging without leaking secrets

The client-loaded addon may collect client-local events, but it must only send compact event batches to the dedicated server. It must not communicate with the backend directly.

## Backend Responsibilities

The backend should own:

- API token or request signature verification
- server identity and scope validation
- request idempotency by `request_id`
- payload schema validation
- raw payload storage
- normalization into relational tables
- read APIs for dashboards and exports
- admin-only token rotation
- audit logging for ingest requests

Suggested endpoint groups:

```text
GET  /health
POST /v1/operations/start
POST /v1/operations/:operation_id/finish
POST /v1/operations/:operation_id/events
GET  /v1/operations
GET  /v1/operations/:operation_id
GET  /v1/operations/:operation_id/attendance
GET  /v1/players
GET  /v1/players/:player_uid
```

`/events` is optional for future low-volume event ingest. The first implementation can avoid it and include all aggregates in the finish payload.

## API Security Requirements

The ingest API must be designed as a server-to-server interface.

### Secret Placement

- Store the API secret only in the server-only mod config or server environment.
- Never pack secrets into a client-loaded PBO.
- Never place secrets in mission files.
- Never log the raw Authorization header or signing secret.

### Authentication

Minimum acceptable model:

```http
Authorization: Bearer <server_machine_token>
Content-Type: application/json
```

Better model:

```http
Authorization: Bearer <server_machine_token>
X-G9-Server-Key: main
X-G9-Request-Id: main:finish:<operation-id>:<timestamp>
X-G9-Timestamp: 2026-06-26T18:00:00Z
X-G9-Signature: hmac-sha256(body + timestamp + request_id)
```

Best model for a hardened deployment:

- HTTPS only
- firewall allowlist for the dedicated server IP
- scoped machine tokens
- request HMAC signature
- short timestamp replay window
- idempotent `request_id`
- rate limits
- body size limits
- optional mTLS between reverse proxy and server

### Authorization

Machine tokens should have scoped permissions.

Suggested token scopes:

```text
stats:operation:start
stats:operation:finish
stats:operation:read
stats:events:write
stats:queue:flush
```

The Arma server token should not have admin/user-management permissions. A Discord bot token, admin UI token, and Arma server ingest token should be separate credentials.

### Network Boundary

Recommended deployment:

```text
Arma dedicated server
-> HTTPS reverse proxy
-> backend API
-> PostgreSQL
```

Restrict ingest routes at the reverse proxy where possible:

- allow only the dedicated server public IP or VPN subnet
- require HTTPS
- reject large payloads
- keep admin/browser routes separate from ingest routes when possible

The backend must still validate tokens even when IP allowlisting is enabled. IP allowlisting is an additional control, not a replacement for authentication.

### Replay Protection

Every start and finish payload must contain a stable unique `request_id`.

Backend behavior:

- First request with a `request_id`: validate, store, process, store response.
- Repeated request with same `request_id`: return stored response.
- Repeated request with same `request_id` but different payload hash: reject as conflict.

This makes retry queues safe and prevents duplicate stats awards.

### Payload Validation

Backend must validate:

- required fields exist
- `server_key` is known and allowed for the token
- operation exists before finish
- finish `server_key` matches start `server_key`
- payload size is within limit
- player UIDs are strings with sane length
- numeric stats are finite integers
- unknown fields are stored as raw JSON but not blindly trusted for normalized columns

## Local Retry Queue

The server-only mod should queue operation start/finish submissions locally before HTTP send.

Queue behavior:

- queue record contains request id, endpoint, payload, attempt count, and created timestamp
- network failures and 5xx responses remain retryable
- validation failures and other terminal 4xx responses are not retried forever
- queue flush can run automatically and via admin command
- queue files must live beside the server-only mod or in a configured server-only path

Do not store the API token in queue records.

## Performance Requirements

Runtime performance rules:

- Keep hot-path work in memory.
- Avoid database, HTTP, or file writes per event.
- Batch client-originated event data.
- Send one start payload and one finish payload per operation.
- Use periodic reconcile loops with conservative intervals.
- Store compact scalar data, not object references.
- Avoid verbose live logging.

Expected high-frequency sources such as raw damage events should be excluded from version 1.

## Failure Modes

The design should explicitly handle:

- backend offline during mission
- server restart after mission
- operation started but not finished
- duplicate finish submission
- player disconnect before finish
- player reconnect with same UID
- headless clients appearing in `allPlayers`
- client sending forged medic/event data
- API token leak or rotation

Recommended defaults:

- queue locally if backend is down
- filter headless clients
- validate remoteExec sender for client-originated event batches
- mark stale unfinished operations as `abandoned` or `failed` through a backend cleanup process
- rotate machine tokens through admin-only backend tools

## Suggested Database Tables

Minimal backend schema:

```text
servers
  server_key
  display_name
  active

machine_tokens
  token_id
  token_hash
  server_key
  scopes
  created_at
  revoked_at

operations
  id
  server_key
  mission_uid
  mission_name
  world_name
  status
  outcome
  started_at
  ended_at
  raw_start_payload
  raw_finish_payload

ingest_requests
  request_id
  operation_id
  endpoint
  payload_hash
  response
  received_at

players
  player_uid
  last_name
  first_seen_at
  last_seen_at
  raw_last_player

operation_players
  operation_id
  player_uid
  start/end metadata
  attendance fields

operation_player_stats
  operation_id
  player_uid
  normalized scoreboard counters
  raw baseline/latest arrays

operation_medic_events
  operation_id
  event_id
  server_time
  medic_uid
  patient_uid
  treatment
  raw_event

operation_medic_aggregates
  operation_id
  medic_uid
  derived counters
```

Raw payloads and raw events should be retained at least until the normalized pipeline has proven stable.

## Open Questions

- Should the backend be part of this repository or a separate service repository?
- Should the Arma server bridge use a native extension, file export, or an existing extension such as extDB?
- Should stats be operation-only or also lifetime totals?
- Should failed operations count toward player stats?
- Should client-originated event batches be accepted only for ACE medic events, or also for other future event types?
- Should admin dashboards be public, Discord-authenticated, or restricted to a VPN?
- Should the API be reachable from the public internet or only through a private tunnel/VPN?

## Implementation Phases

### Phase 1: Local Mission Prototype

- Track operation start/finish in mission SQF.
- Capture player score baselines and finish snapshots.
- Produce a JSON-like debug payload in RPT.
- No backend yet.

### Phase 2: ServerMod Bridge

- Move server-only submission into a serverMod.
- Add config file for API base URL, server key, and token.
- Add local retry queue.
- Add safe health/poke commands.

### Phase 3: Backend MVP

- Add authenticated ingest endpoints.
- Store raw payloads and normalized operation/player/stats rows.
- Add idempotency and payload validation.
- Add basic read endpoints and CSV export.

### Phase 4: Client Event Extensions

- Add medic event batching from clients.
- Validate sender ownership on server.
- Include medic aggregates in finish payload.

### Phase 5: Hardening

- Add HMAC signatures or mTLS.
- Add token rotation workflow.
- Add reverse proxy IP allowlisting.
- Add monitoring, rate limits, and audit logs.

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
Design and implement the first version of a general Arma 3 stats tracking system based on docs/general-stats-tracking-design.md.

Important context:
- The system should use an extra client/server addon plus a server-only mod.
- The server-only mod is the only part allowed to know API credentials.
- Clients must never receive API tokens or backend credentials.
- The backend ingest API must be secured so only the trusted dedicated server can submit data.
- Runtime collection should be low overhead and should avoid per-event HTTP/database/file writes.
- Use these reference repositories for architecture and contract guidance:
  - https://github.com/JTM-rootstorm/arma-attendance-web
  - https://github.com/JTM-rootstorm/arma-attendance-server-extension

Requirements:
1. Inspect the existing project structure before editing.
2. Keep all code and documentation in English.
3. Review the reference repositories' operation start/finish contract, presence ledger, queue behavior, and backend normalization before designing the Gruppe 9 implementation.
4. Create or update mission/serverMod scripts for operation start/finish stats collection.
5. Capture scoreboard baseline at operation start and latest scores at finish.
6. Key all player data by `getPlayerUID`, not by name.
7. Filter out headless clients.
8. Build a finish payload with operation metadata, attendance data, scoreboard deltas, and raw baseline/latest arrays.
9. Keep secrets only in server-only config or environment variables.
10. Design backend ingest endpoints with bearer-token authentication, scoped machine tokens, idempotent request IDs, payload validation, and server_key checks.
11. Add a local retry queue for operation submissions.
12. Avoid direct client-to-backend communication.
13. Document required firewall/reverse-proxy restrictions for the API.

Security requirements:
- Do not put API tokens into client-loaded PBOs or mission files.
- Do not log Authorization headers or raw secrets.
- Add idempotency by `request_id`.
- Validate that token scope and `server_key` match the operation.
- Reject replay/conflict cases where the same `request_id` is reused with a different payload hash.
- Prefer HTTPS, IP allowlisting, and HMAC request signatures for production.

Nice-to-have:
- Add a debug mode that writes the generated operation payload to RPT without secrets.
- Add a health/poke command for backend connectivity.
- Add a backend schema draft or migration files if a backend exists in this repository.
- Keep raw payloads and normalized tables separated.

Do not:
- Implement loadout, position, vehicle, or full ACE medical-state persistence unless explicitly requested.
- Track raw damage events in version 1.
- Write to the backend on every small event.
- Use player names as identity.
- Modify unrelated server automation files unless required for integration.
```
