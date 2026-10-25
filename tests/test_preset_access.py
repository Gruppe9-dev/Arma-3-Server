"""Operator preset-import authorization through the real job queue, offline."""

from pathlib import Path
import tempfile
import types
import unittest
from unittest.mock import AsyncMock, Mock, patch

import discord

from test_bot import interaction
from access import AccessPolicy
import config
from cogs.mods import ModsCog
from jobs import JobRunner, JobStore


def preset_policy():
    return AccessPolicy({"schema_version": 1, "owner_user_ids": ["1"], "guilds": {
        "10": {"profiles": {"main": {
            "operator_role_ids": ["100"], "viewer_role_ids": ["101"], "viewer_user_ids": ["3"],
        }}, "arsenal_profiles": {"sd60-default": {"editor_role_ids": ["300"]}}},
        "20": {"profiles": {"friend": {"operator_user_ids": ["4"]}}},
    }})


class PresetPermissionTests(unittest.TestCase):
    def test_operator_roles_and_users_can_import_only_their_assigned_profiles(self):
        policy = preset_policy()
        self.assertTrue(policy.allows(10, 2, {100}, "preset-import", "main"))
        self.assertTrue(policy.allows(20, 4, set(), "preset-import", "friend"))
        self.assertFalse(policy.allows(10, 2, {100}, "preset-import", "friend"))
        self.assertFalse(policy.allows(20, 2, {100}, "preset-import", "main"))
        self.assertFalse(policy.allows(10, 1, set(), "preset-import", "friend"))

    def test_viewers_and_arsenal_editors_do_not_gain_import_or_shared_maintenance(self):
        policy = preset_policy()
        for user, roles in [(3, set()), (2, {101}), (2, {300}), (2, set())]:
            self.assertFalse(policy.allows(10, user, roles, "preset-import", "main"))
        for action in ("mods-sync", "mods-update", "update"):
            self.assertFalse(policy.allows(10, 2, {100}, action, "main"))


class PresetImportTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.store = JobStore(Path(self.folder.name) / "jobs.sqlite3")
        self.bot = types.SimpleNamespace(jobs=JobRunner(self.store))
        self.cog = ModsCog(self.bot)
        self.attachment = types.SimpleNamespace(filename="fixture.html", size=32,
                                                read=AsyncMock(return_value=b"<html>Offline preset fixture</html>"))
        self.patches = [patch.object(config, "ACCESS_POLICY", preset_policy()),
                        patch.object(config, "GUILD_IDS", (10, 20)),
                        patch("ssh_helper.upload_bytes", new_callable=AsyncMock),
                        patch("ssh_helper.run_ps_file", new_callable=AsyncMock, return_value=(0, "Import complete"))]
        for item in self.patches:
            item.start()
        import ssh_helper
        self.upload = ssh_helper.upload_bytes
        self.execute = ssh_helper.run_ps_file

    async def asyncTearDown(self):
        for item in reversed(self.patches):
            item.stop()
        self.store.db.close()
        self.folder.cleanup()

    def request(self, user=2, guild=10, roles=(100,)):
        request = interaction(user, guild)
        member = Mock(spec=discord.Member)
        member.id = user
        member.roles = [types.SimpleNamespace(id=role) for role in roles]
        request.user = member
        request.guild.fetch_member.return_value = member
        done = False

        async def defer(**kwargs):
            nonlocal done
            done = True

        request.response.defer.side_effect = defer
        request.response.is_done = lambda: done
        return request

    async def test_operator_import_reaches_the_host_without_granting_sync(self):
        request = self.request()
        await self.cog.mods_import_preset.callback(self.cog, request, "main", self.attachment, merge=True)
        self.upload.assert_awaited_once()
        self.execute.assert_awaited_once()
        call = self.execute.call_args
        self.assertEqual(call.args, ("mods/Import-Preset.ps1",))
        self.assertEqual(call.kwargs["Profile"], "main")
        self.assertTrue(call.kwargs["Merge"])
        self.assertFalse(call.kwargs["SyncAfter"])
        self.assertEqual(self.store.db.execute("SELECT action,status FROM jobs").fetchone(), ("preset-import", "completed"))

    async def test_direct_operator_user_grant_can_import(self):
        await self.cog.mods_import_preset.callback(self.cog, self.request(user=4, guild=20, roles=()), "friend", self.attachment)
        self.execute.assert_awaited_once()
        self.assertEqual(self.execute.call_args.kwargs["Profile"], "friend")

    async def test_viewer_foreign_profile_and_invalid_profile_fail_before_upload(self):
        for request, profile in [(self.request(user=3, roles=()), "main"), (self.request(roles=(101,)), "main"),
                                 (self.request(), "friend"), (self.request(user=1, roles=()), "friend"),
                                 (self.request(), "_all"), (self.request(), "../main")]:
            with self.subTest(profile=profile, roles=request.user.roles):
                await self.cog.mods_import_preset.callback(self.cog, request, profile, self.attachment)
                request.response.send_message.assert_awaited_once()
        self.upload.assert_not_awaited()
        self.execute.assert_not_awaited()
        self.attachment.read.assert_not_awaited()

    async def test_operator_cannot_bypass_shared_sync_via_import_option(self):
        request = self.request()
        await self.cog.mods_import_preset.callback(self.cog, request, "main", self.attachment, sync_after=True)
        self.upload.assert_not_awaited()
        self.execute.assert_not_awaited()
        self.assertIn("sync_after:false", request.response.send_message.call_args.args[0])

    async def test_owner_can_still_import_and_sync_for_an_assigned_profile(self):
        await self.cog.mods_import_preset.callback(self.cog, self.request(user=1, roles=()), "main", self.attachment, sync_after=True)
        self.execute.assert_awaited_once()
        self.assertTrue(self.execute.call_args.kwargs["SyncAfter"])

    async def test_role_revoked_before_execution_prevents_host_mutation(self):
        request = self.request()
        request.guild.fetch_member.return_value = self.request(roles=()).user
        await self.cog.mods_import_preset.callback(self.cog, request, "main", self.attachment)
        self.execute.assert_not_awaited()
        self.assertEqual(self.store.db.execute("SELECT status FROM jobs").fetchone()[0], "denied")

    async def test_operator_still_cannot_run_shared_sync_or_update_commands(self):
        for command in (self.cog.mods_sync, self.cog.mods_update):
            request = self.request()
            await command.callback(self.cog, request, "main")
            request.response.send_message.assert_awaited_once()
        self.execute.assert_not_awaited()

    async def test_legacy_admin_roles_keep_import_access(self):
        with patch.object(config, "ACCESS_POLICY", None), patch.object(config, "ADMIN_USER_IDS", set()), patch.object(config, "ADMIN_ROLE_IDS", {100}):
            await self.cog.mods_import_preset.callback(self.cog, self.request(), "main", self.attachment)
        self.execute.assert_awaited_once()


if __name__ == "__main__":
    unittest.main()
