"""Offline SD60 Arsenal bot validation and persistence tests."""

import json
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, Mock, call, patch

import discord

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
from cogs.arsenal import ArsenalCog, _profile_display_name, _profile_key
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
    def test_instance_operators_can_use_all_configured_arsenal_actions_in_their_guild(self):
        payload = {
            "schema_version": 1, "owner_user_ids": [], "guilds": {
                "10": {"profiles": {"60th": {"operator_role_ids": ["100"], "viewer_role_ids": ["200"]}},
                       "arsenal_profiles": {"sd60-default": {}}},
                "20": {"profiles": {}, "arsenal_profiles": {"other": {}}},
            },
        }
        policy = AccessPolicy(payload)
        for action in ("view", "edit", "publish"):
            self.assertTrue(policy.allows_arsenal(10, 2, {100}, action, "sd60-default"))
            self.assertFalse(policy.allows_arsenal(10, 2, {200}, action, "sd60-default"))
            self.assertFalse(policy.allows_arsenal(20, 2, {100}, action, "other"))
            self.assertFalse(policy.allows_arsenal(10, 2, {100}, action, "other"))
            self.assertFalse(policy.allows_arsenal(10, 2, {100}, action, "missing"))

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


class ArsenalCommandRegistrationTests(unittest.IsolatedAsyncioTestCase):
    def test_default_profile_has_the_requested_alias_and_visible_name(self):
        self.assertEqual(_profile_display_name("sd60-default"), "60th")
        self.assertEqual(_profile_display_name("future-profile"), "future-profile")
        self.assertEqual(_profile_key("60th"), "sd60-default")
        self.assertEqual(_profile_key("60TH"), "sd60-default")
        self.assertEqual(_profile_key("sd60-default"), "sd60-default")

    async def test_autocomplete_submits_the_public_profile_alias(self):
        policy = SimpleNamespace(
            arsenal_profiles={10: {"sd60-default": object()}},
        )
        interaction = SimpleNamespace(guild_id=10)
        with (
            patch("cogs.arsenal.config.ACCESS_POLICY", policy),
            patch("cogs.arsenal.utils.can_access_arsenal", return_value=True),
        ):
            choices = await ArsenalCog._profile_choices(None, interaction, "60")

        self.assertEqual(
            [(choice.name, choice.value) for choice in choices],
            [("60th", "60th")],
        )

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

    async def test_attachment_import_prefers_the_direct_discord_url(self):
        payload = b'["ItemMap"]'
        attachment = SimpleNamespace(
            id=123,
            filename="allowed-items.json",
            size=len(payload),
            read=AsyncMock(return_value=payload),
        )

        result = await ArsenalCog._read_input(None, attachment)

        self.assertEqual(result, payload)
        self.assertEqual(attachment.read.await_args_list, [call(use_cached=False)])

    async def test_attachment_import_falls_back_to_the_discord_proxy(self):
        payload = b'["ItemMap"]'
        response = SimpleNamespace(status=404, reason="Not Found")
        attachment = SimpleNamespace(
            id=123,
            filename="allowed-items.json",
            size=len(payload),
            read=AsyncMock(side_effect=[
                discord.NotFound(response, {"message": "Unknown attachment", "code": 10008}),
                payload,
            ]),
        )

        result = await ArsenalCog._read_input(None, attachment)

        self.assertEqual(result, payload)
        self.assertEqual(
            attachment.read.await_args_list,
            [call(use_cached=False), call(use_cached=True)],
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


class ArsenalOperatorWorkflowTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.store = JobStore(Path(self.folder.name) / "jobs.db")
        self.cog = object.__new__(ArsenalCog)
        self.cog.bot = SimpleNamespace(store=self.store)
        self.cog._locks = {}
        self.cog.client = SimpleNamespace(
            get_active=AsyncMock(return_value={"revision": {"number": 1}, "arsenal": content()}),
            publish=AsyncMock(return_value={"revision": 2, "replayed": False}),
        )
        rules = AccessPolicy({"schema_version": 1, "owner_user_ids": [], "guilds": {
            "10": {"profiles": {"60th": {"operator_role_ids": ["100"]}},
                   "arsenal_profiles": {"sd60-default": {"viewer_role_ids": ["200"]}}},
        }})
        self.patch = patch("cogs.arsenal.config.ACCESS_POLICY", rules)
        self.patch.start()

    async def asyncTearDown(self):
        self.patch.stop()
        self.store.db.close()
        self.folder.cleanup()

    @staticmethod
    def request(roles=(100,)):
        member = Mock(spec=discord.Member)
        member.id = 2
        member.roles = [SimpleNamespace(id=role) for role in roles]
        return SimpleNamespace(
            id=12345, user=member, guild_id=10,
            guild=SimpleNamespace(fetch_member=AsyncMock(return_value=member)),
            response=SimpleNamespace(defer=AsyncMock(), send_message=AsyncMock()),
            edit_original_response=AsyncMock(),
        )

    async def preview(self):
        request = self.request()
        await self.cog.items_add.callback(self.cog, request, "60th", "ItemCompass")
        await self.cog.arsenal_publish.callback(self.cog, request, "60th")
        return request.edit_original_response.call_args.kwargs["view"]

    async def test_operator_can_edit_and_confirm_publication_without_separate_arsenal_roles(self):
        view = await self.preview()
        request = self.request()
        self.assertTrue(await view.interaction_check(request))
        await view.confirm.callback(request)
        self.cog.client.publish.assert_awaited_once()
        args = self.cog.client.publish.call_args.args
        self.assertEqual(args[:5], ("sd60-default", 1, "discord:12345", 10, 2))
        self.assertIn("ItemCompass", args[5]["allowedItems"])
        self.assertIsNone(self.store.arsenal_draft("sd60-default"))

    async def test_role_revoked_after_preview_blocks_publication_and_keeps_the_draft(self):
        view = await self.preview()
        request = self.request()
        request.guild.fetch_member.return_value = self.request(roles=()).user
        await view.confirm.callback(request)
        self.cog.client.publish.assert_not_awaited()
        self.assertIsNotNone(self.store.arsenal_draft("sd60-default"))
        self.assertIn("access changed", request.edit_original_response.call_args.kwargs["content"])

    async def test_viewer_cannot_edit_or_request_publication(self):
        request = self.request(roles=(200,))
        await self.cog.items_add.callback(self.cog, request, "60th", "ItemCompass")
        await self.cog.arsenal_publish.callback(self.cog, request, "60th")
        self.cog.client.get_active.assert_not_awaited()
        self.cog.client.publish.assert_not_awaited()
        self.assertIsNone(self.store.arsenal_draft("sd60-default"))

    async def test_role_revoked_during_api_read_blocks_the_publish_request(self):
        view = await self.preview()
        request = self.request()

        async def read(profile):
            request.guild.fetch_member.return_value = self.request(roles=()).user
            return {"revision": {"number": 1}, "arsenal": content()}

        self.cog.client.get_active.side_effect = read
        await view.confirm.callback(request)
        self.cog.client.publish.assert_not_awaited()
        self.assertIsNotNone(self.store.arsenal_draft("sd60-default"))


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
