"""Owner-only changes to the shared mod inventory and trusted profile metadata."""

import uuid

import discord
from discord import app_commands
from discord.ext import commands

import config
import ssh_helper
import utils
from access import valid_profile


async def allowed(interaction, profile, *, all_profiles=False):
    if not utils.has_admin_auth(interaction):
        await interaction.response.send_message("Only the hardware owner may change shared mods or import presets.", ephemeral=True)
        return False
    if not valid_profile(profile) and not (all_profiles and profile == "_all"):
        await interaction.response.send_message("Invalid profile ID.", ephemeral=True)
        return False
    return True


class ModsCog(commands.Cog):
    mods = app_commands.Group(name="mods", description="Owner: manage shared Workshop files")

    def __init__(self, bot):
        self.bot = bot

    @mods.command(name="sync", description="Owner: download and deploy mods while all instances are stopped")
    async def mods_sync(self, interaction: discord.Interaction, profile: str, force: bool = False):
        if await allowed(interaction, profile, all_profiles=True):
            await self.bot.jobs.run(interaction, "mods-sync", profile, "mods/Sync-Mods.ps1", owner_only=True, Profile=profile, Force=force)

    @mods.command(name="update", description="Owner: check or deploy Workshop updates")
    async def mods_update(self, interaction: discord.Interaction, profile: str, restart_server: bool = False, check_only: bool = False):
        if not await allowed(interaction, profile, all_profiles=True):
            return
        if restart_server and (profile == "_all" or check_only):
            await interaction.response.send_message("Restart requires one concrete profile and cannot be combined with check-only.", ephemeral=True)
            return
        await self.bot.jobs.run(interaction, "mods-update", profile, "mods/Sync-Mods.ps1", owner_only=True,
                                Profile=profile, Update=True, RestartServer=restart_server, CheckOnly=check_only)

    @mods.command(name="import-preset", description="Owner: import a Launcher HTML preset into trusted profile metadata")
    async def mods_import_preset(self, interaction: discord.Interaction, profile: str, preset_html: discord.Attachment, merge: bool = False, sync_after: bool = False):
        if not await allowed(interaction, profile):
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
        await self.bot.jobs.run(interaction, "preset-import", profile, "mods/Import-Preset.ps1", owner_only=True,
                                Profile=profile, PresetFile=remote, Merge=merge, SyncAfter=sync_after)


async def setup(bot):
    await bot.add_cog(ModsCog(bot))
