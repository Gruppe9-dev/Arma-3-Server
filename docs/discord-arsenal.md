# SD60 Arsenal Discord workflow

The bot can manage SD60 Arsenal drafts without receiving PostgreSQL credentials.
The backend publisher API remains private to Docker and creates one complete,
immutable snapshot per publication.

## Access policy

Add an `arsenal_profiles` object to the applicable guild in
`config/access.json`:

```json
{
  "arsenal_profiles": {
    "sd60-default": {
      "editor_role_ids": ["EDITOR_ROLE_ID"],
      "editor_user_ids": [],
      "publisher_role_ids": ["PUBLISHER_ROLE_ID"],
      "publisher_user_ids": [],
      "viewer_role_ids": [],
      "viewer_user_ids": []
    }
  }
}
```

Owners and instance operators may view, edit, discard, and publish Arsenal profiles
configured in their current Discord guild. The operator grant comes from any
instance's existing `operator_role_ids` / `operator_user_ids` in that guild; no
duplicate Arsenal editor/publisher grant is required. The target Arsenal profile
must still appear in that guild's `arsenal_profiles` object. Operator access does
not cross guild boundaries. Instance Viewer roles do not gain mutation rights.

Separate Arsenal-only grants remain available: editors may change the draft,
publishers may confirm publication, and viewers may inspect status and diff.
Permissions are fetched again immediately before a draft mutation, discard, or
publication.

## Commands

Use `60th` for the Discord `profile` option. The bot maps this public alias to
the internal backend key `sd60-default`. Keep `config/access.json` and
`BOT_ARSENAL_PROFILES` configured with the internal key `sd60-default`.

| Command | Purpose |
| --- | --- |
| `/arsenal status profile` | Show the active revision and persisted draft |
| `/arsenal items add profile classname` | Add one classname |
| `/arsenal items remove profile classname` | Remove one classname |
| `/arsenal items import profile mode data attachment` | Bulk merge, replace, or remove a JSON classname array |
| `/arsenal kits import profile kit_id display_name data attachment` | Add or replace one `getUnitLoadout` JSON kit |
| `/arsenal kits remove profile kit_id` | Remove a kit |
| `/arsenal diff profile` | Preview item and kit changes |
| `/arsenal discard profile` | Delete the unpublished draft |
| `/arsenal publish profile` | Confirm and atomically publish a new revision |

For import commands, provide exactly one of `data` or `attachment`. Attachments
must be UTF-8 JSON/TXT and no larger than 512 KiB. The bot parses strict JSON; it
never executes SQF, Python, shell, or SQL from an import.

## Export from Arma

Look at the configured ACE Arsenal object and run locally in the debug console:

```sqf
private _items = keys (cursorObject call ace_arsenal_fnc_getVirtualItems);
_items sort true;
copyToClipboard (toJSON _items);
hint format ["%1 ACE Arsenal items copied to clipboard.", count _items];
```

Paste a short result into the `data` option or save a large result as
`allowed-items.json` and upload it as `attachment`.

Export the current player loadout for a kit:

```sqf
copyToClipboard (toJSON (getUnitLoadout player));
```

## Docker startup

The backend stack must create the private `sd60-arsenal-admin` network first.
Configure the `BOT_ARSENAL_*` variables from `.env.example`, then start the bot
with the integration override:

```powershell
docker compose -f docker-compose.yml -f docker-compose.arsenal.yml up -d --build arma-bot
```

Use both `-f` options for every later bot recreation or image rebuild. Running
`up` with only `docker-compose.yml` removes the Arsenal secret mount and private
network from the recreated bot, even if `BOT_ARSENAL_ENABLED=true` remains set.

If startup reports `Arsenal publisher token file is missing or too large`, check
the deployment configuration before replacing credentials. The expected container
file `/run/secrets/arsenal_publisher_token` is mounted only by this override.
`BOT_ARSENAL_TOKEN_SOURCE` must point to the existing publisher token file on the
host (up to 512 bytes), rather than to its parent directory. Do not print or paste
the token contents into logs or chat. Reapply the correct mounts to an already
built image with:

```powershell
docker compose -f docker-compose.yml -f docker-compose.arsenal.yml up -d --force-recreate arma-bot
docker compose -f docker-compose.yml -f docker-compose.arsenal.yml logs --tail 80 arma-bot
```

The bot must use the existing publisher credential; generating an unrelated token
would cause API authentication to fail. Restoring the mounts preserves drafts and
server panel identities in the existing `bot/data` directory.

Drafts are stored in the existing mounted `bot/data/jobs.sqlite3` and survive a
bot rebuild. Published snapshots become active in Arma at the next mission start.

## Fragmented API responses

The API client reads the complete HTTP body before parsing JSON, enforcing a
768 KiB limit across all received chunks. The same limit applies after automatic
HTTP decompression. A single `StreamReader.read(n)` is insufficient: it may return
only the currently buffered part of a valid response. Older bot images can
therefore report `INVALID_RESPONSE` with an `Unterminated string` JSON error as
the active Arsenal snapshot grows or arrives in multiple packets.

Deploy the updated `bot/arsenal_client.py` and rebuild the bot with both Compose
files as shown above. No publisher API, token or draft reset is required for this
client fix. A failed active-snapshot read occurs before the draft mutation is
saved. Retry the edit/import after deployment. Truly malformed or oversized
responses still fail safely; HTTP requests are not automatically replayed.
