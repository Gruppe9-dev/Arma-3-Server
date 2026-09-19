"""Offline security/operation regressions. No Discord or SSH connections are made."""

import asyncio
import base64
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import AsyncMock, patch
import discord

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bot"))
os.environ.update(DISCORD_BOT_TOKEN="test", DISCORD_GUILD_ID="10", BOT_ACCESS_CONFIG="",
                  BOT_SSH_USER="test", BOT_SCRIPTS_PATH=r"C:\Test # Framework", DISCORD_ADMIN_ROLE_IDS="")
from access import AccessPolicy, valid_profile
import config
from jobs import JobRunner, JobStore
import ssh_helper
from cogs.automation import AutomationCog


def policy():
    return AccessPolicy({"schema_version": 1, "owner_user_ids": ["1"], "guilds": {
        "10": {"profiles": {"main": {"operator_role_ids": ["100"], "viewer_user_ids": ["3"]}}},
        "20": {"profiles": {"friend": {"operator_user_ids": ["2"]}}},
    }})


class AccessTests(unittest.TestCase):
    def test_operator_cannot_cross_guild_or_instance_boundaries(self):
        rules = policy()
        self.assertTrue(rules.allows(20, 2, set(), "start", "friend"))
        self.assertFalse(rules.allows(10, 2, set(), "start", "main"))
        self.assertFalse(rules.allows(20, 2, set(), "stop", "main"))
        self.assertFalse(rules.allows(30, 1, set(), "start", "main"))
        self.assertFalse(rules.allows(None, 1, set(), "start", "main"))

    def test_owner_is_bound_to_allowed_guilds_and_profile_publication(self):
        rules = policy()
        self.assertTrue(rules.is_owner(10, 1))
        self.assertFalse(rules.is_owner(30, 1))
        self.assertFalse(rules.allows(20, 1, set(), "status", "main"))

    def test_viewer_cannot_mutate_or_update_shared_files(self):
        rules = policy()
        self.assertTrue(rules.allows(10, 3, set(), "status", "main"))
        self.assertFalse(rules.allows(10, 3, set(), "stop", "main"))
        self.assertFalse(rules.allows(10, 2, {100}, "update", "main"))
        self.assertTrue(rules.allows(10, 2, {100}, "restart", "main"))

    def test_hostile_profile_names_are_rejected(self):
        for name in ("../main", "main -Force", "_all", "_template", "main\n", "main'", "main;exit", "A", "a" * 65):
            with self.subTest(name=name):
                self.assertFalse(valid_profile(name))

    def test_malformed_or_missing_policy_cannot_fall_back(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "access.json"
            with self.assertRaises(FileNotFoundError):
                AccessPolicy.load(str(path))
            path.write_text('{"schema_version":1,"guilds":{}}')
            with self.assertRaises(ValueError):
                AccessPolicy.load(str(path))
            path.write_bytes(b" " * (256 * 1024 + 1))
            with self.assertRaises(ValueError):
                AccessPolicy.load(str(path))


class CommandTests(unittest.TestCase):
    def test_values_are_encoded_as_data(self):
        value = "C:\\presets\\file' $(Write-Output INJECTED); x.html"
        code = ssh_helper.build_ps_invocation("mods/Import-Preset.ps1", {"PresetFile": value, "Profile": "main"})
        self.assertNotIn("INJECTED", code)
        payload = re.search(r"FromBase64String\('([^']+)'\)", code)[1]
        self.assertEqual(json.loads(base64.b64decode(payload))["PresetFile"], value)

    def test_scripts_and_parameters_are_allowlisted(self):
        for script, args in [("../evil.ps1", {}), ("scripts/Stop-Server.ps1", {"Force": True}),
                             ("scripts/Stop-Server.ps1", {"Profile": "main -Force"}),
                             ("scripts/Start-Server.ps1", {"Profile": "_all"})]:
            with self.assertRaises(ValueError):
                ssh_helper.build_ps_invocation(script, args)

    @unittest.skipUnless(sys.platform == "win32", "PowerShell boundary integration test")
    def test_powershell_preserves_values_and_exit_codes(self):
        with tempfile.TemporaryDirectory(prefix="arma-quote-#-") as folder:
            root = Path(folder) / "owner's framework"
            script = root / "mods" / "Import-Preset.ps1"
            script.parent.mkdir(parents=True)
            script.write_text("param([string]$Profile,[string]$PresetFile)\nWrite-Output $PresetFile\nexit 7\n")
            value = "file' $(Write-Output WRONG);.html"
            with patch.object(config, "SCRIPTS_PATH", str(root)):
                ps = ssh_helper.build_ps_invocation("mods/Import-Preset.ps1", {"Profile": "main", "PresetFile": value})
            encoded = base64.b64encode(ps.encode("utf-16-le")).decode()
            result = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded], capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 7, result.stderr)
            self.assertEqual(result.stdout.strip(), value)

    def test_connection_requires_pinned_host_keys(self):
        with patch.object(ssh_helper, "_get_key", return_value="test-key"):
            self.assertEqual(ssh_helper._connection_params()["known_hosts"], config.SSH_KNOWN_HOSTS)
            self.assertIsNotNone(ssh_helper._connection_params()["known_hosts"])


