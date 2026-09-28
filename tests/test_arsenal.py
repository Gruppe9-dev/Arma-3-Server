"""Offline SD60 Arsenal bot validation and persistence tests."""

import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bot"))
os.environ.update(
    DISCORD_BOT_TOKEN="test",
    DISCORD_GUILD_ID="10",
    BOT_ACCESS_CONFIG="",
    BOT_SSH_USER="test",
    BOT_SCRIPTS_PATH=r"C:\Test # Framework",
    DISCORD_ADMIN_ROLE_IDS="",
    BOT_ARSENAL_ENABLED="false",
)

from access import AccessPolicy
from arsenal_client import read_api_token
from arsenal_validation import (
    ArsenalValidationError,
    content_from_json,
    content_to_json,
    diff_content,
    parse_item_payload,
    parse_loadout_payload,
)
from cogs.arsenal import ArsenalCog
from jobs import JobStore


def arsenal_policy():
    return AccessPolicy({
        "schema_version": 1,
        "owner_user_ids": ["1"],
        "guilds": {
            "10": {
                "profiles": {},
                "arsenal_profiles": {
                    "sd60-default": {
                        "editor_role_ids": ["100"],
                        "publisher_user_ids": ["3"],
                        "viewer_user_ids": ["4"],
                    }
                },
            },
            "20": {"profiles": {}, "arsenal_profiles": {}},
        },
    })


def content(items=None, kits=None):
    return {
        "allowedItems": items or ["ItemMap"],
        "kits": kits or [{"id": "arc_default", "displayName": "ARC Default", "loadout": []}],
    }


class ArsenalAccessTests(unittest.TestCase):
    def test_arsenal_roles_are_profile_and_guild_scoped(self):
        policy = arsenal_policy()
        self.assertTrue(policy.allows_arsenal(10, 2, {100}, "edit", "sd60-default"))
        self.assertFalse(policy.allows_arsenal(10, 2, {100}, "publish", "sd60-default"))
        self.assertTrue(policy.allows_arsenal(10, 3, set(), "publish", "sd60-default"))
        self.assertTrue(policy.allows_arsenal(10, 4, set(), "view", "sd60-default"))
        self.assertFalse(policy.allows_arsenal(10, 4, set(), "edit", "sd60-default"))
        self.assertFalse(policy.allows_arsenal(20, 1, set(), "view", "sd60-default"))

    def test_unknown_arsenal_grants_fail_closed(self):
        payload = {
            "schema_version": 1,
            "owner_user_ids": [],
            "guilds": {"10": {
                "profiles": {},
                "arsenal_profiles": {"sd60-default": {"admin_role_ids": ["100"]}},
            }},
        }
        with self.assertRaises(ValueError):
            AccessPolicy(payload)


class ArsenalCommandRegistrationTests(unittest.TestCase):
    def test_expected_nested_slash_commands_are_registered(self):
        root_commands = {command.name: command for command in ArsenalCog.arsenal.commands}
        self.assertEqual(set(root_commands), {"items", "kits", "status", "diff", "discard", "publish"})
        self.assertEqual(
            {command.name for command in root_commands["items"].commands},
            {"add", "remove", "import"},
        )
        self.assertEqual(
            {command.name for command in root_commands["kits"].commands},
            {"import", "remove"},
        )


class ArsenalValidationTests(unittest.TestCase):
    def test_complete_ace_export_is_accepted_and_duplicates_are_reported(self):
        items, duplicates = parse_item_payload('["ACE_DefusalKit","ItemMap","ItemMap"]')
        self.assertEqual(items, ["ACE_DefusalKit", "ItemMap"])
        self.assertEqual(duplicates, 1)

    def test_non_json_and_injection_shaped_classnames_are_rejected(self):
        for payload in (
            '["ItemMap", player call compile "evil"]',
            '["ItemMap;deleteVehicle_player"]',
            '["../ItemMap"]',
        ):
            with self.subTest(payload=payload), self.assertRaises(ArsenalValidationError):
                parse_item_payload(payload)

    def test_loadout_bounds_and_forbidden_keys_are_enforced(self):
        self.assertEqual(parse_loadout_payload('["arifle_MX_F",[],[]]')[0], "arifle_MX_F")
        with self.assertRaises(ArsenalValidationError):
            parse_loadout_payload(json.dumps({"__proto__": {"polluted": True}}))
        nested = None
        for _ in range(18):
            nested = [nested]
        with self.assertRaises(ArsenalValidationError):
            parse_loadout_payload(json.dumps(nested))

    def test_snapshot_round_trip_and_diff_are_deterministic(self):
        active = content()
        draft = content(
            ["ItemMap", "ACE_DefusalKit"],
            [{"id": "arc_default", "displayName": "ARC Updated", "loadout": []}],
        )
        self.assertEqual(content_from_json(content_to_json(draft)), draft)
        diff = diff_content(active, draft)
        self.assertEqual(diff["added_items"], ["ACE_DefusalKit"])
        self.assertEqual(diff["changed_kits"], ["arc_default"])


class ArsenalDraftStoreTests(unittest.TestCase):
    def test_draft_survives_restart_and_uses_version_checks(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "jobs.db"
            first = JobStore(path)
            saved = first.save_arsenal_draft(
                "sd60-default", 10, 1, content_to_json(content()), 2,
                expected_version=None,
            )
            self.assertEqual(saved.version, 1)
            self.assertIsNone(first.save_arsenal_draft(
                "sd60-default", 10, 1, content_to_json(content()), 2,
                expected_version=99,
            ))
            first.db.close()

            second = JobStore(path)
            loaded = second.arsenal_draft("sd60-default")
            self.assertEqual((loaded.guild_id, loaded.base_revision, loaded.version), (10, 1, 1))
            self.assertTrue(second.remove_arsenal_draft("sd60-default", expected_version=1))
            self.assertIsNone(second.arsenal_draft("sd60-default"))
            second.db.close()


class ArsenalTokenTests(unittest.TestCase):
    def test_token_file_is_bounded(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "token.txt"
            path.write_text("a" * 128, encoding="utf-8")
            self.assertEqual(read_api_token(str(path)), "a" * 128)
            path.write_text("short", encoding="utf-8")
            with self.assertRaises(ValueError):
                read_api_token(str(path))


if __name__ == "__main__":
    unittest.main()
