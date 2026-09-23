"""Guild-scoped instance controls and persistent, instance-specific status panels."""

import asyncio
import contextlib
import json
import logging
import re
import sqlite3
import time

import a2s
import discord
from discord import app_commands
from discord.ext import commands

import config
import ssh_helper
import utils
from presentation import status_embed
from access import valid_profile
from control_panel import ServerControlView

log = logging.getLogger(__name__)


class ServerCog(commands.Cog):
    server = app_commands.Group(name="server", description="Manage your assigned Arma instances")

    def __init__(self, bot):
        self.bot = bot
        self._tasks = {}
        self._restore_task = None
        self._catalog = []
        self._catalog_time = 0.0
        self._control_tasks = {}
        self._control_views = {}
        self._control_busy = set()
        self._control_refresh_times = {}
        self._panel_lock = asyncio.Lock()

    async def cog_load(self):
        # Register callbacks before the gateway becomes ready. The IDs in SQLite
        # bind each persistent view to its original Discord message after rebuilds.
        for guild, profile, channel, message in self.bot.store.control_panels():
            if self._panel_allowed(int(guild), profile):
                self._register_control(int(guild), profile, int(message))
        self._restore_task = asyncio.create_task(self._restore_panels())

    async def cog_unload(self):
        tasks = list(self._tasks.values()) + list(self._control_tasks.values()) + ([self._restore_task] if self._restore_task else [])
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        for view in self._control_views.values():
            view.stop()

    @staticmethod
    def _panel_allowed(guild, profile):
        return (guild in config.GUILD_IDS and valid_profile(profile) and
                (not config.ACCESS_POLICY or profile in config.ACCESS_POLICY.guilds.get(guild, {})))

    def _register_control(self, guild, profile, message):
        key = (guild, profile)
        old = self._control_views.pop(key, None)
        if old:
            old.stop()
        view = ServerControlView(self, guild, profile)
        self.bot.add_view(view, message_id=message)
        self._control_views[key] = view
        return view

    @staticmethod
    def log_control_error(error):
        log.error("Control panel interaction failed", exc_info=(type(error), error, error.__traceback__))

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
        embed, _ = await self._snapshot(profile)
        return embed

    async def _snapshot(self, profile):
        status = (await self._status(profile))[0]
        running = status["Running"]
        info = None
        if running:
            try:
                info = await asyncio.to_thread(a2s.info, (config.SERVER_HOST, status["Port"] + 1), timeout=2)
            except Exception as exc:
                log.debug("A2S unavailable for %s: %s", profile, exc)
        return status_embed(profile, status, info), running

    async def _panel_loop(self, guild_id, profile, channel_id, message_id, *, control=False):
        misses = 0
        while True:
            try:
                if control and (not self._panel_allowed(guild_id, profile) or
                                self.bot.store.control_panel(guild_id, profile) != (str(channel_id), str(message_id))):
                    return
                channel = self.bot.get_channel(channel_id) or await self.bot.fetch_channel(channel_id)
                if not getattr(channel, "guild", None) or channel.guild.id != guild_id:
                    return
                message = channel.get_partial_message(message_id)
                running = None
                try:
                    embed, running = await self._snapshot(profile)
                    misses = 0
                except Exception:
                    misses += 1
                    log.warning("Status query failed for %s (attempt %d)", profile, misses)
                    embed = discord.Embed(title=f"{profile} — Status unavailable", description="The host could not be queried. This does not mean the game server is offline.", color=discord.Color.orange())
                if control:
                    view = self._control_views.get((guild_id, profile))
                    if view is None:
                        view = self._register_control(guild_id, profile, message_id)
                    view.set_state(running, busy=profile in self._control_busy)
                    self._control_footer(embed, running)
                    await message.edit(embed=embed, view=view)
                else:
                    await message.edit(embed=embed)
                if running is False:
                    # Bot restoration can still refresh this persisted message.
                    log.debug("Paused offline status panel for %s in guild %s", profile, guild_id)
                    return
            except discord.NotFound:
                if control:
                    if self.bot.store.control_panel(guild_id, profile) == (str(channel_id), str(message_id)):
                        self.bot.store.remove_control_panel(guild_id, profile, message_id)
                        view = self._control_views.pop((guild_id, profile), None)
                        if view:
                            view.stop()
                else:
                    self.bot.store.remove_panel(guild_id, profile)
                return
            except discord.Forbidden:
                if not control:
                    self.bot.store.remove_panel(guild_id, profile)
                    return
                # Keep durable identity during temporary channel permission loss.
                log.warning("Cannot access control panel for guild=%s profile=%s; retaining it for retry", guild_id, profile)
                await asyncio.sleep(60)
                continue
            except discord.HTTPException:
                log.warning("Could not update status panel for %s", profile)
            await asyncio.sleep(30)

    def _track_panel(self, guild, profile, channel, message, *, control=False):
        key = (guild, profile)
        tasks = self._control_tasks if control else self._tasks
        old = tasks.pop(key, None)
        if old:
            old.cancel()
        task = asyncio.create_task(self._panel_loop(guild, profile, channel, message, control=control))
        tasks[key] = task

        def discard(completed):
            if tasks.get(key) is completed:
                tasks.pop(key, None)

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
        for guild, profile, channel, message in self.bot.store.control_panels():
            if self._panel_allowed(int(guild), profile):
                self._track_panel(int(guild), profile, int(channel), int(message), control=True)

    async def _ensure_panel(self, interaction, profile):
        if self.bot.store.control_panel(interaction.guild_id, profile):
            self.refresh_panels(profile)
            return
        # A new start/restart deserves a fresh panel at the bottom of the
        # invoking channel. Other guilds keep their own independent panel.
        message = await interaction.channel.send(embed=await self._embed(profile), allowed_mentions=discord.AllowedMentions.none())
        self.bot.store.save_panel(interaction.guild_id, profile, message.channel.id, message.id)
        self._track_panel(interaction.guild_id, profile, message.channel.id, message.id)
        self.refresh_panels(profile, exclude_guild=interaction.guild_id)

    def refresh_panels(self, profile, *, exclude_guild=None):
        """Resume persisted panels across authorized guilds after a host action."""
        resumed = set()
        for guild, saved_profile, channel, message in self.bot.store.panels():
            guild_id = int(guild)
            if saved_profile != profile or guild_id not in config.GUILD_IDS or guild_id == exclude_guild:
                continue
            if config.ACCESS_POLICY and profile not in config.ACCESS_POLICY.guilds[guild_id]:
                continue
            # Replace even a still-active task: it may be finishing an offline
            # snapshot from before the start/restart operation completed.
            self._track_panel(guild_id, profile, int(channel), int(message))
            resumed.add((guild_id, profile))
        for guild, saved_profile, channel, message in self.bot.store.control_panels():
            guild_id = int(guild)
            if saved_profile == profile and self._panel_allowed(guild_id, profile):
                self._track_panel(guild_id, profile, int(channel), int(message), control=True)
                resumed.add((guild_id, profile))
        return resumed

    @staticmethod
    def _control_footer(embed, running):
        embed.set_footer(text=("CPU/RAM include HCs • CPU: host capacity • Updated every 30s • Controls require instance access" if running else
                               "Offline checks paused • Use Start or Refresh • Controls require instance access" if running is False else
                               "Status unavailable • Retrying automatically • Controls require instance access"))

    async def control_action(self, interaction, guild_id, profile, action):
        saved = self.bot.store.control_panel(guild_id, profile)
        if (interaction.guild_id != guild_id or not self._panel_allowed(guild_id, profile) or
                not interaction.message or saved != (str(interaction.channel_id), str(interaction.message.id))):
            await interaction.response.send_message("This panel is no longer active. Use the current server panel.", ephemeral=True)
            return
        if action not in {"start", "stop", "status"} or not await utils.require_access(interaction, action, profile):
            return
        if action == "status":
            key = (guild_id, profile)
            now = time.monotonic()
            if now - self._control_refresh_times.get(key, -10) < 5:
                await interaction.response.send_message("Please wait a few seconds before refreshing again.", ephemeral=True)
                return
            self._control_refresh_times[key] = now
            self.refresh_panels(profile)
            await interaction.response.send_message("Refreshing the server panel…", ephemeral=True)
            return
        if profile in self._control_busy:
            await interaction.response.send_message("An operation for this instance is already in progress.", ephemeral=True)
            return
        self._control_busy.add(profile)
        try:
            # JobRunner rechecks live membership/roles immediately before SSH,
            # serializes operations, and records the same audit trail as commands.
            script = "scripts/Start-Server.ps1" if action == "start" else "scripts/Stop-Server.ps1"
            await self.bot.jobs.run(interaction, action, profile, script, private=True, Profile=profile)
        finally:
            self._control_busy.discard(profile)
            self.refresh_panels(profile)

    async def _publish_control(self, guild_id, profile, channel):
        saved = self.bot.store.control_panel(guild_id, profile)
        view = ServerControlView(self, guild_id, profile)
        embed = discord.Embed(title=f"Server — {profile}", description="Loading server status…", color=discord.Color.blue())
        message = None
        if saved and int(saved[0]) == channel.id:
            try:
                message = channel.get_partial_message(int(saved[1]))
                await message.edit(embed=embed, view=view)
            except discord.NotFound:
                message = None
        if message is None:
            message = await channel.send(embed=embed, view=view, allowed_mentions=discord.AllowedMentions.none())
        try:
            self.bot.store.save_control_panel(guild_id, profile, channel.id, message.id)
        except Exception:
            view.stop()
            with contextlib.suppress(discord.HTTPException):
                await message.edit(view=None)
            raise
        # Stop the view auto-registered by send/edit before registering our tracked
        # copy. Callbacks are always bound to the persisted message identity.
        view.stop()
        self._register_control(guild_id, profile, message.id)
        self._track_panel(guild_id, profile, channel.id, message.id, control=True)
        # Retire the old transient status panel; future starts update this card.
        self.bot.store.remove_panel(guild_id, profile)
        old_task = self._tasks.pop((guild_id, profile), None)
        if old_task:
            old_task.cancel()
        if saved and saved != (str(channel.id), str(message.id)):
            with contextlib.suppress(discord.HTTPException):
                old_channel = self.bot.get_channel(int(saved[0])) or await self.bot.fetch_channel(int(saved[0]))
                await old_channel.get_partial_message(int(saved[1])).edit(
                    embed=discord.Embed(title=f"Server panel moved — {profile}", description=f"Use <#{channel.id}> for the current panel."), view=None)
        return f"https://discord.com/channels/{guild_id}/{channel.id}/{message.id}"

    @server.command(name="panel", description="Create or move persistent server controls to a text channel")
    @app_commands.guild_only()
    @app_commands.describe(channel="Channel for the persistent panels", profiles="Instance IDs separated by commas, for example main,60th")
    async def server_panel(self, interaction: discord.Interaction, channel: discord.TextChannel, profiles: str):
        names = list(dict.fromkeys(re.split(r"[\s,]+", profiles.strip())))
        if len(profiles) > 1300 or not 1 <= len(names) <= 20 or any(not valid_profile(name) for name in names):
            await interaction.response.send_message("Enter 1–20 valid instance IDs separated by commas.", ephemeral=True)
            return
        if (interaction.guild_id != channel.guild.id or not utils.has_any_access(interaction) or
                any(not utils.can_access(interaction, "start", name) for name in names)):
            await interaction.response.send_message("You need operator access to every selected instance in this Discord server.", ephemeral=True)
            return
        user_permissions = channel.permissions_for(interaction.user)
        bot_permissions = channel.permissions_for(interaction.guild.me)
        if not user_permissions.view_channel or not (utils.has_admin_auth(interaction) or user_permissions.manage_channels):
            await interaction.response.send_message("Creating or moving panels requires Manage Channels in the target channel, or hardware-owner access.", ephemeral=True)
            return
        if not all((bot_permissions.view_channel, bot_permissions.send_messages, bot_permissions.embed_links)):
            await interaction.response.send_message("The bot needs View Channel, Send Messages and Embed Links in the target channel.", ephemeral=True)
            return
        await interaction.response.defer(ephemeral=True, thinking=True)
        links = []
        try:
            async with self._panel_lock:
                # Confirm profile existence without relying on autocomplete cache.
                known = {entry["Profile"] for entry in await self._status()}
                if any(name not in known for name in names):
                    await interaction.edit_original_response(content="One or more selected instances do not exist on the host.")
                    return
                interaction.user = await interaction.guild.fetch_member(interaction.user.id)
                permissions = channel.permissions_for(interaction.user)
                if (any(not utils.can_access(interaction, "start", name) for name in names) or
                        not permissions.view_channel or
                        not (utils.has_admin_auth(interaction) or permissions.manage_channels)):
                    await interaction.edit_original_response(content="Your access changed while panel setup was waiting. No panels were published.")
                    return
                for name in names:
                    links.append(await self._publish_control(interaction.guild_id, name, channel))
            await interaction.edit_original_response(content="Server panels ready:\n" + "\n".join(links))
        except (discord.HTTPException, RuntimeError, sqlite3.Error):
            log.exception("Could not publish control panels")
            await interaction.edit_original_response(content="Could not finish creating the panels. Check channel permissions and host connectivity.\n" + "\n".join(links))

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
            code = await self.bot.jobs.run(interaction, "stop", profile, "scripts/Stop-Server.ps1", Profile=profile)
            if code == 0:
                self.refresh_panels(profile)

    @server.command(name="restart", description="Restart an assigned instance (ends the active game session)")
    @app_commands.autocomplete(profile=_profile_choices)
    async def server_restart(self, interaction: discord.Interaction, profile: str):
        if await utils.require_access(interaction, "restart", profile):
            code = await self.bot.jobs.run(interaction, "restart", profile, "scripts/Restart-Server.ps1", Profile=profile)
            if code == 0:
                with contextlib.suppress(discord.HTTPException, RuntimeError):
                    await self._ensure_panel(interaction, profile)

    @server.command(name="status", description="Show status for an assigned instance")
    @app_commands.autocomplete(profile=_profile_choices)
    async def server_status(self, interaction: discord.Interaction, profile: str):
        if not await utils.require_access(interaction, "status", profile):
            return
        await interaction.response.defer(ephemeral=True)
        try:
            embed, running = await self._snapshot(profile)
            await interaction.edit_original_response(embed=embed)
            if running:
                self.refresh_panels(profile)
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