class StoreTests(unittest.TestCase):
    def test_restart_records_uncertainty_without_replaying_jobs(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "jobs.db"
            first = JobStore(path)
            job = first.create(10, 2, "main", "start")
            first.mark(job, "running")
            first.save_panel(10, "main", 11, 12)
            first.db.close()
            second = JobStore(path)
            self.assertEqual(second.db.execute("SELECT status FROM jobs WHERE id=?", (job,)).fetchone()[0], "interrupted")
            self.assertEqual(second.panels(), [("10", "main", "11", "12")])
            second.db.close()


def interaction(user, guild):
    response = types.SimpleNamespace(is_done=lambda: False, defer=AsyncMock(), send_message=AsyncMock())
    message = types.SimpleNamespace(edit=AsyncMock(), jump_url="https://discord.test/message")
    member = types.SimpleNamespace(id=user)
    return types.SimpleNamespace(user=member, guild_id=guild, response=response,
                                 channel=types.SimpleNamespace(send=AsyncMock(return_value=message)),
                                 guild=types.SimpleNamespace(fetch_member=AsyncMock(return_value=member)),
                                 edit_original_response=AsyncMock())


class JobTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.store = JobStore(Path(self.folder.name) / "jobs.db")
        self.runner = JobRunner(self.store)

    async def asyncTearDown(self):
        self.store.db.close()
        self.folder.cleanup()

    async def test_operations_from_two_guilds_are_serialized(self):
        active = 0
        maximum = 0

        async def execute(*args, **kwargs):
            nonlocal active, maximum
            active += 1
            maximum = max(maximum, active)
            await asyncio.sleep(0.02)
            active -= 1
            return 0, "done"

        with patch("utils.can_access", return_value=True), patch("ssh_helper.run_ps_file", side_effect=execute):
            codes = await asyncio.gather(
                self.runner.run(interaction(1, 10), "start", "main", "scripts/Start-Server.ps1", Profile="main"),
                self.runner.run(interaction(2, 20), "start", "friend", "scripts/Start-Server.ps1", Profile="friend"),
            )
        self.assertEqual(codes, [0, 0])
        self.assertEqual(maximum, 1)
        self.assertEqual(self.store.db.execute("SELECT COUNT(*) FROM jobs WHERE status='completed'").fetchone()[0], 2)

    async def test_revoked_access_is_checked_before_execution(self):
        with patch("utils.can_access", side_effect=[True, False]), patch("ssh_helper.run_ps_file", new_callable=AsyncMock) as execute:
            code = await self.runner.run(interaction(2, 20), "stop", "friend", "scripts/Stop-Server.ps1", Profile="friend")
        self.assertEqual(code, 1)
        execute.assert_not_awaited()
        self.assertEqual(self.store.db.execute("SELECT status FROM jobs").fetchone()[0], "denied")

    async def test_transport_timeout_is_unknown_not_success(self):
        with patch("utils.can_access", return_value=True), patch("ssh_helper.run_ps_file", return_value=(255, "timeout")):
            await self.runner.run(interaction(2, 20), "start", "friend", "scripts/Start-Server.ps1", Profile="friend")
        self.assertEqual(self.store.db.execute("SELECT status FROM jobs").fetchone()[0], "unknown")

    async def test_discord_failure_does_not_erase_completed_host_result(self):
        request = interaction(2, 20)
        message = request.channel.send.return_value
        response = types.SimpleNamespace(status=503, reason="Unavailable")
        message.edit.side_effect = [None, discord.HTTPException(response, "unavailable")]
        with patch("utils.can_access", return_value=True), patch("ssh_helper.run_ps_file", return_value=(0, "done")):
            code = await self.runner.run(request, "start", "friend", "scripts/Start-Server.ps1", Profile="friend")
        self.assertEqual(code, 0)
        self.assertEqual(self.store.db.execute("SELECT status FROM jobs").fetchone()[0], "completed")


class AutomationTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.store = JobStore(Path(self.folder.name) / "jobs.db")
        self.cog = AutomationCog(types.SimpleNamespace(store=self.store, jobs=JobRunner(self.store)))

    async def asyncTearDown(self):
        self.store.db.close()
        self.folder.cleanup()

    async def test_skip_is_not_recorded_as_success(self):
        for reason in ("skipped_active", "skipped_locked"):
            with self.subTest(reason=reason), patch("ssh_helper.run_ps_file", return_value=(0, f"[host] AUTO_UPDATE_RESULT={reason}\r\n")):
                await self.cog._run_update_cycle()
            status = self.store.db.execute("SELECT status FROM jobs ORDER BY id DESC LIMIT 1").fetchone()[0]
            self.assertEqual(status, "skipped")

    async def test_success_requires_the_host_completion_marker(self):
        cases = [(0, "AUTO_UPDATE_RESULT=complete", "completed"),
                 (0, "connection ended without host result", "unknown"),
                 (0, "AUTO_UPDATE_RESULT=failed", "failed"),
                 (1, "AUTO_UPDATE_RESULT=complete", "failed"),
                 (255, "AUTO_UPDATE_RESULT=complete", "unknown")]
        for code, output, expected in cases:
            with self.subTest(code=code, output=output), patch("ssh_helper.run_ps_file", return_value=(code, output)):
                await self.cog._run_update_cycle()
            status = self.store.db.execute("SELECT status FROM jobs ORDER BY id DESC LIMIT 1").fetchone()[0]
            self.assertEqual(status, expected)

    async def test_disabled_configuration_starts_no_scheduler(self):
        with patch.object(config, "AUTO_UPDATE_ENABLED", False), patch("asyncio.create_task") as create:
            await self.cog.cog_load()
        create.assert_not_called()
        self.assertIsNone(self.cog._scheduler_task)

    async def test_failed_attempt_does_not_prevent_next_attempt(self):
        with patch("ssh_helper.run_ps_file", side_effect=[RuntimeError("fixture failure"), (0, "AUTO_UPDATE_RESULT=complete")]):
            await self.cog._run_update_cycle()
            await self.cog._run_update_cycle()
        statuses = self.store.db.execute("SELECT status FROM jobs ORDER BY id").fetchall()
        self.assertEqual(statuses, [("interrupted",), ("completed",)])


if __name__ == "__main__":
    unittest.main()
