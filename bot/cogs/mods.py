"""Operator-scoped preset imports, Workshop synchronization and updates."""

import contextlib
import uuid

import discord
from discord import app_commands
from discord.ext import commands

import config
import ssh_helper
import utils


async def targets(interaction, action, profile):
    """Expand _all to assigned operator profiles without exposing foreign instances."""
    if profile == "_all":
        if utils.has_admin_auth(interaction):
            return ["_all"]  # Owner retains the existing host-wide operation.
        if config.ACCESS_POLICY:
            assigned = [name for name in config.ACCESS_POLICY.guilds.get(interaction.guild_id, {})
                        if utils.can_access(interaction, action, name)]
            if assigned:
                return assigned
    if await utils.require_access(interaction, action, profile):
        return [profile]
    return []


class ModsCog(commands.Cog):
    mods = app_commands.Group(name="mods", description="Import instance presets and manage shared Workshop files")

    def __init__(self, bot):
        self.bot = bot

    @mods.command(name="sync", description="Operator: download and deploy mods for assigned instances")
    async def mods_sync(self, interaction: discord.Interaction, profile: str, force: bool = False):
        for target in await targets(interaction, "mods-sync", profile):
            await self.bot.jobs.run(interaction, "mods-sync", target, "mods/Sync-Mods.ps1", owner_only=target == "_all", Profile=target, Force=force)

    @mods.command(name="update", description="Operator: check or deploy Workshop updates for assigned instances")
    async def mods_update(self, interaction: discord.Interaction, profile: str, restart_server: bool = False, check_only: bool = False):
        if restart_server and (profile == "_all" or check_only):
            await interaction.response.send_message("Restart requires one concrete profile and cannot be combined with check-only.", ephemeral=True)
            return
        for target in await targets(interaction, "mods-update", profile):
            code = await self.bot.jobs.run(interaction, "mods-update", target, "mods/Sync-Mods.ps1", owner_only=target == "_all",
                                          Profile=target, Update=True, RestartServer=restart_server, CheckOnly=check_only)
            if restart_server:
                server = self.bot.get_cog("ServerCog")
                if server:
                    if code == 0:
                        with contextlib.suppress(discord.HTTPException, RuntimeError):
                            await server._ensure_panel(interaction, target)
                    else:
                        server.refresh_panels(target)

    @mods.command(name="import-preset", description="Operator: import a Launcher HTML preset for an assigned instance")
    async def mods_import_preset(self, interaction: discord.Interaction, profile: str, preset_html: discord.Attachment, merge: bool = False, sync_after: bool = False):
        if not await utils.require_access(interaction, "preset-import", profile):
            return
        if not preset_html.filename.lower().endswith(".html") or preset_html.size > 2 * 1024 * 1024:
            await interaction.response.send_message("Attach a Launcher .html preset of at most 2 MiB.", ephemeral=True)
            return
        await interaction.response.defer(ephemeral=True)
        try:
            data = await preset_html.read()
            if len(data) > 2 * 1024 * 1024:
                raise ValueError("Preset is too large")
            # Never use the client-supplied filename as a host filesystem path.
            remote = config.SCRIPTS_PATH.rstrip("\\") + "\\presets\\" + uuid.uuid4().hex + ".html"
            await ssh_helper.upload_bytes(data, remote)
        except (discord.HTTPException, RuntimeError, ValueError):
            await interaction.edit_original_response(content="Preset upload failed. See the private bot log.")
            return
        await self.bot.jobs.run(interaction, "preset-import", profile, "mods/Import-Preset.ps1",
                                Profile=profile, PresetFile=remote, Merge=merge, SyncAfter=sync_after)


async def setup(bot):
    await bot.add_cog(ModsCog(bot))
