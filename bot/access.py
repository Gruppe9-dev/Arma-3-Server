"""Guild-scoped authorization, independent of Discord for direct testing."""

import json
import re
from pathlib import Path

PROFILE_RE = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}\Z")
INSTANCE_ACTIONS = frozenset({"start", "stop", "restart", "preset", "status", "list"})


def valid_profile(value: str) -> bool:
    return isinstance(value, str) and PROFILE_RE.fullmatch(value) is not None


def _ids(values: object) -> frozenset[int]:
    if not isinstance(values, list):
        raise ValueError("IDs must be an array of Discord snowflake strings")
    result = set()
    for value in values:
        if isinstance(value, bool) or not str(value).isdigit() or not 0 < int(value) < 2**64:
            raise ValueError("Invalid Discord ID in access configuration")
        result.add(int(value))
    return frozenset(result)


class AccessPolicy:
    def __init__(self, data: dict):
        if not isinstance(data, dict) or data.get("schema_version") != 1:
            raise ValueError("Access configuration requires schema_version 1")
        self.owners = _ids(data.get("owner_user_ids", []))
        guilds = data.get("guilds")
        if not isinstance(guilds, dict) or not guilds:
            raise ValueError("Configure at least one allowed guild")
        self.guilds: dict[int, dict[str, dict[str, frozenset[int]]]] = {}
        for guild_id, guild in guilds.items():
            parsed_id = next(iter(_ids([guild_id])))
            if not isinstance(guild, dict) or not isinstance(guild.get("profiles"), dict):
                raise ValueError("Each guild requires a profiles object")
            profiles = {}
            for profile, grants in guild["profiles"].items():
                if not valid_profile(profile) or not isinstance(grants, dict):
                    raise ValueError("Invalid profile access rule")
                supported = {"operator_user_ids", "operator_role_ids", "viewer_user_ids", "viewer_role_ids"}
                if set(grants) - supported:
                    raise ValueError("Unknown access rule field")
                profiles[profile] = {key: _ids(grants.get(key, [])) for key in supported}
            self.guilds[parsed_id] = profiles

    @classmethod
    def load(cls, path: str):
        with Path(path).open("rb") as file:
            raw = file.read(256 * 1024 + 1)
        if len(raw) > 256 * 1024:
            raise ValueError("Access configuration exceeds 256 KiB")
        return cls(json.loads(raw.decode("utf-8-sig")))

    def is_owner(self, guild_id: int | None, user_id: int) -> bool:
        return guild_id in self.guilds and user_id in self.owners

    def allows(self, guild_id: int | None, user_id: int, roles: set[int], action: str, profile: str) -> bool:
        if guild_id not in self.guilds or not valid_profile(profile) or action not in INSTANCE_ACTIONS:
            return False
        # Bind the target to this guild even for owners, so its status cannot be
        # accidentally published into another community's channel.
        rule = self.guilds[guild_id].get(profile)
        if rule is None:
            return False
        if self.is_owner(guild_id, user_id):
            return True
        operator = user_id in rule["operator_user_ids"] or bool(roles & rule["operator_role_ids"])
        viewer = user_id in rule["viewer_user_ids"] or bool(roles & rule["viewer_role_ids"])
        return operator or (action in {"status", "list"} and viewer)
