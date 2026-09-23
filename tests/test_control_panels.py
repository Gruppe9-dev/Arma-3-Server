"""Persistent panel lifecycle and authorization, without Discord/SSH connections."""

import asyncio
from pathlib import Path
import tempfile
import types
import unittest
from unittest.mock import AsyncMock, Mock, patch

import discord

from test_bot import interaction, policy
import config
from cogs.server import ServerCog
from control_panel import ServerControlView
from jobs import JobRunner, JobStore


class ControlPanelTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.path = Path(self.folder.name) / "jobs.sqlite3"
        self.store = JobStore(self.path)
        self.message = types.SimpleNamespace(id=12, edit=AsyncMock())
        self.permissions = discord.Permissions(view_channel=True, send_messages=True,
                                               embed_links=True, manage_channels=True)
        self.channel = types.SimpleNamespace(id=11, guild=types.SimpleNamespace(id=10),
                                             get_partial_message=Mock(return_value=self.message),
                                             send=AsyncMock(return_value=self.message),
                                             permissions_for=Mock(return_value=self.permissions))
        self.bot = types.SimpleNamespace(store=self.store, jobs=JobRunner(self.store),
                                         add_view=Mock(), wait_until_ready=AsyncMock(),
                                         get_channel=Mock(return_value=self.channel), fetch_channel=AsyncMock())
        self.cog = ServerCog(self.bot)
        self.patches = [patch.object(config, "GUILD_IDS", (10, 20)), patch.object(config, "ACCESS_POLICY", policy())]
        for item in self.patches:
            item.start()

    async def asyncTearDown(self):
        await self.cog.cog_unload()
        for item in reversed(self.patches):
            item.stop()
        self.store.db.close()
        self.folder.cleanup()

    def request(self, user=2, guild=10, *, roles=(100,)):
        request = interaction(user, guild)
        member = Mock(spec=discord.Member)
        member.id = user
        member.roles = [types.SimpleNamespace(id=role) for role in roles]
        request.user = member
        request.guild.me = Mock(spec=discord.Member)
        request.guild.fetch_member.return_value = member
        request.channel = self.channel
        request.channel_id = self.channel.id
        request.message = self.message
        request.original_response = AsyncMock(return_value=types.SimpleNamespace(edit=AsyncMock()))
        request.followup = types.SimpleNamespace(send=AsyncMock())
        return request

    async def test_store_reopens_without_losing_legacy_or_control_identity(self):
        self.store.save_panel(10, "main", 8, 9)
        self.store.save_control_panel(10, "main", 11, 12)
        self.store.save_control_panel(20, "friend", 21, 22)
        self.store.db.close()
        self.store = JobStore(self.path)
        self.bot.store = self.store
        self.assertEqual(self.store.panels(), [("10", "main", "8", "9")])
        self.assertEqual(self.store.control_panel(10, "main"), ("11", "12"))
        self.store.save_control_panel(10, "main", 31, 32)
        self.store.remove_control_panel(10, "main", 12)
        self.assertEqual(self.store.control_panel(10, "main"), ("31", "32"))
        self.assertEqual(self.store.control_panel(20, "friend"), ("21", "22"))

    async def test_restoration_registers_persistent_buttons_before_ready_and_checks_scope(self):
        self.store.save_control_panel(10, "main", 11, 12)
        self.store.save_control_panel(20, "main", 21, 22)  # Not assigned to this guild.
        self.store.save_control_panel(30, "main", 31, 32)  # Guild no longer allowed.
        with patch.object(self.cog, "_track_panel") as track:
            await self.cog.cog_load()
            self.bot.add_view.assert_called_once()
            view = self.bot.add_view.call_args.args[0]
            self.assertTrue(view.is_persistent())
            self.assertEqual(self.bot.add_view.call_args.kwargs, {"message_id": 12})
            self.assertEqual(len({item.custom_id for item in view.children}), 3)
            await self.cog._restore_task
        track.assert_called_once_with(10, "main", 11, 12, control=True)

    async def test_restored_button_uses_private_job_and_retains_panel(self):
        self.store.save_control_panel(10, "main", 11, 12)
        self.store.db.close()
        self.store = JobStore(self.path)
        self.bot.store = self.store
        self.bot.jobs = JobRunner(self.store)
        view = self.cog._register_control(10, "main", 12)
        request = self.request()
        with patch("ssh_helper.run_ps_file", return_value=(0, "PRIVATE_HOST_LOG")) as execute, patch.object(self.cog, "refresh_panels") as refresh:
            await view.start.callback(request)
        execute.assert_awaited_once_with("scripts/Start-Server.ps1", Profile="main")
        self.channel.send.assert_not_awaited()
        request.response.defer.assert_awaited_once_with(ephemeral=True, thinking=True)
        self.assertIn("Completed", request.original_response.return_value.edit.call_args.kwargs["embed"].fields[1].value)
        self.assertEqual(self.store.control_panel(10, "main"), ("11", "12"))
        refresh.assert_called_once_with("main")
        self.assertEqual(self.store.db.execute("SELECT action,status FROM jobs").fetchone(), ("start", "completed"))

    async def test_viewer_can_refresh_but_cannot_start_or_stop(self):
        self.store.save_control_panel(10, "main", 11, 12)
        request = self.request(user=3, roles=())
        with patch.object(self.bot.jobs, "run", new_callable=AsyncMock) as run, patch.object(self.cog, "refresh_panels") as refresh:
            await self.cog.control_action(request, 10, "main", "start")
            await self.cog.control_action(request, 10, "main", "stop")
            run.assert_not_awaited()
            await self.cog.control_action(request, 10, "main", "status")
            await self.cog.control_action(request, 10, "main", "status")
            refresh.assert_called_once_with("main")
        self.assertIn("wait", request.response.send_message.call_args.args[0])

    async def test_cross_guild_channel_and_old_message_buttons_cannot_execute(self):
        self.store.save_control_panel(10, "main", 11, 12)
        for change in ("guild", "channel", "message"):
            request = self.request(user=1)
            if change == "guild":
                request.guild_id = 20
            elif change == "channel":
                request.channel_id = 99
            else:
                request.message = types.SimpleNamespace(id=99)
            with self.subTest(change=change), patch.object(self.bot.jobs, "run", new_callable=AsyncMock) as run:
                await self.cog.control_action(request, 10, "main", "start")
                run.assert_not_awaited()
                self.assertIn("no longer active", request.response.send_message.call_args.args[0])

    async def test_button_rechecks_revoked_role_before_host_execution(self):
        self.store.save_control_panel(10, "main", 11, 12)
        request = self.request()
        request.guild.fetch_member.return_value = self.request(roles=()).user
        with patch("ssh_helper.run_ps_file", new_callable=AsyncMock) as execute, patch.object(self.cog, "refresh_panels"):
            await self.cog.control_action(request, 10, "main", "stop")
        execute.assert_not_awaited()
        self.assertEqual(self.store.db.execute("SELECT status FROM jobs").fetchone()[0], "denied")

    async def test_double_click_does_not_queue_another_host_operation(self):
        self.store.save_control_panel(10, "main", 11, 12)
        started = asyncio.Event()
        release = asyncio.Event()

        async def run(*args, **kwargs):
            started.set()
            await release.wait()

        with patch.object(self.bot.jobs, "run", side_effect=run) as job, patch.object(self.cog, "refresh_panels"):
            first = asyncio.create_task(self.cog.control_action(self.request(), 10, "main", "start"))
            await started.wait()
            second = self.request(user=1)
            await self.cog.control_action(second, 10, "main", "start")
            self.assertIn("already in progress", second.response.send_message.call_args.args[0])
            release.set()
            await first
        self.assertEqual(job.await_count, 1)
        self.assertFalse(self.cog._control_busy)

    async def test_publish_reuses_same_message_and_moves_without_duplicate_controls(self):
        self.store.save_panel(10, "main", 7, 8)
        with patch.object(self.cog, "_track_panel"):
            first = await self.cog._publish_control(10, "main", self.channel)
            second = await self.cog._publish_control(10, "main", self.channel)
            self.assertEqual(first, second)
            self.channel.send.assert_awaited_once()
            self.assertFalse(self.store.panels())
            next_message = types.SimpleNamespace(id=32, edit=AsyncMock())
            next_channel = types.SimpleNamespace(id=31, send=AsyncMock(return_value=next_message))
            await self.cog._publish_control(10, "main", next_channel)
        self.assertEqual(self.store.control_panel(10, "main"), ("31", "32"))
        self.assertIsNone(self.message.edit.call_args.kwargs["view"])

    async def test_slash_start_refreshes_fixed_panel_instead_of_posting_another(self):
        self.store.save_control_panel(10, "main", 11, 12)
        with patch.object(self.cog, "refresh_panels") as refresh:
            await self.cog._ensure_panel(self.request(), "main")
        refresh.assert_called_once_with("main")
        self.channel.send.assert_not_awaited()

    async def test_offline_fixed_panel_stops_polling_but_keeps_start_button(self):
        self.store.save_control_panel(10, "main", 11, 12)
        with patch.object(self.cog, "_snapshot", return_value=(discord.Embed(title="Offline"), False)), patch("cogs.server.asyncio.sleep", new_callable=AsyncMock) as sleep:
            await self.cog._panel_loop(10, "main", 11, 12, control=True)
        view = self.message.edit.call_args.kwargs["view"]
        self.assertFalse(view.start.disabled)
        self.assertTrue(view.stop_server.disabled)
        self.assertFalse(view.refresh.disabled)
        sleep.assert_not_awaited()
        self.assertEqual(self.store.control_panel(10, "main"), ("11", "12"))

    async def test_running_and_unknown_states_keep_correct_controls(self):
        self.store.save_control_panel(10, "main", 11, 12)
        states = []

        async def edit(**kwargs):
            view = kwargs["view"]
            states.append((view.start.disabled, view.stop_server.disabled))

        self.message.edit.side_effect = edit
        with patch.object(self.cog, "_snapshot", side_effect=[(discord.Embed(), True), RuntimeError("offline host"), (discord.Embed(), False)]), patch("cogs.server.asyncio.sleep", new_callable=AsyncMock):
            await self.cog._panel_loop(10, "main", 11, 12, control=True)
        self.assertEqual(states, [(True, False), (False, False), (False, True)])

    async def test_forbidden_is_retried_without_forgetting_persistent_message(self):
        self.store.save_control_panel(10, "main", 11, 12)
        self.message.edit.side_effect = [discord.Forbidden(types.SimpleNamespace(status=403, reason="Forbidden"), "denied"), None]
        with patch.object(self.cog, "_snapshot", return_value=(discord.Embed(), False)), patch("cogs.server.asyncio.sleep", new_callable=AsyncMock) as sleep:
            await self.cog._panel_loop(10, "main", 11, 12, control=True)
        sleep.assert_awaited_once_with(60)
        self.assertEqual(self.store.control_panel(10, "main"), ("11", "12"))

    async def test_deleted_message_is_forgotten_and_can_be_recreated(self):
        self.store.save_control_panel(10, "main", 11, 12)
        self.message.edit.side_effect = discord.NotFound(types.SimpleNamespace(status=404, reason="Not Found"), "deleted")
        with patch.object(self.cog, "_snapshot", return_value=(discord.Embed(), False)):
            await self.cog._panel_loop(10, "main", 11, 12, control=True)
        self.assertIsNone(self.store.control_panel(10, "main"))
        self.assertNotIn((10, "main"), self.cog._control_views)

    async def test_command_validates_permissions_all_profiles_and_channel_before_publication(self):
        for profiles, user, roles, manage in [("main,friend", 1, (), True), ("main", 3, (), True),
                                             ("main", 2, (100,), False), ("../main", 1, (), True)]:
            self.permissions.manage_channels = manage
            request = self.request(user, roles=roles)
            with self.subTest(profiles=profiles, user=user, manage=manage), patch.object(self.cog, "_publish_control", new_callable=AsyncMock) as publish, patch.object(self.cog, "_status", new_callable=AsyncMock) as status:
                await self.cog.server_panel.callback(self.cog, request, self.channel, profiles)
                publish.assert_not_awaited()
                status.assert_not_awaited()
                request.response.send_message.assert_awaited_once()

    async def test_command_deduplicates_and_publishes_approved_profiles(self):
        with patch.object(self.cog, "_status", return_value=[{"Profile": "main"}]), patch.object(self.cog, "_publish_control", return_value="https://discord.test/panel") as publish:
            await self.cog.server_panel.callback(self.cog, self.request(), self.channel, "main, main")
        publish.assert_awaited_once_with(10, "main", self.channel)

    async def test_publication_rechecks_roles_after_waiting_for_host(self):
        request = self.request()
        request.guild.fetch_member.return_value = self.request(roles=()).user
        with patch.object(self.cog, "_status", return_value=[{"Profile": "main"}]), patch.object(self.cog, "_publish_control", new_callable=AsyncMock) as publish:
            await self.cog.server_panel.callback(self.cog, request, self.channel, "main")
        publish.assert_not_awaited()
        self.assertIn("access changed", request.edit_original_response.call_args.kwargs["content"])


if __name__ == "__main__":
    unittest.main()
