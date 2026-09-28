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

Owners may view, edit, and publish configured profiles. Editors may change the
draft. Publishers may confirm publication. Viewers may inspect status and diff.
Permissions are fetched again immediately before a draft mutation, discard, or
publication.

## Commands

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

Drafts are stored in the existing mounted `bot/data/jobs.sqlite3` and survive a
bot rebuild. Published snapshots become active in Arma at the next mission start.
