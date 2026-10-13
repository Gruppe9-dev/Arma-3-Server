"""SSH burst/retry and cross-guild status regressions, without remote connections."""

import asyncio
import json
import types
import unittest
from unittest.mock import AsyncMock, Mock, patch

from test_bot import config  # Initialize the offline bot environment before imports.
import asyncssh
import discord
import ssh_helper
from cogs.server import ServerCog
from control_panel import ServerControlView
from presentation import status_embed


def status():
    return dict(Profile="60th", Running=True, Port=2502, UptimeSeconds=10,
                CpuPercent=5, RamMB=2048, PID=55, Processes=3, HeadlessClients=2,
                Preset="default", Mission="Fixture mission")


class SnapshotTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.cog = ServerCog(types.SimpleNamespace())

    async def asyncTearDown(self):
        await self.cog.cog_unload()

    async def test_two_guilds_share_host_read_and_game_query_with_independent_embeds(self):
        async def read(*args):
            await asyncio.sleep(0.01)
            return [status()]

        info = types.SimpleNamespace(player_count=8, max_players=40, map_name="Altis")
        with patch.object(self.cog, "_status", side_effect=read) as host, patch("cogs.server.a2s.info", return_value=info) as query:
            first, second = await asyncio.gather(self.cog._snapshot("60th"), self.cog._snapshot("60th"))
            cached = await self.cog._snapshot("60th")
        host.assert_awaited_once_with("60th")
        query.assert_called_once()
        first[0].title = "Local edit"
        self.assertNotEqual(first[0].title, second[0].title)
        self.assertNotEqual(first[0].title, cached[0].title)

    async def test_cancelling_one_panel_does_not_cancel_other_guilds_snapshot(self):
        started = asyncio.Event()
        release = asyncio.Event()

        async def read(profile):
            started.set()
            await release.wait()
            return discord.Embed(title="Online"), True

        with patch.object(self.cog, "_read_snapshot", side_effect=read) as host:
            first = asyncio.create_task(self.cog._snapshot("60th"))
            second = asyncio.create_task(self.cog._snapshot("60th"))
            await started.wait()
            first.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await first
            release.set()
            embed, running = await second
        host.assert_awaited_once_with("60th")
        self.assertTrue(running)
        self.assertEqual(embed.title, "Online")

    async def test_post_action_refresh_does_not_accept_an_older_inflight_read(self):
        started = asyncio.Event()
        release = asyncio.Event()

        async def old_read(profile):
            started.set()
            await release.wait()
            return discord.Embed(title="Before action"), False

        self.cog.bot.store = types.SimpleNamespace(panels=lambda: [], control_panels=lambda: [])
        with patch.object(self.cog, "_read_snapshot", side_effect=old_read):
            old = asyncio.create_task(self.cog._snapshot("60th"))
            await started.wait()
            self.cog.refresh_panels("60th")
            with patch.object(self.cog, "_read_snapshot", return_value=(discord.Embed(title="After action"), True)) as fresh:
                current = await self.cog._snapshot("60th")
            release.set()
            await old
        self.assertTrue(current[1])
        fresh.assert_awaited_once()
        self.assertEqual(self.cog._last_snapshots["60th"].title, "After action")

    async def test_failures_preserve_stats_as_explicitly_stale_and_recover(self):
        with patch.object(self.cog, "_read_snapshot", return_value=(status_embed("60th", status()), True)):
            await self.cog._snapshot("60th")
        self.cog._snapshot_cache.clear()
        with patch.object(self.cog, "_read_snapshot", side_effect=RuntimeError("SSH failed")) as host:
            for _ in range(2):
                with self.assertRaises(RuntimeError):
                    await self.cog._snapshot("60th")
        host.assert_awaited_once()  # Failure cooldown also coalesces staggered panels.
        delayed = self.cog._delayed_snapshot("60th")
        self.assertIn("delayed", delayed.title)
        self.assertIn("last confirmed", delayed.description)
        self.assertIn("current server state is unknown", delayed.description)
        self.assertEqual(delayed.timestamp, self.cog._last_snapshots["60th"].timestamp)
        self.assertEqual(len(delayed.fields), len(self.cog._last_snapshots["60th"].fields))
        self.assertIn("Server Running", self.cog._last_snapshots["60th"].title)
        self.cog._snapshot_errors.clear()
        with patch.object(self.cog, "_read_snapshot", return_value=(discord.Embed(title="Recovered"), True)):
            recovered, running = await self.cog._snapshot("60th")
        self.assertEqual(recovered.title, "Recovered")
        self.assertTrue(running)

    async def test_cold_start_failure_does_not_invent_a_last_known_state(self):
        embed = self.cog._delayed_snapshot("60th")
        self.assertIn("Status unavailable", embed.title)
        self.assertFalse(embed.fields)
        view = ServerControlView(self.cog, 10, "60th")
        self.assertTrue(view.start.disabled)
        self.assertTrue(view.stop_server.disabled)
        self.assertFalse(view.refresh.disabled)
        view.stop()

    async def test_panel_keeps_last_stats_during_failure_and_resumes_with_fresh_offline_state(self):
        edits = []
        message = types.SimpleNamespace(edit=AsyncMock(side_effect=lambda **kwargs: edits.append(kwargs["embed"])))
        channel = types.SimpleNamespace(guild=types.SimpleNamespace(id=10), get_partial_message=lambda _: message)
        self.cog.bot.get_channel = lambda _: channel
        offline = status()
        offline["Running"] = False

        async def next_cycle(delay):
            self.cog._snapshot_cache.clear()
            self.cog._snapshot_errors.clear()

        with patch.object(self.cog, "_read_snapshot", side_effect=[(status_embed("60th", status()), True), RuntimeError("SSH failed"), (status_embed("60th", offline), False)]), patch("cogs.server.asyncio.sleep", new_callable=AsyncMock, side_effect=next_cycle):
            await self.cog._panel_loop(10, "60th", 11, 12)
        self.assertEqual(len(edits), 3)
        self.assertIn("delayed", edits[1].title)
        self.assertEqual(edits[0].fields, edits[1].fields)
        self.assertIn("Offline", edits[2].title)
        self.assertNotIn("delayed", edits[2].title)

    async def test_read_only_status_retries_transport_failure_but_not_host_errors(self):
        response = "INSTANCE_JSON=" + json.dumps([status()])
        with patch("ssh_helper.run_ps_file", side_effect=[(255, "connection lost"), (0, response)]) as read, patch("cogs.server.asyncio.sleep", new_callable=AsyncMock):
            self.assertEqual(await self.cog._status("60th"), [status()])
        self.assertEqual(read.await_count, 2)
        with patch("ssh_helper.run_ps_file", return_value=(1, "Host access denied")) as read:
            with self.assertRaises(RuntimeError):
                await self.cog._status("60th")
        read.assert_awaited_once()


class SSHReliabilityTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.lock_patch = patch.object(ssh_helper, "_connect_lock", asyncio.Lock())
        self.lock_patch.start()

    async def asyncTearDown(self):
        self.lock_patch.stop()

    @staticmethod
    def connection():
        connection = Mock()
        connection.__aenter__ = AsyncMock(return_value=connection)
        connection.__aexit__ = AsyncMock(return_value=False)
        return connection

    async def test_handshakes_are_serialized_while_commands_can_overlap(self):
        active = 0
        maximum = 0
        command_active = 0
        maximum_commands = 0

        async def connect(**kwargs):
            nonlocal active, maximum
            active += 1
            maximum = max(maximum, active)
            await asyncio.sleep(0.01)
            active -= 1
            return self.connection()

        async def command():
            nonlocal command_active, maximum_commands
            async with ssh_helper._connect():
                command_active += 1
                maximum_commands = max(maximum_commands, command_active)
                await asyncio.sleep(0.04)
                command_active -= 1

        with patch("asyncssh.connect", new_callable=AsyncMock, side_effect=connect), patch("ssh_helper._connection_params", return_value={}):
            await asyncio.gather(command(), command(), command())
        self.assertEqual(maximum, 1)
        self.assertGreater(maximum_commands, 1)

    async def test_handshake_loss_is_retried_before_command_submission(self):
        conn = self.connection()
        conn.run = AsyncMock(return_value=types.SimpleNamespace(stdout="done", stderr="", returncode=0))
        with patch("ssh_helper.Path.is_file", return_value=True), patch("ssh_helper._connection_params", return_value={}), patch(
            "asyncssh.connect", new_callable=AsyncMock, side_effect=[asyncssh.ConnectionLost("Connection lost"), conn]
        ) as connect, patch("ssh_helper.asyncio.sleep", new_callable=AsyncMock):
            result = await ssh_helper._exec("fixed fixture command")
        self.assertEqual(result, (0, "done"))
        self.assertEqual(connect.await_count, 2)
        conn.run.assert_awaited_once()

    async def test_lost_running_command_is_never_replayed(self):
        conn = self.connection()
        conn.run = AsyncMock(side_effect=asyncssh.ConnectionLost("Connection lost during command"))
        with patch("ssh_helper.Path.is_file", return_value=True), patch("ssh_helper._connection_params", return_value={}), patch("asyncssh.connect", new_callable=AsyncMock, return_value=conn) as connect:
            result = await ssh_helper._exec("mutation fixture command")
        self.assertEqual(result[0], 255)
        connect.assert_awaited_once()
        conn.run.assert_awaited_once()

    async def test_security_errors_and_exhausted_handshakes_fail_without_running_a_command(self):
        for error, count in [(asyncssh.PermissionDenied("Denied"), 1),
                             (asyncssh.HostKeyNotVerifiable("Wrong host key"), 1),
                             (asyncssh.ConnectionLost("Connection lost"), 3)]:
            with self.subTest(error=type(error).__name__), patch("ssh_helper.Path.is_file", return_value=True), patch("ssh_helper._connection_params", return_value={}), patch("asyncssh.connect", new_callable=AsyncMock, side_effect=error) as connect, patch("ssh_helper.asyncio.sleep", new_callable=AsyncMock):
                result = await ssh_helper._exec("fixed fixture command")
            self.assertEqual(result[0], 255)
            self.assertEqual(connect.await_count, count)


if __name__ == "__main__":
    unittest.main()
