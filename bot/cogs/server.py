"""Guild-scoped instance controls and persistent, instance-specific status panels."""

import asyncio
import contextlib
import json
import logging
import time

import a2s
import discord
from discord import app_commands
from discord.ext import commands

import config
import ssh_helper
import utils
from presentation import status_embed

log = logging.getLogger(__name__)


class ServerCog(commands.Cog):
    server = app_commands.Group(name="server", description="Manage your assigned Arma instances")

    def __init__(self, bot):
        self.bot = bot
        self._tasks = {}
        self._restore_task = None
        self._catalog = []
        self._catalog_time = 0.0

    async def cog_load(self):
        self._restore_task = asyncio.create_task(self._restore_panels())

    async def cog_unload(self):
        tasks = list(self._tasks.values()) + ([self._restore_task] if self._restore_task else [])
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)

    async def _status(self, profile=None):
        parameters = {"Profile": profile} if profile else {}
        try:
            code, output = await asyncio.wait_for(
                ssh_helper.run_ps_file("scripts/Get-ServerStatus.ps1", **parameters), timeout=30,
            )
        except TimeoutError as exc:
            raise RuntimeError("Host status timed out") from exc
        if code:
            raise RuntimeError("Host status is unavailable")
        for line in output.splitlines():
            if line.startswith("INSTANCE_JSON="):
                value = json.loads(line.removeprefix("INSTANCE_JSON="))
                if isinstance(value, list):
                    return value
        raise RuntimeError("Invalid host status response")

    async def _get_catalog(self):
        if not self._catalog or time.monotonic() - self._catalog_time > 15:
            self._catalog = await self._status()
            self._catalog_time = time.monotonic()
        return self._catalog

    async def _profile_choices(self, interaction, current):
        if not utils.has_any_access(interaction):
            return []
        action = interaction.command.name if interaction.command else "status"
        try:
            profiles = await asyncio.wait_for(self._get_catalog(), timeout=2)
        except (TimeoutError, RuntimeError):
            return []
        return [app_commands.Choice(name=item["Profile"], value=item["Profile"])
                for item in profiles if current.lower() in item["Profile"]
                and utils.can_access(interaction, action, item["Profile"])][:25]

    async def _preset_choices(self, interaction, current):
        profile = interaction.namespace.profile
        if not utils.can_access(interaction, "preset", profile):
            return []
        try:
            entries = await asyncio.wait_for(self._get_catalog(), timeout=2)
        except (TimeoutError, RuntimeError):
            return []
        for item in entries:
            if item["Profile"] == profile:
                return [app_commands.Choice(name=name, value=name) for name in item["Presets"] if current.lower() in name][:25]
        return []

    async def _embed(self, profile):
        status = (await self._status(profile))[0]
        running = status["Running"]
        info = None
        if running:
            try:
                info = await asyncio.to_thread(a2s.info, (config.SERVER_HOST, status["Port"] + 1), timeout=2)
            except Exception as exc:
                log.debug("A2S unavailable for %s: %s", profile, exc)
        return status_embed(profile, status, info)

    async def _panel_loop(self, guild_id, profile, channel_id, message_id):
        misses = 0
        while True:
            try:
                channel = self.bot.get_channel(channel_id) or await self.bot.fetch_channel(channel_id)
                if not getattr(channel, "guild", None) or channel.guild.id != guild_id:
                    return
                message = channel.get_partial_message(message_id)
                try:
                    embed = await self._embed(profile)
                    misses = 0
                except Exception:
                    misses += 1
                    log.warning("Status query failed for %s (attempt %d)", profile, misses)
                    embed = discord.Embed(title=f"{profile} — Status unavailable", description="The host could not be queried. This does not mean the game server is offline.", color=discord.Color.orange())
                await message.edit(embed=embed)
            except (discord.NotFound, discord.Forbidden):
                self.bot.store.remove_panel(guild_id, profile)
                return
            except discord.HTTPException:
                log.warning("Could not update status panel for %s", profile)
            await asyncio.sleep(30)

    def _track_panel(self, guild, profile, channel, message):
        key = (guild, profile)
        old = self._tasks.pop(key, None)
        if old:
            old.cancel()
        task = asyncio.create_task(self._panel_loop(guild, profile, channel, message))
        self._tasks[key] = task

        def discard(completed):
            if self._tasks.get(key) is completed:
                self._tasks.pop(key, None)

        task.add_done_callback(discard)

    async def _restore_panels(self):
        await self.bot.wait_until_ready()
        for guild, profile, channel, message in self.bot.store.panels():
            guild_id = int(guild)
            if guild_id not in config.GUILD_IDS:
                continue
            if config.ACCESS_POLICY and profile not in config.ACCESS_POLICY.guilds[guild_id]:
                continue
            self._track_panel(guild_id, profile, int(channel), int(message))

    async def _ensure_panel(self, interaction, profile):
        if (interaction.guild_id, profile) in self._tasks:
            return
        message = await interaction.channel.send(embed=await self._embed(profile))
        self.bot.store.save_panel(interaction.guild_id, profile, message.channel.id, message.id)
        self._track_panel(interaction.guild_id, profile, message.channel.id, message.id)

    @server.command(name="list", description="List instances assigned to you")
    async def server_list(self, interaction: discord.Interaction):
        if not utils.has_any_access(interaction):
            await interaction.response.send_message("No instances are assigned to you.", ephemeral=True)
            return
        await interaction.response.defer(ephemeral=True)
        try:
            entries = await self._status()
            visible = [item for item in entries if utils.can_access(interaction, "list", item["Profile"])]
            lines = [f"`{item['Profile']}` — {'running' if item['Running'] else 'stopped'} — preset `{item['Preset']}`" for item in visible]
            await interaction.edit_original_response(content="\n".join(lines)[:1900] or "No instances are assigned to you.")
        except RuntimeError:
            await interaction.edit_original_response(content="Host status is unavailable.")

    @server.command(name="start", description="Start an assigned instance")
    @app_commands.autocomplete(profile=_profile_choices)
    async def server_start(self, interaction: discord.Interaction, profile: str):
        if not await utils.require_access(interaction, "start", profile):
            return
        code = await self.bot.jobs.run(interaction, "start", profile, "scripts/Start-Server.ps1", Profile=profile)
        if code == 0:
            with contextlib.suppress(discord.HTTPException, RuntimeError):
                await self._ensure_panel(interaction, profile)

    @server.command(name="stop", description="Stop only the selected instance and its headless clients")
    @app_commands.autocomplete(profile=_profile_choices)
    async def server_stop(self, interaction: discord.Interaction, profile: str):
        if await utils.require_access(interaction, "stop", profile):
            await self.bot.jobs.run(interaction, "stop", profile, "scripts/Stop-Server.ps1", Profile=profile)

    @server.command(name="restart", description="Restart an assigned instance (ends the active game session)")
    @app_commands.autocomplete(profile=_profile_choices)
    async def server_restart(self, interaction: discord.Interaction, profile: str):
        if await utils.require_access(interaction, "restart", profile):
            await self.bot.jobs.run(interaction, "restart", profile, "scripts/Restart-Server.ps1", Profile=profile)

    @server.command(name="status", description="Show status for an assigned instance")
    @app_commands.autocomplete(profile=_profile_choices)
    async def server_status(self, interaction: discord.Interaction, profile: str):
        if not await utils.require_access(interaction, "status", profile):
            return
        await interaction.response.defer(ephemeral=True)
        try:
            await interaction.edit_original_response(embed=await self._embed(profile))
        except RuntimeError:
            await interaction.edit_original_response(content="Host status is unavailable; the server may still be running.")

    @server.command(name="preset", description="Select an approved mod preset for a stopped instance")
    @app_commands.autocomplete(profile=_profile_choices, preset=_preset_choices)
    async def server_preset(self, interaction: discord.Interaction, profile: str, preset: str):
        if await utils.require_access(interaction, "preset", profile):
            await self.bot.jobs.run(interaction, "preset", profile, "scripts/Set-InstancePreset.ps1", Profile=profile, Preset=preset)
            self._catalog_time = 0

    @server.command(name="update", description="Owner: update the shared Arma installation while all instances are stopped")
    async def server_update(self, interaction: discord.Interaction):
        if not utils.has_admin_auth(interaction):
            await interaction.response.send_message("Only the hardware owner may update shared files.", ephemeral=True)
            return
        await self.bot.jobs.run(interaction, "update", "", "setup/Update-Server.ps1", owner_only=True)


async def setup(bot):
    await bot.add_cog(ServerCog(bot))
